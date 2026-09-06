import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Filesystem boundary rules enforced here:
//  - File discovery streams NUL-delimited find output (filenames cannot forge
//    separators), is capped while consuming (never buffers unbounded output),
//    and aborts if anything unexpected appears on the stream.
//  - Nothing is loaded until a stat (no dereference) of the exact candidate
//    path confirms a regular file under the size cap. Only then is the
//    FileView for that path created. Every watch-triggered reload re-runs the
//    same checks and keeps the last good data if validation fails.
//  - Task writes never touch the shell for redirection (which would follow a
//    planted inbox.md symlink). The file is staged under mktemp and renamed
//    over the target; atomicWrites does the same, so a symlinked inbox.md or
//    a swapped Todos/ directory is *replaced* (still inside the vault), never
//    written through.
// Residual TOCTOU between stat and load is inherent to the QML toolset; the
// reload re-validation and hard size cap bound what an attacker can achieve
// through it. A native backend (open/fstat/O_NOFOLLOW) would close it fully.
Panel {
  id: root
  moduleName: "jeanhuit.todos"
  ipcTarget: "jeanhuit.todos"
  manageIpc: false

  // ---- resource limits ---------------------------------------------------
  readonly property int maxFiles: 256                 // files scanned / watched
  readonly property int maxFileSize: 1 * 1024 * 1024  // bytes per file (approximate in chars on read)

  // ---- configuration -------------------------------------------------------
  readonly property string rawVaultPath: setting("vaultPath", "")
  readonly property string todosDirName: sanitizeSegment(setting("todosDir", "Todos"), "Todos")
  readonly property string inboxFile: sanitizeSegment(setting("inboxFile", "inbox.md"), "inbox.md")
  readonly property bool showCompleted: setting("showCompleted", false) === true

  // rawVaultPath is what the user typed (kept for the setup form). Everything
  // that touches the filesystem is derived from the canonicalized vaultPath.
  readonly property bool configured: String(rawVaultPath).trim() !== ""
  property bool vaultPending: false
  property string vaultPath: ""
  readonly property string todosPath: vaultPath === "" ? "" : vaultPath + "/" + todosDirName
  readonly property string vaultName: vaultPath === "" ? "" : vaultPath.split("/").pop()

  function sanitizeSegment(value, fallback) {
    // Single plain path segment (see Model.validateSegment); anything else
    // falls back to the default.
    return Model.validateSegment(value) || fallback
  }

  function normalizeVaultPath() {
    // Canonicalize once (symlinks resolved, ~ and relative paths expanded) so
    // every derived path is a plain, unambiguous location.
    var raw = String(rawVaultPath).trim()
    if (raw === "") {
      vaultPath = ""
      vaultPending = false
      return
    }
    var abs = raw
    if (abs.charAt(0) === "~")
      abs = abs.replace(/^~(\/|$)/, Quickshell.env("HOME") + "/")
    if (abs.charAt(0) !== "/")
      abs = Quickshell.env("PWD") + "/" + abs
    vaultPending = true
    canonProc.run(abs)
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function saveVault() {
    var path = String(vaultField.text || "").replace(/^\s+|\s+$/g, "").replace(/\/+$/, "")
    if (path === "") return
    persistSettings({ vaultPath: path }) // rawVaultPath change re-canonicalizes
  }

  // ---- state ---------------------------------------------------------------
  readonly property color contentForeground: root.barForeground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color urgentColor: bar && bar.urgent ? bar.urgent : Color.urgent
  readonly property string todayKey: Model.dateKey(new Date())

  property var files: []
  property var pendingFiles: []
  property var fileData: ({})
  property var taskList: []
  property var displayList: []
  property int openCount: 0
  property var views: ({})
  property string filesKey: ""
  property bool scanAborted: false
  property bool scanCapped: false
  property int scanGen: 0
  property string statusText: ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var openTasks: displayList.filter(function (t) { return !t.done })
  readonly property var doneTasks: displayList.filter(function (t) { return t.done })
  readonly property int doneCount: doneTasks.length

  function recompute() {
    var list = []
    var open = 0
    var names = []
    for (var k in fileData) names.push(k)
    names.sort()

    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      var rec = fileData[name]
      var tasks = rec.tasks || []
      for (var j = 0; j < tasks.length; j++) {
        var t = tasks[j]
        list.push({ file: name, path: rec.path, line: t.line, done: t.done, text: t.text, due: t.due })
        if (!t.done) open++
      }
    }

    var today = root.todayKey
    list.sort(function (a, b) {
      if (a.done !== b.done) return a.done ? 1 : -1
      var ao = a.due !== "" && a.due < today
      var bo = b.due !== "" && b.due < today
      if (ao !== bo) return ao ? -1 : 1
      if (a.due !== b.due) return a.due === "" ? 1 : (b.due === "" ? -1 : (a.due < b.due ? -1 : 1))
      return a.file < b.file ? -1 : (a.file > b.file ? 1 : 0)
    })

    taskList = list
    openCount = open
    displayList = list.filter(function (t) { return root.showCompleted || !t.done })
  }

  function setFile(name, path, content) {
    var next = {}
    for (var k in fileData) next[k] = fileData[k]
    // Parse results are retained; the raw content is not (it can be large
    // and is re-read from the view whenever needed, e.g. on toggle).
    next[name] = { path: path, tasks: Model.parseTasks(content) }
    fileData = next
    recompute()
  }

  function removeFile(name) {
    var next = {}
    for (var k in fileData) if (k !== name) next[k] = fileData[k]
    fileData = next
    recompute()
  }

  function registerView(name, view) { views[name] = view }
  function unregisterView(name) { delete views[name] }

  function abortScan(reason) {
    // One strike: anything unexpected from the discovery stream (bogus or
    // overlong filename, malformed output) stops the whole scan and keeps
    // the previous, validated file list.
    if (scanAborted) return
    scanAborted = true
    statusText = "scan aborted: " + reason
    if (listProc.running) listProc.signal(15)
  }

  function clearResults() {
    files = []
    pendingFiles = []
    fileData = ({})
    taskList = []
    displayList = []
    openCount = 0
  }

  // ---- file discovery --------------------------------------------------------
  function refresh() {
    if (!root.configured || vaultPending || todosPath === "") {
      clearResults()
      return
    }
    scanGen++
    scanAborted = false
    scanCapped = false
    statusText = ""
    pendingFiles = []
    // Stop any in-flight enumeration first: its entries would otherwise be
    // validated against the NEW todosPath and its stderr could abort THIS
    // scan. Dropping the connection also discards cross-generation output.
    if (listProc.running) listProc.running = false
    listProc.command = ["find", "-P", todosPath, "-maxdepth", "1", "-type", "f", "-name", "*.md", "-print0"]
    listProc.running = true
  }

  function handleDiscoveredPath(p) {
    // Streamed consumption: validate and account for each entry as it
    // arrives; enumeration is killed at the cap instead of buffering the
    // full find output.
    if (scanAborted || p === "") return
    // find -print0 yields full paths; require the exact vault prefix and a
    // safe basename (see Model.validateVaultPath).
    var res = Model.validateVaultPath(todosPath, p)
    if (!res.ok) { abortScan(res.reason); return }
    var name = res.name
    if (pendingFiles.length >= maxFiles) {
      // Bounded consumption: maxFiles validated entries collected, so stop
      // reading instead of buffering more; what we have gets committed.
      if (!scanCapped && listProc.running) {
        scanCapped = true
        listProc.signal(15) // SIGTERM: enumeration stops at the cap
      }
      return
    }
    if (pendingFiles.some(function (f) { return f.name === name })) return
    pendingFiles.push({ name: name, path: p })
    // Stat the exact path find reported, not a reconstructed one.
    statProc.run(name, p, "discover", scanGen)
  }

  // stat -c '%F:%s' with no dereference: a symlink is reported as
  // "symbolic link" and rejected. Runs one candidate at a time; validation
  // happens before the FileView for that path is ever created.
  function handleStatResult(name, mode, gen, payload) {
    if (gen !== scanGen) return // superseded by a newer scan
    var res = Model.parseStatPayload(payload, maxFileSize)

    if (mode === "reload") {
      // Re-validate from disk before loading: the object at the watched path
      // may have been replaced since the last check. On failure the view
      // keeps its last good data (stale-but-valid beats fresh-but-unchecked).
      if (res.ok && views[name]) views[name].reload()
      return
    }

    if (!res.ok) {
      if (res.reason === "unparsable stat output") abortScan(res.reason)
      return // symlink / non-regular / too large: never watched
    }
    if (!pendingFiles.some(function (f) { return f.name === name })) return
    // Only now create the watch/read view for this path.
    var next = files.slice()
    next.push({ name: name, path: todosPath + "/" + name })
    files = next
  }

  function commitFileList() {
    if (scanAborted) return
    // find exit code 1 usually means a raced deletion; stderr already flagged
    // real problems. Keep the previously validated list on abnormal exits.
    var key = pendingFiles.map(function (f) { return f.name }).join("\u0001")
    if (key === filesKey) return
    filesKey = key
    files = pendingFiles
    // Drop data/views for files that disappeared.
    var present = {}
    for (var i = 0; i < pendingFiles.length; i++) present[pendingFiles[i].name] = true
    var removed = false
    for (var k in fileData) if (!present[k]) { removeFile(k); removed = true }
    if (removed) recompute()
  }

  // ---- content handling -------------------------------------------------------
  function handleFileContent(name, path, rawContent) {
    // Defense in depth: even though stat capped the size before the view
    // was created, truncate before anything downstream parses it.
    var content = String(rawContent || "")
    if (content.length > maxFileSize) content = content.slice(0, maxFileSize)
    setFile(name, path, content)
  }

  function toggleTask(task) {
    var view = views[task.file]
    if (view) {
      var next = Model.toggleTaskIn(String(view.text() || ""), task.line)
      if (next !== null) {
        view.setText(next)
        setFile(task.file, task.path, next)
        return
      }
    }
    refresh()
  }

  function addTask(text) {
    // IPC/UI input is unbounded and can embed newlines (which would forge
    // extra task lines in the file): flatten, collapse, and cap it first.
    var t = Model.sanitizeTaskText(text, Model.MAX_TASK_LENGTH)
    if (!root.configured || vaultPending || todosPath === "" || t === null) return
    var line = "- [ ] " + t
    var path = todosPath + "/" + inboxFile
    // Preferred write path: no shell at all. appendTask + setText goes
    // through FileView's atomicWrites (temp file + rename), so a planted
    // inbox.md symlink is replaced rather than written through and nothing
    // is passed through bash.
    var view = views[inboxFile]
    if (view && view.loaded) {
      view.setText(Model.appendTask(String(view.text() || ""), t))
      setFile(inboxFile, path, Model.appendTask(view && view.loaded ? String(view.text() || "") : "", t))
      return
    }
    // Fallback: symlink-safe staged rename via add-task.sh (see that file).
    // A swapped Todos/ directory or a symlinked inbox.md is refused
    // (O_NOFOLLOW-equivalent); junk in argv is inert because nothing is
    // expanded by a shell.
    addProc.run(line, path)
  }

  function submitQuick() {
    addTask(quickField.text)
    quickField.text = ""
  }

  readonly property string displayText: root.configured
    ? (root.openCount > 0 ? String(root.openCount) : "✓")
    : "!"

  Component.onCompleted: normalizeVaultPath()
  onRawVaultPathChanged: normalizeVaultPath()
  onTodosPathChanged: refresh()
  onOpenedChanged: if (root.opened) refresh()

  IpcHandler {
    target: "jeanhuit.todos"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
    function add(text: string): string { root.addTask(text); return "ok" }
    function count(): string { return String(root.openCount) }
  }

  // Canonicalize the configured vault path once (symlinks resolved) so every
  // path we derive is unambiguous. Paths are only used as find/stat/mv argv —
  // never passed through a shell — so no quoting is needed.
  Process {
    id: canonProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var canon = String(text || "").replace(/^\s+|\s+$/g, "")
        root.vaultPending = false
        if (canon === "" || canon.indexOf("\n") !== -1) return
        root.vaultPath = canon
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.vaultPending = false
      if (exitCode !== 0) root.statusText = "vault path not found"
    }
  }

  Process {
    id: listProc
    stdout: SplitParser {
      splitMarker: "\u0000"
      onRead: function (data) { root.handleDiscoveredPath(String(data)) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // find's stderr can echo attacker-controlled filenames; flatten and
        // cap it before it reaches the status line.
        var t = String(text || "").replace(/[\r\n]+/g, " ").trim()
        if (t !== "") root.abortScan("find reported: " + t.slice(0, 120))
      }
    }
    onExited: function(exitCode) {
      // exitCode 0 = full scan; scanCapped = we stopped it at the cap.
      // Anything else (aborted/error) keeps the previously validated list.
      if (exitCode === 0 || root.scanCapped) root.commitFileList()
    }
  }

  // --- stat serialization ----------------------------------------------
  // statProc is a single reusable Process, so candidates are validated
  // strictly one at a time through this queue. Running a second stat while
  // one is in flight would overwrite name/gen and misattribute or lose
  // results.
  property var statQueue: []
  function statRequest(name, path, mode, gen) {
    // Coalesce: only the latest request per file+mode is kept, so a rapid
    // stream of file-changed events cannot grow the queue without bound
    // (intermediate reloads would be redundant anyway).
    var key = mode + "\u0001" + name
    for (var i = 0; i < statQueue.length; i++) {
      if (statQueue[i].key === key) { statQueue.splice(i, 1); break }
    }
    statQueue.push({ key: key, name: name, path: path, mode: mode, gen: gen })
    statPump()
  }
  function statPump() {
    if (statProc.running || statQueue.length === 0) return
    var req = statQueue.shift()
    statProc.run(req.name, req.path, req.mode, req.gen)
  }

  // Validates one candidate path at a time. No shell: arguments are passed as
  // argv, so filenames with newlines, quotes or globs are inert. '%F:%s' with
  // no dereference; format fields cannot inject newlines into the payload.
  Process {
    id: statProc
    property string name: ""
    property string mode: ""
    property int gen: 0
    function run(n, path, m, g) {
      name = n
      mode = m
      gen = g
      command = ["stat", "-c", "%F:%s", "--", path]
      running = true
    }
    stdout: SplitParser {
      // stat's own argv cannot contain newlines and %F/%s are fixed coreutils
      // strings, so newline framing is safe here (unlike find output).
      splitMarker: "\n"
      onRead: function (data) {
        root.handleStatResult(statProc.name, statProc.mode, statProc.gen, String(data))
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.statPump()
  }

  // Quick-add fallback write (used when the inbox FileView is not loaded):
  // stage in a private temp file, then rename over the target. No `>>`
  // redirection anywhere — that would follow symlinks. See add-task.sh.
  Process {
    id: addProc
    function run(line, path) {
      command = ["bash", Qt.resolvedUrl("add-task.sh").replace("file://", ""), line, path]
      running = true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.refresh()
      else root.statusText = "could not add task"
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  // Watches the Todos directory itself; "" while unconfigured/vaultPending
  // unloads it, so nothing is watched before the path is canonical.
  // onFileChanged is coalesced through a debounce timer: an event storm
  // (sync client churn or a hostile flood) must not spawn a find process
  // per event.
  Timer {
    id: refreshDebounce
    interval: 250
    repeat: false
    onTriggered: root.refresh()
  }
  FileView {
    id: dirWatcher
    path: root.todosPath
    watchChanges: true
    printErrors: false
    onFileChanged: refreshDebounce.restart()
  }

  Instantiator {
    model: root.files // only stat-validated files reach this model
    delegate: FileView {
      id: fileView
      required property var modelData
      readonly property string fname: modelData.name
      path: modelData.path
      watchChanges: true
      atomicWrites: true
      printErrors: false
      onLoaded: root.handleFileContent(fname, modelData.path, text())
      onFileChanged: root.statRequest(fname, modelData.path, "reload", root.scanGen)
      onLoadFailed: root.removeFile(fname)
      Component.onCompleted: root.registerView(fname, fileView)
      Component.onDestruction: root.unregisterView(fname)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    tooltipText: root.configured
      ? (root.openCount + " open todo" + (root.openCount === 1 ? "" : "s"))
      : "Click to set your Obsidian vault"
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: quickField
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Flickable {
      id: list
      anchors.fill: parent
      clip: true
      contentWidth: width
      contentHeight: column.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: column
        width: list.width
        spacing: Style.space(10)

        PanelHero {
          title: "Todos"
          meta: root.configured ? (root.vaultName + " / " + root.todosDirName) : "Not configured"
          detail: root.configured ? String(root.openCount) : "!"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        PanelSeparator { foreground: root.contentForeground }

        Row {
          width: parent.width
          visible: root.configured
          spacing: Style.space(8)

          TextField {
            id: quickField
            width: parent.width - addButton.width - parent.spacing
            placeholderText: "Add a todo…"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            onAccepted: root.submitQuick()
          }

          Button {
            id: addButton
            text: "Add"
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.submitQuick()
          }
        }

        Column {
          width: parent.width
          visible: !root.configured
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: "Obsidian vault not set"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            width: parent.width
            text: "Todos are Obsidian Tasks stored in a Syncthing-synced folder. Point me at the vault and I'll watch its markdown files."
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          TextField {
            id: vaultField
            width: parent.width
            placeholderText: "~/Sync/Obsidian"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            onAccepted: root.saveVault()
          }

          Button {
            width: parent.width
            text: "Save"
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.saveVault()
          }
        }

        Text {
          visible: root.statusText !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.statusText
          color: root.urgentColor
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSectionHeader {
          visible: root.configured && root.openTasks.length > 0
          text: "Open"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Repeater {
          model: root.openTasks
          delegate: taskRow
        }

        PanelSectionHeader {
          visible: root.configured && root.showCompleted && root.doneCount > 0
          text: "Done"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Repeater {
          model: root.doneTasks
          delegate: taskRow
        }

        Text {
          width: parent.width
          visible: root.configured && root.displayList.length === 0
          text: "All clear."
          color: Qt.darker(root.contentForeground, 1.6)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  Component {
    id: taskRow

    Item {
      id: row
      required property var modelData
      width: column.width
      height: rowContent.implicitHeight + Style.space(12)

      readonly property bool done: modelData.done
      readonly property bool overdue: !modelData.done && modelData.due !== "" && modelData.due < root.todayKey

      BorderSurface {
        id: surface
        anchors.fill: parent
        radius: Style.cornerRadius
        color: mouse.containsMouse
          ? Style.hoverFillFor(root.contentForeground, Color.accent)
          : "transparent"
        borderSpec: mouse.containsMouse
          ? Border.controlSpec("hover-cursor", root.contentForeground, Color.accent)
          : Border.none()
      }

      Row {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        BorderSurface {
          width: Style.space(18)
          height: Style.space(18)
          radius: Style.cornerRadius
          color: row.done
            ? Style.selectedFillFor(root.contentForeground, Color.accent)
            : "transparent"
          borderSpec: Border.controlSpec(row.done ? "selected" : "normal", root.contentForeground, Color.accent)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            visible: row.done
            text: "✓"
            color: Style.selectedStateColor(root.contentForeground, Color.accent)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          width: parent.width - Style.space(18) - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: modelData.text
            color: row.done
              ? Qt.darker(root.contentForeground, 1.8)
              : (row.overdue ? root.urgentColor : root.contentForeground)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.strikeout: row.done
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
          }

          Text {
            visible: modelData.due !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: "📅 " + modelData.due
            color: row.overdue ? root.urgentColor : Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleTask(modelData)
      }
    }
  }
}
