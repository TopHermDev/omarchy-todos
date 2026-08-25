import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "jeanhuit.todos"
  ipcTarget: "jeanhuit.todos"
  manageIpc: false

  readonly property string vaultPath: root.canonicalizeVault(setting("vaultPath", ""))
  readonly property string todosDirName: Model.sanitizeComponent(setting("todosDir", "Todos"), "Todos")
  readonly property string inboxFile: Model.sanitizeComponent(setting("inboxFile", "inbox.md"), "inbox.md")
  readonly property bool showCompleted: setting("showCompleted", false) === true

  readonly property bool configured: vaultPath !== ""
  readonly property string todosPath: vaultPath + "/" + todosDirName
  readonly property string vaultName: configured ? vaultPath.replace(/\/+$/, "").split("/").pop() : ""

  readonly property color contentForeground: root.barForeground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color urgentColor: bar && bar.urgent ? bar.urgent : Color.urgent
  readonly property string todayKey: Model.dateKey(new Date())

  property var files: []
  property var fileData: ({})
  property var taskList: []
  property var displayList: []
  property int openCount: 0
  property var views: ({})
  property string filesKey: ""

  // Cap how many markdown files we watch. The vault is populated by sync
  // tools, so a peer can drop arbitrarily many files into it; without a cap
  // each one becomes a FileView and a retained parse result.
  readonly property int maxFiles: 256
  // Cap the size of each file we read. Files at or above this size are not
  // listed, so FileView never materializes an unboundedly large file.
  readonly property int maxFileBytes: 262144

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var openTasks: displayList.filter(function (t) { return !t.done })
  readonly property var doneTasks: displayList.filter(function (t) { return t.done })
  readonly property int doneCount: doneTasks.length

  // Expand "~" and strip trailing slashes, and require an absolute path so the
  // vault can never resolve relative to an unpredictable working directory or
  // start with "-" (which find would treat as an option).
  function canonicalizeVault(path) {
    var p = String(path == null ? "" : path).trim()
    if (p === "") return ""
    if (p === "~" || p.slice(0, 2) === "~/") {
      var home = Quickshell.env("HOME")
      if (typeof home !== "string" || home === "") return ""
      p = p === "~" ? home : home + p.slice(1)
    }
    p = p.replace(/\/+$/, "")
    if (p === "" || p.charAt(0) !== "/") return ""
    return p
  }

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

  function refresh() {
    if (!root.configured) {
      files = []
      fileData = ({})
      taskList = []
      displayList = []
      openCount = 0
      return
    }
    listProc.command = ["find", "-P", root.todosPath, "-maxdepth", "1", "-type", "f", "-size", "-" + root.maxFileBytes + "c", "-name", "*.md", "-printf", "%f\\n"]
    listProc.running = true
  }

  function applyFileList(raw) {
    var seen = String(raw || "").split("\n")
    var names = []
    for (var i = 0; i < seen.length; i++) {
      var n = seen[i]
      if (n === "") continue
      if (names.indexOf(n) === -1) names.push(n)
    }
    names.sort()
    if (names.length > root.maxFiles) names = names.slice(0, root.maxFiles)

    var key = names.join("\u0001")
    if (key === filesKey) return
    filesKey = key

    var list = []
    for (var j = 0; j < names.length; j++)
      list.push({ name: names[j], path: root.todosPath + "/" + names[j] })
    files = list
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
    var t = String(text || "").replace(/\r?\n/g, " ").replace(/^\s+|\s+$/g, "")
    t = Model.truncateTaskText(t)
    if (!root.configured || t === "") return
    addProc.run("- [ ] " + t, root.todosPath + "/" + root.inboxFile)
  }

  function submitQuick() {
    addTask(quickField.text)
    quickField.text = ""
  }

  function saveVault() {
    var path = String(vaultField.text || "").replace(/^\s+|\s+$/g, "").replace(/\/+$/, "")
    if (path === "") return
    persistSettings({ vaultPath: path })
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  readonly property string displayText: root.configured
    ? (root.openCount > 0 ? String(root.openCount) : "✓")
    : "!"

  Component.onCompleted: refresh()
  onTodosPathChanged: refresh()
  onOpenedChanged: if (root.opened) refresh()

  IpcHandler {
    target: "jeanhuit.todos"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh(): void { root.refresh() }
    function add(text: string): string { root.addTask(text); return "ok" }
    function count(): string { return String(root.openCount) }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFileList(String(text || ""))
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: addProc
    function run(line, path) {
      command = ["bash", "-c", 'mkdir -p "$(dirname "$2")" && printf "%s\\n" "$1" >> "$2"', "_", line, path]
      running = true
    }
    onExited: root.refresh()
    stderr: StdioCollector { waitForEnd: true }
  }

  FileView {
    id: dirWatcher
    path: root.configured ? root.todosPath : ""
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  Instantiator {
    model: root.files
    delegate: FileView {
      id: fileView
      required property var modelData
      readonly property string fname: modelData.name
      path: modelData.path
      watchChanges: true
      atomicWrites: true
      printErrors: false
      onLoaded: root.setFile(fname, modelData.path, text())
      onFileChanged: reload()
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
            text: modelData.text
            textFormat: Text.PlainText
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
            text: "📅 " + modelData.due
            textFormat: Text.PlainText
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
