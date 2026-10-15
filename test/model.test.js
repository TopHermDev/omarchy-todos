// Unit tests for Model.js: markdown parsing plus the filesystem-boundary
// validators used by Panel.qml. Run with: node test/model.test.js
var m = require("../Model.js")
var assert = require("assert")

var passed = 0
function t(name, fn) {
  try {
    fn()
    passed++
    console.log("ok: " + name)
  } catch (e) {
    console.log("FAIL: " + name)
    console.log("  " + (e && e.message ? e.message : e))
    process.exitCode = 1
  }
}

// ---- markdown parsing (regression) -------------------------------------------
t("parseTasks basic", function () {
  var t = m.parseTasks("- [ ] a\n- [x] b\n- [ ] c 📅 2026-08-23")
  assert.strictEqual(t.length, 3)
  assert.strictEqual(t[2].due, "2026-08-23")
  assert.strictEqual(t[1].done, true)
})
t("toggleTaskIn round trip", function () {
  assert.strictEqual(m.toggleTaskIn("- [ ] a\n- [x] b", 0), "- [x] a\n- [x] b")
  assert.strictEqual(m.toggleTaskIn("- [ ] a", 5), null)
  assert.strictEqual(m.toggleTaskIn("not a task", 0), null)
})
t("appendTask newline handling", function () {
  assert.strictEqual(m.appendTask("", "x"), "- [ ] x")
  assert.strictEqual(m.appendTask("- [ ] a", "x"), "- [ ] a\n- [ ] x")
  assert.strictEqual(m.appendTask("- [ ] a\n", "x"), "- [ ] a\n- [ ] x")
})
t("multiline task text flattened", function () {
  var tasks = m.parseTasks(m.appendTask("", "one\ntwo"))
  assert.strictEqual(tasks.length, 1)
  assert.strictEqual(tasks[0].text, "one two")
})

// ---- sanitizeTaskText ------------------------------------------------------------
t("task text: flatten newlines/tabs and collapse whitespace", function () {
  assert.strictEqual(m.sanitizeTaskText("one\ntwo"), "one two")
  assert.strictEqual(m.sanitizeTaskText("- [ ] a\n- [x] b"), "- [ ] a - [x] b", "newline cannot forge task lines")
  assert.strictEqual(m.sanitizeTaskText("a\t\tb\nc  d"), "a b c d")
})
t("task text: trims and rejects empty", function () {
  assert.strictEqual(m.sanitizeTaskText("   "), null)
  assert.strictEqual(m.sanitizeTaskText("\n\r\n"), null)
  assert.strictEqual(m.sanitizeTaskText(""), null)
  assert.strictEqual(m.sanitizeTaskText(null), null)
  assert.strictEqual(m.sanitizeTaskText("  hi  "), "hi")
})
t("task text: length cap", function () {
  assert.strictEqual(m.sanitizeTaskText("x".repeat(513), 512), null)
  assert.strictEqual(m.sanitizeTaskText("x".repeat(512), 512), "x".repeat(512))
  assert.strictEqual(m.sanitizeTaskText("\n" + "x".repeat(513) + "\n", 512), null, "cap applies after flattening")
})
t("task text: default cap constant exists", function () {
  assert.strictEqual(typeof m.MAX_TASK_LENGTH, "number")
  assert.ok(m.MAX_TASK_LENGTH >= 128 && m.MAX_TASK_LENGTH <= 4096)
})

// ---- parse bounds -----------------------------------------------------------------
t("parseTasks: line/char/task caps bound output", function () {
  var big = ""
  for (var i = 0; i < 20000; i++) big += "- [ ] task " + i + "\n"
  assert.strictEqual(m.parseTasks(big).length, m.MAX_TASKS)
  var halfMeg = "x".repeat(600 * 1024) + "\n- [ ] after cap"
  assert.strictEqual(m.parseTasks(halfMeg).length, 0, "checkbox beyond char cap is not parsed")
})
t("parseTasks: normal files unaffected by caps", function () {
  var small = "- [ ] a\n- [x] b\n- [ ] c"
  assert.strictEqual(m.parseTasks(small).length, 3)
})

