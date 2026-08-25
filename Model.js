// Obsidian-tasks markdown parsing. Kept Qt-free so it can be unit tested
// under node (node -e "var m=require('./Model.js'); ...").

var CHECKBOX = /^(\s*[-*]\s+\[)([ xX])(\]\s+)(.*)$/
var DUE = /📅\s*(\d{4}-\d{2}-\d{2})/

// Resource bounds. The vault is populated by sync tools, so a peer can drop
// arbitrarily large files or many files into it. Cap how much we parse and
// retain so a synced peer cannot exhaust the long-lived shell.
var MAX_PARSE_CHARS = 512 * 1024
var MAX_PARSE_LINES = 10000
var MAX_TASKS = 1000
var MAX_TASK_CHARS = 2000

function parseTasks(markdown) {
  var text = String(markdown || "")
  if (text.length > MAX_PARSE_CHARS) text = text.slice(0, MAX_PARSE_CHARS)
  var lines = text.split(/\r?\n/)
  var tasks = []
  var n = lines.length < MAX_PARSE_LINES ? lines.length : MAX_PARSE_LINES
  for (var i = 0; i < n; i++) {
    var t = parseTaskLine(lines[i], i)
    if (t) {
      tasks.push(t)
      if (tasks.length >= MAX_TASKS) break
    }
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

// Reduce a user-supplied setting to a single safe directory/file name. Strips
// path separators and control characters, then leading dots and dashes so the
// result can't be absolute, hidden, a parent reference (".."), or a command
// option ("-"). Falls back when nothing safe remains.
function sanitizeComponent(value, fallback) {
  var s = String(value == null ? "" : value).trim()
  s = s.replace(/[\\\/\x00-\x1f]+/g, "")
  s = s.replace(/^[.\-]+/, "")
  if (s === "") s = fallback
  return s
}

// Bound the length of a single task before it is written to disk.
function truncateTaskText(text) {
  var s = String(text == null ? "" : text)
  if (s.length > MAX_TASK_CHARS) s = s.slice(0, MAX_TASK_CHARS)
  return s
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
    sanitizeComponent: sanitizeComponent,
    truncateTaskText: truncateTaskText
  }
}
