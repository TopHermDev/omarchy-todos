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

var MAX_TASK_LENGTH = 512

// Quick-add text arrives from IPC/UI and is unbounded: flatten to a single
// line (newlines would forge extra task lines), collapse whitespace, and cap
// the length. Returns the sanitized text or null if unusable.
function sanitizeTaskText(text, maxLen) {
  var s = String(text == null ? "" : text).replace(/[\r\n\t]+/g, " ")
  s = s.replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  if (s === "") return null
  if (maxLen != null && s.length > maxLen) return null
  return s
}

// Resource bounds for parsing. The vault is populated by sync tools, so a
// peer can drop arbitrarily large files into it; even with the 1 MiB stat
// gate, bound how much is parsed and retained so the long-lived shell cannot
// be exhausted by checkbox spam.
var MAX_PARSE_CHARS = 512 * 1024
var MAX_PARSE_LINES = 10000
var MAX_TASKS = 1000

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

// ---- natural-language due dates (quick-add) ----------------------------------
// Matches a date expression at the END of the task text ("ship report
// friday") and returns the stripped text plus the resolved 📅 date, or
// null when the text carries no date. Deterministic: `today` is the
// caller's dateKey, never read from the clock here.
// Semantics (documented in README):
//   today                  -> today
//   tomorrow / tmrw        -> today + 1
//   in N days / N weeks    -> today + N / N*7
//   <weekday>              -> next occurrence strictly after today (1-7 days)
//   next <weekday>         -> the occurrence after that (+7 more)
// Text that already contains 📅, or that is nothing but a date word
// ("remind me: tomorrow"), is left alone.
var WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
var NATURAL_DUE = /(?:^|\s)(next\s+)?(today|tomorrow|tmrw|in\s+\d{1,3}\s+(?:day|days|week|weeks)|sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|weds|wed|thurs|thur|thu|fri|sat)\s*[.!?]?$/i

function addDaysKey(today, n) {
  var p = today.split("-")
  var d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]) + n)
  return dateKey(d)
}

function naturalDue(text, today) {
  var s = String(text == null ? "" : text)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(today == null ? "" : today))) return null
  if (s.indexOf("📅") !== -1) return null
  var m = NATURAL_DUE.exec(s)
  if (!m) return null
  var body = s.slice(0, m.index).replace(/\s+$/g, "")
  if (body === "") return null
  var hasNext = !!m[1]
  var kw = m[2].toLowerCase().replace(/\s+/g, " ")
  var due = ""
  if (kw === "today") due = today
  else if (kw === "tomorrow" || kw === "tmrw") due = addDaysKey(today, 1)
  else if (kw.indexOf("in ") === 0) {
    var im = /in\s+(\d{1,3})\s+(day|days|week|weeks)/.exec(kw)
    due = addDaysKey(today, Number(im[1]) * (im[2].charAt(0) === "w" ? 7 : 1))
  } else {
    var name = { sun: "sunday", mon: "monday", tues: "tuesday", tue: "tuesday",
                 weds: "wednesday", wed: "wednesday", thurs: "thursday",
                 thur: "thursday", thu: "thursday", fri: "friday", sat: "saturday" }[kw] || kw
    var target = WEEKDAYS.indexOf(name)
    var delta = (target - new Date(Number(today.slice(0, 4)), Number(today.slice(5, 7)) - 1, Number(today.slice(8, 10))).getDay() + 7) % 7
    if (delta === 0) delta = 7 // a plain weekday never means today
    if (hasNext) delta += 7
    due = addDaysKey(today, delta)
  }
  return { text: body, due: due }
}

// Full quick-add pipeline as one testable unit: flatten/cap the raw input,
// convert a trailing natural-language date, then re-apply the length cap so
// the INVARIANT holds — a task written to the vault never exceeds maxLen,
// even after a date suffix is appended. Falls back to the undated text when
// the date would push it over.
function applyNaturalDue(text, today, maxLen) {
  var t = sanitizeTaskText(text, maxLen)
  if (t === null) return null
  var nd = naturalDue(t, today)
  if (nd !== null) {
    var dated = nd.text + " 📅 " + nd.due
    if (dated.length <= maxLen) return dated
  }
  return t
}