// ---- summarize (bar summary) --------------------------------------------------
var TODAY = "2026-10-15"
function task(done, due) { return { done: done, due: due || "" } }
t("summarize: counts open, overdue, and next due", function () {
  var s = m.summarize([
    task(false, "2026-10-10"), // overdue
    task(false, "2026-10-15"), // due today: not overdue, and earliest not-overdue
    task(false, "2026-10-20"),
    task(false, "2026-10-18"),
    task(false, ""),           // no due date
    task(true, "2026-10-01")   // done, ignored even though past
  ], TODAY)
  assert.deepStrictEqual(s, { open: 5, overdue: 1, nextDue: "2026-10-15" })
})
t("summarize: all done yields zeroed summary", function () {
  assert.deepStrictEqual(m.summarize([task(true, "2026-10-01")], TODAY), { open: 0, overdue: 0, nextDue: "" })
})
t("summarize: empty/null input safe", function () {
  assert.deepStrictEqual(m.summarize([], TODAY), { open: 0, overdue: 0, nextDue: "" })
  assert.deepStrictEqual(m.summarize(null, TODAY), { open: 0, overdue: 0, nextDue: "" })
})
t("summarize: string ordering matches date ordering", function () {
  // Guards against lexicographic surprises being relied on elsewhere.
  assert.ok(m.dateKey(new Date(2026, 0, 5)) < m.dateKey(new Date(2026, 11, 31)))
  var s = m.summarize([task(false, "2026-12-31"), task(false, "2026-01-05")], "2026-06-01")
  assert.strictEqual(s.overdue, 1, "January date is overdue relative to June")
  assert.strictEqual(s.nextDue, "2026-12-31", "future date is nextDue, past one is not")
})

