#!/usr/bin/env bash
# Atomic, symlink-safe single-line deletion used by the todos plugin's
# delete action (sibling of replace-line.sh).
# usage: remove-line.sh <target-file> <line-no-0-based>
#        stdin: line 1 = expected-line (the line being deleted)
#
# The expected line travels on STDIN, never in argv: argv lives in
# /proc/<pid>/cmdline, which every local user can read (`ps`), so a vault
# task line passed as an argument would be private content on display.
#
# Same boundary rules as the sibling helpers:
#   1. refuses unless the target's parent is a REAL directory (stat does
#      not dereference — a symlinked Todos/ is reported as "symbolic link")
#   2. refuses unless the target is an existing regular file (-L catches a
#      symlink even when it points at a regular file; O_NOFOLLOW equivalent)
#   3. compare-and-swaps: line <n> must still exactly equal <expected-line>,
#      so an edit from a sync peer is refused, not overwritten by a stale
#      delete
#   4. stages the remaining content in a 0600 temp file, renames it over
#      the target, then re-applies the target's mode AFTER the rename (a
#      loosened staging file in /tmp would be cross-user readable before mv)
#
# Lines are compared after the shell strips only the trailing newline (CR
# bytes are kept), so CRLF files compare and round-trip unchanged. Residual
# TOCTOU between the checks and the rename is accepted here; the rename
# itself never follows a final-component symlink.
set -u

target=$1
lineno=$2

# The expected line comes from stdin (IFS= keeps leading/trailing spaces,
# -r keeps backslashes). No stdin line = refuse. -t 10 bounds the wait so a
# helper whose caller died before writing exits instead of blocking forever.
IFS= read -r -t 10 expected || exit 1

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

mapfile -t lines < "$target"

# Bounds + compare-and-swap: the line must still be exactly what we
# rendered before we remove it.
if [ "$lineno" -ge "${#lines[@]}" ]; then
  exit 1
fi
if [ "${lines[$lineno]}" != "$expected" ]; then
  exit 1
fi

# Drop exactly that one line. `unset` leaves a hole; array expansion skips
# holes, so the re-serialized file is dense.
unset 'lines[$lineno]'

tmp=$(mktemp "/tmp/.todos-XXXXXX") || exit 1
if [ "${#lines[@]}" -gt 0 ]; then
  # Zero lines left means an empty file — mktemp's output is already empty,
  # so no stray newline is written.
  printf '%s\n' "${lines[@]}" > "$tmp" || { rm -f -- "$tmp"; exit 1; }
fi

# Capture the target's mode BEFORE the swap. The staging file must stay at
# mktemp's 0600 until it is inside the vault: loosening it to (say) 0644
# first would expose the whole note to other local accounts through the
# world-searchable /tmp path in the window before mv. The mode is applied
# AFTER the rename, where the vault's directory protection already covers
# it (the mode itself is still read from the pre-swap target — same
# accepted TOCTOU class as the checks above, bounded to a permission byte).
mode=$(stat -c %a -- "$target" 2>/dev/null || true)

mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; exit 1; }

if [ -n "$mode" ]; then
  chmod "$mode" -- "$target" 2>/dev/null || true
fi