// ---- tags and filtering (popup) ----------------------------------------------
// Obsidian-style #tags in task text: preceded by start-of-text or
// whitespace, must begin with a letter (so "#123" and "url#frag" never
// match), chars [A-Za-z0-9_-]. Returns unique tags, bounded.
var MAX_TAGS = 32
var TAG = /(?:^|\s)#([A-Za-z][A-Za-z0-9_-]*)/g

function taskTags(text) {
  var s = String(text == null ? "" : text)
  var out = []
  TAG.lastIndex = 0
  var m
  while ((m = TAG.exec(s)) !== null) {
    if (out.indexOf(m[1]) === -1) {
      out.push(m[1])
      if (out.length >= MAX_TAGS) break
    }
  }
  return out
}

// Pure filter over an already-built task list. kind: "all" | "file" | "tag".
// "file" matches the task's source filename (with .md); "tag" matches a
// #tag in the task text. Returns a new array; never mutates.
function filterTasks(tasks, kind, value) {
  var list = tasks || []
  if (kind === "file") {
    var v = String(value == null ? "" : value)
    return list.filter(function (t) { return t && t.file === v })
  }
  if (kind === "tag") {
    var tag = String(value == null ? "" : value)
    if (tag === "") return list.slice()
    return list.filter(function (t) { return t && taskTags(t.text).indexOf(tag) !== -1 })
  }
  return list.slice()
}

// Group a task list by source file for sectioned popup display: one entry
// per file, tasks kept in the order given (already sorted overdue-first).
// Group order = first appearance, so the file holding the most urgent task
// leads. Label is the filename without .md ("school.md" -> "school").
function groupByFile(tasks) {
  var list = tasks || []
  var keys = []
  var byFile = {}
  for (var i = 0; i < list.length; i++) {
    var t = list[i]
    if (!t) continue
    var k = "f\u0001" + t.file // prefix guards against __proto__-style keys
    if (byFile[k] === undefined) {
      byFile[k] = []
      keys.push(t.file)
    }
    byFile[k].push(t)
  }
  var out = []
  for (var j = 0; j < keys.length; j++) {
    out.push({ file: keys[j], label: keys[j].replace(/\.md$/, ""), tasks: byFile["f\u0001" + keys[j]] })
  }
  return out
}

// Summarize open tasks for the bar display: total open, how many are
// overdue relative to `today` (a dateKey string), and the earliest due
// date among open tasks that is not overdue ("" when none). Done tasks
// are ignored entirely.
function summarize(tasks, today) {
  var open = 0
  var overdue = 0
  var nextDue = ""
  var list = tasks || []
  for (var i = 0; i < list.length; i++) {
    var t = list[i]
    if (!t || t.done) continue
    open++
    if (isOverdue(t.due, today)) overdue++
    else if (t.due !== "" && (nextDue === "" || t.due < nextDue)) nextDue = t.due
  }
  return { open: open, overdue: overdue, nextDue: nextDue }
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
    sanitizeTaskText: sanitizeTaskText,
    dateKey: dateKey,
    isOverdue: isOverdue,
    summarize: summarize,
    naturalDue: naturalDue,
    applyNaturalDue: applyNaturalDue,
    taskTags: taskTags,
    filterTasks: filterTasks,
    groupByFile: groupByFile,
    MAX_TAGS: MAX_TAGS,
    validateSegment: validateSegment,
    validateVaultPath: validateVaultPath,
    parseStatPayload: parseStatPayload,
    MAX_TASK_LENGTH: MAX_TASK_LENGTH,
    MAX_PARSE_CHARS: MAX_PARSE_CHARS,
    MAX_PARSE_LINES: MAX_PARSE_LINES,
    MAX_TASKS: MAX_TASKS
  }
}
