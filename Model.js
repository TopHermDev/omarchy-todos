// Obsidian-tasks markdown parsing. Kept Qt-free so it can be unit tested
// under node (node -e "var m=require('./Model.js'); ...").

var CHECKBOX = /^(\s*[-*]\s+\[)([ xX])(\]\s+)(.*)$/
var DUE = /📅\s*(\d{4}-\d{2}-\d{2})/

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
    isOverdue: isOverdue
  }
}
