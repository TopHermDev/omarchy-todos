#!/usr/bin/env bash
# Atomic, symlink-safe task append used by the todos plugin's quick-add.
# usage: add-task.sh <target-file>        (task line arrives on stdin, one line)
#
# The task text travels on STDIN, never in argv: argv lives in
# /proc/<pid>/cmdline, which every local user can read (`ps`), so a task
# line passed as an argument would be private-vault content on display.
#
# Why not `echo "$1" >> "$2"`? Shell redirection opens the target *through*
# any symlink in every path component, so a planted inbox.md symlink (or a
# swapped Todos/ directory) would redirect the write outside the configured
# vault.
#
# This script instead:
#   1. refuses unless the target's parent is a REAL directory (stat does not
#      dereference, so a symlinked Todos/ is reported as "symbolic link")
#   2. refuses if the target exists and is not a regular file (a planted
#      inbox.md symlink is neither written through nor read through —
#      equivalent to open(O_NOFOLLOW) failing with ELOOP)
#   3. stages the new content in a temp file with the target's permissions
#      and renames it over the target, so the write is atomic and the final
#      object is always a regular file inside the vault
#
# Residual TOCTOU between the stat checks and the rename is accepted here;
# the rename itself never follows a final-component symlink. There is no
# in-process setText() alternative: Quickshell's atomicWrites uses QSaveFile,
# which resolves an existing symlink before choosing the write target.
set -u

target=$1

# One line from stdin (IFS= keeps leading/trailing spaces, -r keeps
# backslashes; only the trailing newline is consumed). No stdin line at all
# (closed channel, empty write) is refused. -t 10 bounds the wait: the QML
# caller writes within milliseconds of process start, so a helper whose
# caller died before writing exits instead of blocking forever.
IFS= read -r -t 10 line || exit 1
[ -n "$line" ] || exit 1

tmp=$(mktemp "/tmp/.todos-XXXXXX") || exit 1

parent=$(dirname -- "$target")
if [ "$(stat -c %F -- "$parent")" != "directory" ]; then
  rm -f -- "$tmp"
  exit 1
fi

if [ -L "$target" ] || [ -e "$target" ]; then
  if [ "$(stat -c %F -- "$target")" != "regular file" ]; then
    rm -f -- "$tmp"
    exit 1
  fi
fi

# Append to existing content. $(cat) strips trailing newlines; the format
# string re-adds exactly one, so files missing a trailing newline are fixed
# instead of corrupted (which `>>` would do).
existing=$(cat -- "$target" 2>/dev/null)
if [ -n "$existing" ]; then
  printf '%s\n%s\n' "$existing" "$line" > "$tmp" || { rm -f -- "$tmp"; exit 1; }
else
  printf '%s\n' "$line" > "$tmp" || { rm -f -- "$tmp"; exit 1; }
fi

# Keep the target's permission bits (mktemp creates 0600).
if [ -e "$target" ]; then
  chmod --reference="$target" -- "$tmp" 2>/dev/null || true
fi

mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; exit 1; }
