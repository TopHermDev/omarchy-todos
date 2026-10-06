#!/usr/bin/env bash
# Adversarial fixture exercising the plugin's filesystem-boundary guards:
# newline filenames, symlinked targets/directories, FIFOs, oversized files,
# and hostile argv. Run directly; exits non-zero if any check fails.
#
#   bash test/vault-fixture.sh
set -u

PASS=0
FAIL=0

note() { printf '%s\n' "== $1"; }
ok()   { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }

# check_exit <expected> <actual> <label>
check_exit() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (exit $2, expected $1)"; fi
}

here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/add-task.sh"
rscript="$here/replace-line.sh"
T=$(mktemp -d /tmp/todos-fixture-XXXXXX)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/vault/Todos" "$T/outside/realTodos"
target="$T/vault/Todos/inbox.md"
line="- [ ] planted"

# --- T1: normal append ------------------------------------------------------
note "T1 normal append"
printf -- '- [ ] existing\n' > "$target"
bash "$script" "$line" "$target" 2>/dev/null
check_exit 0 $? "append to existing file"
grep -q -- '- \[ \] planted' "$target" && ok "new task present" || bad "new task missing"

# --- T2: missing trailing newline gets fixed, not corrupted -----------------
note "T2 missing trailing newline"
printf -- '- [ ] a' > "$target"
bash "$script" "$line" "$target" 2>/dev/null
check_exit 0 $? "append without trailing newline"
[ "$(tail -n 1 "$target")" = "$line" ] && ok "task on its own line" || bad "line corrupted"

# --- T3: fresh target --------------------------------------------------------
note "T3 fresh target"
rm -f "$target"
bash "$script" "$line" "$target" 2>/dev/null
check_exit 0 $? "create new inbox"
[ "$(cat "$target")" = "$line" ] && ok "content exact" || bad "content wrong"

# --- T4: symlinked target refused, outside file untouched (O_NOFOLLOW eq) ---
note "T4 symlinked target refused"
rm -f "$target"
printf 'SECRET\n' > "$T/outside/secret.md"
ln -s "$T/outside/secret.md" "$target"
bash "$script" "$line" "$target" 2>/dev/null
check_exit 1 $? "symlink target refused"
[ "$(cat "$T/outside/secret.md")" = "SECRET" ] && ok "outside file untouched" || bad "outside file written"
[ -L "$target" ] && ok "symlink left in place" || bad "symlink clobbered"

# --- T5: filename with a real newline (NUL framing survives it) -------------
note "T5 newline filename"
nt="$T/vault/Todos/weird
filename.md"
printf -- '- [ ] n1\n' > "$nt"
bash "$script" "- [ ] n2" "$nt" 2>/dev/null
check_exit 0 $? "append to newline-named file"
grep -q -- '- \[ \] n2' "$nt" && ok "newline filename handled" || bad "newline filename broken"

# --- T6: symlinked Todos directory refused ----------------------------------
note "T6 symlinked Todos dir refused"
mkdir -p "$T/vaultB"
ln -s "$T/outside/realTodos" "$T/vaultB/Todos"
bash "$script" "$line" "$T/vaultB/Todos/todo.md" 2>/dev/null
check_exit 1 $? "symlinked parent dir refused"
[ -z "$(ls -A "$T/outside/realTodos")" ] && ok "nothing written outside" || bad "wrote outside vault"

# --- T7: missing parent directory refused -----------------------------------
note "T7 missing parent refused"
bash "$script" "$line" "$T/nonexistent/dir/todo.md" 2>/dev/null
check_exit 1 $? "missing parent refused"

# --- T8: symlinked parent below the target refused ---------------------------
note "T8 symlinked subpath parent refused"
mkdir -p "$T/vault/sub"
ln -s "$T/outside" "$T/vault/sub/down"
bash "$script" "$line" "$T/vault/sub/down/evil.md" 2>/dev/null
check_exit 1 $? "symlinked subpath refused"
if ls -A "$T/outside" | grep -q '^evil'; then bad "file created outside"; else ok "no file created outside"; fi

# --- T9: FIFO target refused --------------------------------------------------
note "T9 FIFO target refused"
rm -f "$target"
mkfifo "$target"
bash "$script" "$line" "$target" 2>/dev/null
check_exit 1 $? "FIFO target refused"
[ -p "$target" ] && ok "FIFO untouched" || bad "FIFO clobbered"

# --- T10: hostile task text is inert (argv only, no shell expansion) --------
note "T10 hostile task text"
rm -f "$target"
printf -- '- [ ] x\n' > "$target"
bash "$script" '$(reboot) `id` ; rm -rf /tmp/zzz ; " && | < > >' "$target" 2>/dev/null
check_exit 0 $? "hostile text append"
grep -qF '$(reboot) `id` ; rm -rf /tmp/zzz ; " && | < > >' "$target" \
  && ok "task text stored verbatim" || bad "task text mangled or executed"

