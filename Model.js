// Obsidian-tasks markdown parsing and vault path validation. Kept Qt-free so
// it can be unit tested under node (node -e "var m=require('./Model.js'); ...").

var CHECKBOX = /^(\s*[-*]\s+\[)([ xX])(\]\s+)(.*)$/
var DUE = /📅\s*(\d{4}-\d{2}-\d{2})/
var CONTROL = /[\u0000-\u001f\u007f]/
// Characters that are structurally meaningful in the discovery pipeline:
// \u0000 is the find -print0 framing and \u0001 the files-list key joiner.
// Other control characters (including \n) inside a filename are harmless —
// NUL framing means they cannot forge separators, and filenames are never
// rendered — so they are allowed rather than turned into a denial of service.
var FRAMING = /[\u0000\u0001]/

// ---- vault filesystem validation --------------------------------------------
// These helpers encode the filesystem boundary rules used by Panel.qml. They
// are pure string predicates so the boundary logic itself can be unit tested.

var MAX_NAME_LENGTH = 255

// A single plain path segment: no separators, no traversal, no control
// characters. Returns the sanitized segment or null if unusable.
function validateSegment(v) {
  var s = String(v == null ? "" : v).trim()
  if (s === "" || s === "." || s === "..") return null
  if (s.indexOf("/") !== -1 || s.indexOf("\\") !== -1) return null
  if (CONTROL.test(s)) return null
  return s
}

// A discovered file path must sit directly inside todosPath and be a safe
// basename. Works on NUL-delimited find output where filenames may contain
// newlines. Returns { ok: true, name } or { ok: false, reason }.
function validateVaultPath(todosPath, p, maxNameLength) {
  var cap = maxNameLength || MAX_NAME_LENGTH
  var path = String(p == null ? "" : p)
  var prefix = String(todosPath == null ? "" : todosPath) + "/"
  if (path.lastIndexOf(prefix, 0) !== 0) return { ok: false, reason: "path escaped vault" }
  var name = path.slice(prefix.length)
  if (name === "" || name.length > cap) return { ok: false, reason: "overlong filename" }
  if (FRAMING.test(name)) return { ok: false, reason: "unexpected filename" }
  if (name === "." || name === ".." || name === "__proto__" || name.indexOf("/") !== -1)
    return { ok: false, reason: "unexpected filename" }
  return { ok: true, name: name }
}

// Parses `stat -c '%F:%s'` output (no dereference). Returns
// { ok: true, size } for regular files within maxBytes, otherwise
// { ok: false, reason }. "unparsable stat output" indicates malformed data
// (abort-worthy); other reasons are skip-worthy (e.g. symlink, too large).
function parseStatPayload(payload, maxBytes) {
  var s = String(payload == null ? "" : payload)
  var i = s.indexOf(":")
  if (i === -1) return { ok: false, reason: "unparsable stat output" }
  var type = s.slice(0, i)
  var size = parseInt(s.slice(i + 1), 10)
  if (type !== "regular file" && type !== "regular empty file")
    return { ok: false, reason: "not a regular file" }
  if (isNaN(size) || size < 0) return { ok: false, reason: "unparsable stat output" }
  if (maxBytes != null && size > maxBytes) return { ok: false, reason: "file too large" }
  return { ok: true, size: size }
}

function parseTasks(markdown) {
  var lines = String(markdown || "").split(/\r?\n/)
  var tasks = []
  for (var i = 0; i < lines.length; i++) {
    var t = parseTaskLine(lines[i], i)
    if (t) tasks.push(t)
  }
  return tasks
}

function parseTaskLine(line, lineNumber) {
  var m = CHECKBOX.exec(String(line == null ? "" : line))
  if (!m) return null
  var body = m[4]
  return {
    line: lineNumber,
    done: m[2] !== " ",
    text: displayText(body),
    due: dueDate(body),
    raw: line
  }
}

function displayText(body) {
  return String(body || "")
    .replace(DUE, "")
    .replace(/\s+/g, " ")
    .replace(/^\s+|\s+$/g, "")
}

function dueDate(body) {
  var m = DUE.exec(String(body || ""))
  return m ? m[1] : ""
}

function toggleTaskLine(line) {
  if (!CHECKBOX.test(String(line))) return null
  return String(line).replace(/^(\s*[-*]\s+\[)([ xX])(\]\s+)/, function (all, open, mark, close) {
    return open + (mark === " " ? "x" : " ") + close
  })
}

function toggleTaskIn(markdown, lineNumber) {
  var lines = String(markdown || "").split(/\r?\n/)
  if (lineNumber < 0 || lineNumber >= lines.length) return null
  var toggled = toggleTaskLine(lines[lineNumber])
  if (toggled === null) return null
  lines[lineNumber] = toggled
  return lines.join("\n")
}

function appendTask(markdown, text) {
  var base = String(markdown || "")
  var line = "- [ ] " + String(text || "").replace(/\r?\n/g, " ")
  if (base === "") return line
  return base + (/\n$/.test(base) ? "" : "\n") + line
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function dateKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function isOverdue(due, today) {
  return due !== "" && due < today
}

if (typeof module !== "undefined") {
  module.exports = {
    parseTasks: parseTasks,
    parseTaskLine: parseTaskLine,
    displayText: displayText,
    dueDate: dueDate,
    toggleTaskLine: toggleTaskLine,
    toggleTaskIn: toggleTaskIn,
    appendTask: appendTask,
    dateKey: dateKey,
    isOverdue: isOverdue,
    validateSegment: validateSegment,
    validateVaultPath: validateVaultPath,
    parseStatPayload: parseStatPayload
  }
}