// ---- naturalDue (natural-language quick-add) ----------------------------------
// Reference: 2026-10-15 is a Thursday.
var TD = "2026-10-15"
t("naturalDue: today/tomorrow/tmrw", function () {
  assert.deepStrictEqual(m.naturalDue("water plants today", TD), { text: "water plants", due: "2026-10-15" })
  assert.deepStrictEqual(m.naturalDue("water plants tomorrow", TD), { text: "water plants", due: "2026-10-16" })
  assert.deepStrictEqual(m.naturalDue("water plants tmrw", TD), { text: "water plants", due: "2026-10-16" })
})
t("naturalDue: in N days/weeks", function () {
  assert.deepStrictEqual(m.naturalDue("file report in 3 days", TD), { text: "file report", due: "2026-10-18" })
  assert.deepStrictEqual(m.naturalDue("file report in 2 weeks", TD), { text: "file report", due: "2026-10-29" })
  assert.deepStrictEqual(m.naturalDue("file report in 1 day", TD), { text: "file report", due: "2026-10-16" })
})
t("naturalDue: weekday rolls forward, never today", function () {
  // Thu -> fri is +1 (tomorrow); thu (same day) is +7, never today.
  assert.deepStrictEqual(m.naturalDue("ship report friday", TD), { text: "ship report", due: "2026-10-16" })
  assert.deepStrictEqual(m.naturalDue("ship report monday", TD), { text: "ship report", due: "2026-10-19" })
  assert.deepStrictEqual(m.naturalDue("ship report thursday", TD), { text: "ship report", due: "2026-10-22" })
})
t("naturalDue: 'next' weekday is one week further", function () {
  assert.deepStrictEqual(m.naturalDue("ship report next friday", TD), { text: "ship report", due: "2026-10-23" })
  assert.deepStrictEqual(m.naturalDue("ship report next monday", TD), { text: "ship report", due: "2026-10-26" })
})
t("naturalDue: abbreviations and case", function () {
  assert.deepStrictEqual(m.naturalDue("taxes Fri", TD), { text: "taxes", due: "2026-10-16" })
  assert.deepStrictEqual(m.naturalDue("taxes TUE", TD), { text: "taxes", due: "2026-10-20" })
  assert.deepStrictEqual(m.naturalDue("taxes NEXT Friday", TD), { text: "taxes", due: "2026-10-23" })
})
t("naturalDue: trailing punctuation tolerated", function () {
  assert.deepStrictEqual(m.naturalDue("ship it tomorrow.", TD), { text: "ship it", due: "2026-10-16" })
  assert.deepStrictEqual(m.naturalDue("ship it friday!", TD), { text: "ship it", due: "2026-10-16" })
})
t("naturalDue: no false positives mid-text or on plain tasks", function () {
  assert.strictEqual(m.naturalDue("buy milk", TD), null)
  assert.strictEqual(m.naturalDue("friday planning notes are done", TD), null, "weekday not at end")
  assert.strictEqual(m.naturalDue("read the friday report", TD), null)
  assert.strictEqual(m.naturalDue("call mom 555-1234", TD), null)
})
t("naturalDue: refuses ambiguous or protected input", function () {
  assert.strictEqual(m.naturalDue("tomorrow", TD), null, "date word alone is not a task")
  assert.strictEqual(m.naturalDue("friday", TD), null)
  assert.strictEqual(m.naturalDue("deploy 📅 2026-11-01 tomorrow", TD), null, "explicit 📅 wins")
  assert.strictEqual(m.naturalDue("ship tomorrow", "not-a-date"), null, "bogus today key")
  assert.strictEqual(m.naturalDue(null, TD), null)
})
t("naturalDue: month boundary arithmetic", function () {
  assert.deepStrictEqual(m.naturalDue("clean garage tomorrow", "2026-10-31"), { text: "clean garage", due: "2026-11-01" })
  assert.deepStrictEqual(m.naturalDue("clean garage in 2 weeks", "2026-12-25"), { text: "clean garage", due: "2027-01-08" })
  assert.deepStrictEqual(m.naturalDue("clean garage friday", "2026-02-28"), { text: "clean garage", due: "2026-03-06" })
})
t("naturalDue: round trip through appendTask parses back with the date", function () {
  var nd = m.naturalDue("buy milk tomorrow", TD)
  var parsed = m.parseTasks(m.appendTask("", nd.text + " 📅 " + nd.due))
  assert.strictEqual(parsed[0].text, "buy milk")
  assert.strictEqual(parsed[0].due, "2026-10-16")
})
t("applyNaturalDue: full pipeline, dated output", function () {
  assert.strictEqual(m.applyNaturalDue("buy milk tomorrow", TD, m.MAX_TASK_LENGTH), "buy milk 📅 2026-10-16")
  assert.strictEqual(m.applyNaturalDue("plain task", TD, m.MAX_TASK_LENGTH), "plain task")
  assert.strictEqual(m.applyNaturalDue("has 📅 2026-01-01 already tomorrow", TD, m.MAX_TASK_LENGTH),
    "has 📅 2026-01-01 already tomorrow", "explicit date blocks conversion")
})
t("applyNaturalDue: length cap holds even after date append", function () {
  // The old pipeline sanitized to 512 then appended 7+ chars, overshooting
  // the cap. Now the dated form must fit within maxLen or be dropped.
  var text = "y".repeat(m.MAX_TASK_LENGTH - 7) + " friday" // exactly maxLen
  var out = m.applyNaturalDue(text, TD, m.MAX_TASK_LENGTH)
  assert.ok(out.length <= m.MAX_TASK_LENGTH, "dated output within cap, got " + out.length)
  assert.strictEqual(out.indexOf("📅"), -1, "oversized dated form falls back to undated")
  // Just under the limit with room for the suffix: date survives.
  var short = "z".repeat(m.MAX_TASK_LENGTH - 20) + " friday"
  var out2 = m.applyNaturalDue(short, TD, m.MAX_TASK_LENGTH)
  assert.ok(out2.indexOf("📅 2026-10-16") !== -1, "fits: date appended")
  assert.ok(out2.length <= m.MAX_TASK_LENGTH)
})
t("applyNaturalDue: rejects empty/oversize like sanitizeTaskText", function () {
  assert.strictEqual(m.applyNaturalDue("   ", TD, m.MAX_TASK_LENGTH), null)
  assert.strictEqual(m.applyNaturalDue("x".repeat(m.MAX_TASK_LENGTH + 1), TD, m.MAX_TASK_LENGTH), null)
  assert.strictEqual(m.applyNaturalDue(null, TD, m.MAX_TASK_LENGTH), null)
})