# --- T11: permission bits preserved ------------------------------------------
note "T11 permissions preserved"
rm -f "$target"
printf -- '- [ ] x\n' > "$target"
chmod 644 "$target"
bash "$script" "$line" "$target" 2>/dev/null
[ "$(stat -c %a "$target")" = "644" ] && ok "mode kept" || bad "mode changed to $(stat -c %a "$target")"

# --- T12: oversized file rejected by Model.parseStatPayload ------------------
note "T12 size gate logic"
big="$T/vault/Todos/big.md"
head -c 2097152 /dev/zero > "$big"
payload=$(stat -c '%F:%s' "$big")
node -e '
  var m = require(process.argv[1] + "/Model.js");
  var r = m.parseStatPayload(process.argv[2], 1048576);
  process.exit(r.ok ? 1 : 0);
' "$here" "$payload" && ok "oversized file fails size gate" || bad "oversized file passed size gate"

# --- T13: normal line replace (CAS pass) -------------------------------------
note "T13 replace-line CAS pass"
printf -- '- [ ] one\n- [ ] two\n- [x] three\n' > "$target"
bash "$rscript" "$target" 1 '- [ ] two' '- [x] two' 2>/dev/null
check_exit 0 $? "replace accepted"
[ "$(sed -n 2p "$target")" = '- [x] two' ] && ok "line flipped" || bad "line not flipped"
grep -qx -- '- \[ \] one' "$target" && ok "other lines intact" || bad "other lines changed"

# --- T14: replace via symlinked target refused -------------------------------
note "T14 replace-line symlinked target refused"
rm -f "$target"
printf 'SECRET2\n' > "$T/outside/secret2.md"
ln -s "$T/outside/secret2.md" "$target"
bash "$rscript" "$target" 0 'SECRET2' 'PWNED' 2>/dev/null
check_exit 1 $? "symlink replace refused"
[ "$(cat "$T/outside/secret2.md")" = "SECRET2" ] && ok "outside file untouched" || bad "outside file written"
[ -L "$target" ] && ok "symlink left in place" || bad "symlink clobbered"

# --- T15: replace through symlinked Todos dir refused ------------------------
note "T15 replace-line symlinked parent refused"
rm -f "$target"
printf -- '- [ ] t\n' > "$T/outside/realTodos/todo.md"
bash "$rscript" "$T/vaultB/Todos/todo.md" 0 '- [ ] t' '- [x] t' 2>/dev/null
check_exit 1 $? "symlinked parent refused"
[ "$(cat "$T/outside/realTodos/todo.md")" = '- [ ] t' ] && ok "outside content untouched" || bad "outside content changed"

# --- T16: CAS mismatch refused (file changed under us) -----------------------
note "T16 CAS mismatch refused"
printf -- '- [ ] orig\n' > "$target"
bash "$rscript" "$target" 0 '- [ ] DIFFERENT' '- [x] orig' 2>/dev/null
check_exit 1 $? "stale expected refused"
[ "$(cat "$target")" = '- [ ] orig' ] && ok "file untouched" || bad "file overwritten"

# --- T17: bad line numbers refused -------------------------------------------
note "T17 line number guards"
printf -- '- [ ] only\n' > "$target"
bash "$rscript" "$target" abc '- [ ] only' '- [x] only' 2>/dev/null
check_exit 1 $? "non-numeric lineno refused"
bash "$rscript" "$target" 99 '- [ ] only' '- [x] only' 2>/dev/null
check_exit 1 $? "out-of-range lineno refused"
[ "$(cat "$target")" = '- [ ] only' ] && ok "file untouched" || bad "file changed"

# --- T18: CRLF line endings compared and round-tripped -----------------------
note "T18 CRLF preserved"
printf -- '- [ ] one\r\n- [ ] two\r\n' > "$target"
bash "$rscript" "$target" 1 $'- [ ] two\r' $'- [x] two\r' 2>/dev/null
check_exit 0 $? "CRLF CAS accepted"
grep -qF -- $'- [x] two\r' "$target" && ok "CR kept on replaced line" || bad "CR lost"

# --- T19: hostile replacement text inert (argv, no shell) ---------------------
note "T19 hostile replacement text"
printf -- '- [ ] x\n' > "$target"
bash "$rscript" "$target" 0 '- [ ] x' '$(reboot) `id` ; rm -rf /tmp/zzz' 2>/dev/null
check_exit 0 $? "hostile replacement accepted"
grep -qF -- '$(reboot) `id` ; rm -rf /tmp/zzz' "$target" && ok "stored verbatim" || bad "mangled or executed"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
