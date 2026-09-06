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