// ---- taskTags / filterTasks (popup filtering) ---------------------------------
t("taskTags: extracts, dedupes, requires word boundary + letter", function () {
  assert.deepStrictEqual(m.taskTags("fix #bug-a and #bug-a again #work"), ["bug-a", "work"])
  assert.deepStrictEqual(m.taskTags("#lead and #tag in middle"), ["lead", "tag"])
  assert.deepStrictEqual(m.taskTags("C# and url#frag and #123 stay put"), [], "no word-boundary letter match")
  assert.deepStrictEqual(m.taskTags(""), [])
  assert.deepStrictEqual(m.taskTags(null), [])
})
t("taskTags: bounded", function () {
  var many = ""
  for (var i = 0; i < 100; i++) many += " #t" + i
  assert.strictEqual(m.taskTags(many).length, m.MAX_TAGS)
})
t("filterTasks: by file, tag, and all", function () {
  var list = [
    { file: "inbox.md", text: "milk #errand" },
    { file: "work.md", text: "report #deep" },
    { file: "inbox.md", text: "gift #errand #home" }
  ]
  assert.strictEqual(m.filterTasks(list, "file", "inbox.md").length, 2)
  assert.strictEqual(m.filterTasks(list, "tag", "errand").length, 2)
  assert.strictEqual(m.filterTasks(list, "tag", "deep").length, 1)
  assert.strictEqual(m.filterTasks(list, "all", "").length, 3)
  assert.strictEqual(m.filterTasks(list, "tag", "nope").length, 0)
})
t("filterTasks: returns new array, tolerates junk", function () {
  var list = [{ file: "a.md", text: "x" }]
  assert.notStrictEqual(m.filterTasks(list, "all", ""), list)
  assert.deepStrictEqual(m.filterTasks(null, "tag", "x"), [])
  assert.deepStrictEqual(m.filterTasks([null, { file: "a.md", text: "y" }], "file", "a.md").length, 1, "null entries skipped")
})
t("groupByFile: groups by file, keeps order, strips .md label", function () {
  var list = [
    { file: "work.md", text: "a" },
    { file: "home.md", text: "b" },
    { file: "work.md", text: "c" }
  ]
  var g = m.groupByFile(list)
  assert.strictEqual(g.length, 2)
  assert.strictEqual(g[0].file, "work.md", "first appearance leads")
  assert.strictEqual(g[0].label, "work")
  assert.deepStrictEqual(g[0].tasks.map(function (t) { return t.text }), ["a", "c"], "in-order within group")
  assert.strictEqual(g[1].label, "home")
  assert.strictEqual(g[1].tasks.length, 1)
})
t("groupByFile: empty and junk input", function () {
  assert.deepStrictEqual(m.groupByFile([]), [])
  assert.deepStrictEqual(m.groupByFile(null), [])
  var g = m.groupByFile([null, { file: "a.md", text: "x" }])
  assert.strictEqual(g.length, 1)
  assert.strictEqual(g[0].tasks.length, 1)
})
t("groupByFile: hostile filenames cannot forge group keys", function () {
  var g = m.groupByFile([{ file: "__proto__", text: "x" }, { file: "constructor", text: "y" }])
  assert.strictEqual(g.length, 2, "both kept as plain groups")
  assert.strictEqual(g[0].tasks.length, 1)
  assert.strictEqual(g[1].tasks.length, 1)
})

