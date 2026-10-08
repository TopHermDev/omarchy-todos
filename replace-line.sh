#!/usr/bin/env bash
# Atomic, symlink-safe single-line replacement used by the todos plugin's
# checkbox toggle (the only write path besides add-task.sh's append).
# usage: replace-line.sh <target-file> <line-no-0-based>
#        stdin: line 1 = expected-line, line 2 = replacement-line
#
# Both lines travel on STDIN, never in argv: argv lives in
# /proc/<pid>/cmdline, which every local user can read (`ps`), so existing
# and replacement vault-task lines passed as arguments would be private
# content on display.
#
# The QML layer cannot use FileView.setText() for writes: Quickshell
# implements atomicWrites with QSaveFile, and QSaveFile resolves an
# EXISTING symlink before choosing the write target — a sync peer that
# plants <target> as a symlink would have the write redirected through it,
# outside the vault. Shell redirection (`>>`/`>`) has the same problem in
# every path component. So this script does the write itself:
#
#   1. refuses unless the target's parent is a REAL directory (stat does not
#      dereference, so a symlinked Todos/ is reported as "symbolic link")
#   2. refuses unless the target is an existing regular file (-L catches a
#      symlink even when it points at a regular file; O_NOFOLLOW equivalent)
#   3. compare-and-swaps: line <n> must still exactly equal <expected-line>
#      (the content the popup was rendered from). A file changed under us —
#      by a sync peer or a raced edit — is refused rather than overwritten.
#   4. stages the new content in a temp file with the target's permissions
#      and renames it over the target, so the write is atomic and the final
#      object is always a regular file inside the vault
#
# Lines are compared after the shell strips only the trailing newline (CR
# bytes are kept), so CRLF files compare and round-trip unchanged. Like
# add-task.sh, a missing final newline on the target is normalized to one.
# Residual TOCTOU between the stat/CAS checks and the rename is accepted
# here; the rename itself never follows a final-component symlink.
set -u

target=$1
lineno=$2

# Expected and replacement lines come from stdin, one per line (IFS= keeps
# leading/trailing spaces, -r keeps backslashes). Both must be present.
IFS= read -r expected || exit 1
IFS= read -r replacement || exit 1

# lineno must be a non-negative integer (0-based, matching Model.parseTasks)
# and short enough that bash arithmetic cannot overflow.
case $lineno in
  ''|*[!0-9]*) exit 1 ;;
esac
if [ ${#lineno} -gt 7 ]; then exit 1; fi

if [ -L "$target" ] || [ ! -f "$target" ]; then
  # Missing, symlinked, or not a regular file: refuse, write nothing.
  exit 1
fi

parent=$(dirname -- "$target")
if [ "$(stat -c %F -- "$parent")" != "directory" ]; then
  exit 1
fi

# Read every line (NUL bytes, if any, are dropped by bash — the CAS against
# <expected-line> then fails and we refuse, which is the safe direction).
mapfile -t lines < "$target"

# Bounds: lineno must index a line that actually exists on disk (the disk
# may differ from the rendered view — that is the point of re-reading here).
if [ "$lineno" -ge "${#lines[@]}" ]; then
  exit 1
fi

# Compare-and-swap: the line must still be exactly what we rendered.
if [ "${lines[$lineno]}" != "$expected" ]; then
  exit 1
fi

lines[$lineno]=$replacement

tmp=$(mktemp "/tmp/.todos-XXXXXX") || exit 1
printf '%s\n' "${lines[@]}" > "$tmp" || { rm -f -- "$tmp"; exit 1; }

# Keep the target's permission bits (mktemp creates 0600).
chmod --reference="$target" -- "$tmp" 2>/dev/null || true

mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; exit 1; }