// ---- validateSegment -----------------------------------------------------------
t("segment: plain names accepted", function () {
  assert.strictEqual(m.validateSegment("inbox.md"), "inbox.md")
  assert.strictEqual(m.validateSegment("Todos"), "Todos")
  assert.strictEqual(m.validateSegment("  Todos "), "Todos")
  assert.strictEqual(m.validateSegment("a b"), "a b")
})
t("segment: traversal and separators rejected", function () {
  assert.strictEqual(m.validateSegment(""), null)
  assert.strictEqual(m.validateSegment(null), null)
  assert.strictEqual(m.validateSegment("."), null)
  assert.strictEqual(m.validateSegment(".."), null)
  assert.strictEqual(m.validateSegment("a/b"), null)
  assert.strictEqual(m.validateSegment("a\\b"), null)
})
t("segment: control characters rejected", function () {
  assert.strictEqual(m.validateSegment("a\nb"), null)
  assert.strictEqual(m.validateSegment("a\tb"), null)
  assert.strictEqual(m.validateSegment("a\u0000b"), null)
})

// ---- validateVaultPath ----------------------------------------------------------
var TP = "/home/u/vault/Todos"
t("path: contained basename accepted", function () {
  assert.deepStrictEqual(m.validateVaultPath(TP, TP + "/inbox.md"), { ok: true, name: "inbox.md" })
})
t("path: newline filename accepted under NUL framing", function () {
  assert.deepStrictEqual(m.validateVaultPath(TP, TP + "/weird\nfilename.md"), { ok: true, name: "weird\nfilename.md" })
})
t("path: escapes rejected", function () {
  assert.strictEqual(m.validateVaultPath(TP, TP + "/../secret.txt").ok, false)
  assert.strictEqual(m.validateVaultPath(TP, TP + "2/file.md").ok, false)
  assert.strictEqual(m.validateVaultPath(TP, TP).ok, false)
  assert.strictEqual(m.validateVaultPath(TP, "/etc/passwd").ok, false)
})
t("path: subpaths and traversal basenames rejected", function () {
  assert.strictEqual(m.validateVaultPath(TP, TP + "/sub/dir.md").ok, false)
  assert.strictEqual(m.validateVaultPath(TP, TP + "/.").ok, false)
  assert.strictEqual(m.validateVaultPath(TP, TP + "/..").ok, false)
})
t("path: hostile basenames rejected", function () {
  assert.strictEqual(m.validateVaultPath(TP, TP + "/a\u0000b").ok, false)
  assert.strictEqual(m.validateVaultPath(TP, TP + "/a\u0001b").ok, false)
  assert.strictEqual(m.validateVaultPath(TP, TP + "/__proto__").ok, false)
  assert.strictEqual(m.validateVaultPath(TP, TP + "/a" + "x".repeat(300) + ".md").ok, false)
})

// ---- parseStatPayload -----------------------------------------------------------
var CAP = 1048576
t("stat: regular file within cap", function () {
  assert.deepStrictEqual(m.parseStatPayload("regular file:17", CAP), { ok: true, size: 17 })
  assert.deepStrictEqual(m.parseStatPayload("regular empty file:0", CAP), { ok: true, size: 0 })
})
t("stat: symlinks, directories, and other types rejected", function () {
  assert.strictEqual(m.parseStatPayload("symbolic link:31", CAP).ok, false)
  assert.strictEqual(m.parseStatPayload("directory:60", CAP).ok, false)
  assert.strictEqual(m.parseStatPayload("fifo file:0", CAP).ok, false)
  assert.strictEqual(m.parseStatPayload("socket:0", CAP).ok, false)
})
t("stat: size gate", function () {
  assert.strictEqual(m.parseStatPayload("regular file:999999999", CAP).ok, false)
  assert.strictEqual(m.parseStatPayload("regular file:" + CAP, CAP).ok, true, "exactly at cap is fine")
})
t("stat: malformed payloads abort-worthy", function () {
  assert.strictEqual(m.parseStatPayload("garbage", CAP).reason, "unparsable stat output")
  assert.strictEqual(m.parseStatPayload("regular file:abc", CAP).reason, "unparsable stat output")
  assert.strictEqual(m.parseStatPayload("regular file:-5", CAP).reason, "unparsable stat output")
  assert.strictEqual(m.parseStatPayload("", CAP).reason, "unparsable stat output")
})

console.log("\n" + passed + " passed")
