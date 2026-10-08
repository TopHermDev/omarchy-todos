# omarchy-todos

A todo-list bar widget for [Omarchy](https://omarchy.org/) backed by plain
Obsidian markdown, kept in sync across machines with
[Syncthing](https://syncthing.net/).

Your todos are just `- [ ]` / `- [x]` lines in markdown files inside an
Obsidian vault. The plugin watches those files, shows the open count in the
bar, and lets you check tasks off from a popup. Because the source of truth is
a folder on disk that Syncthing (or Dropbox, rsync, anything) keeps identical
everywhere, every machine's bar shows the same list — no server, no API, no
account.

## How it works

```
Obsidian vault (synced by Syncthing)
  └── Todos/
        ├── inbox.md     # - [ ] Buy milk
        ├── today.md
        └── project.md

Omarchy shell (each machine) ──watches──> reads .md ──> bar shows open count
                                        toggle checkbox ──> writes back ──> syncs
```

Each machine's shell reads its own local copy of the vault. Checking a task off
on machine A rewrites the line in `inbox.md`, Syncthing propagates it, and
machine B's bar updates within seconds.

## Requirements

- **Omarchy** — the plugin runs inside `omarchy-shell` (Quickshell).
- **An Obsidian vault (or any folder of markdown)** — the source of truth.
- **Syncthing** (or any folder-sync tool) to keep the vault identical across
  machines.

No external runtime dependencies: the plugin uses only standard coreutils
(`find`, `stat`, `bash`, `mktemp`, `mv`) plus Omarchy's built-in shell
components.

## Installation

```bash
omarchy plugin add https://github.com/TopHermDev/omarchy-todos.git --enable
```

`--enable` places the widget in the bar. If you skip it:

```bash
omarchy plugin enable jeanhuit.todos --section right
```

After installing, run once to make sure the widget's IPC handler registers cleanly:

```bash
omarchy restart shell
```

## Removal

```bash
omarchy plugin remove jeanhuit.todos
```

## Configuration

Set the vault path by clicking the widget and pasting it into the setup form,
or by editing the `jeanhuit.todos` entry in `~/.config/omarchy/shell.json`:

```jsonc
{
  "id": "jeanhuit.todos",
  "vaultPath": "~/Sync/Obsidian",
  "todosDir": "Todos",
  "inboxFile": "inbox.md",
  "showCompleted": false
}
```

| Key             | Default      | Description                                                        |
| --------------- | ------------ | ------------------------------------------------------------------ |
| `vaultPath`     | *(required)* | Absolute path to your Obsidian vault (the Syncthing-synced folder). |
| `todosDir`      | `Todos`      | Subfolder inside the vault holding your todo `.md` files.           |
| `inboxFile`     | `inbox.md`   | File that quick-add and agents append new tasks to.                |
| `showCompleted` | `false`      | Also list completed tasks in the popup.                            |

## Markdown format

The plugin speaks the [Obsidian Tasks](https://publish.obsidian.md/tasks/)
checkbox syntax. Any `.md` file under `todosDir` is scanned:

```markdown
- [ ] Buy milk 📅 2026-08-23
- [x] Ship the plugin
- [ ] Fix the thing #project-a
```

- `- [ ]` / `- [x]` toggle open/done.
- `📅 YYYY-MM-DD` sets a due date (overdue items render red in the popup).
- Tasks are grouped per file and sorted: open before done, overdue first.

## Resource limits

Because the vault is populated by sync tools, a peer could in principle drop
many files or very large files into it. To keep the long-lived shell safe, the
plugin bounds what it reads, watches, and parses:

- Up to `256` markdown files are watched (alphabetically first).
- Files at or above `256 KiB` are not read at all — `find` excludes them before
  any content reaches the shell.
- Each file is parsed for at most `10 000` lines / `1000` tasks (the `512 KB`
  parse cap remains as defense in depth).
- A single task added via the bar or IPC is truncated to `2000` characters.

Tasks beyond those limits are simply not shown; the underlying files are never
truncated or rewritten.

## Path safety

`todosDir` and `inboxFile` are treated as a single safe directory/file name:
path separators, control characters, and leading dots/dashes are stripped, so a
setting like `../../.config` can never escape the vault. The vault path itself
is canonicalized (`~` expanded, trailing slashes removed) and must be absolute.

## Usage

- **Bar** — shows the open count; `✓` when all clear, `!` when unconfigured.
- **Click** the widget to open the popup: check tasks off, add a new one, or
  set the vault path on first run.
- **Hover** a task row: ✎ edits it inline (Enter saves, clicking away
  cancels — the due date is prefilled so a plain edit keeps 📅); ✕ deletes
  it on a second confirming click.
- **Quick-add / agents** — append a task without opening the popup:

  ```bash
  omarchy-shell jeanhuit.todos add "Buy milk 📅 2026-08-30"
  ```

  Your agents write plain markdown directly into the vault too — the plugin
  picks up new and edited files automatically.

### IPC reference

`omarchy-shell jeanhuit.todos <method> [args]`:

| Method    | Args   | Returns | Description                       |
| --------- | ------ | ------- | --------------------------------- |
| `add`     | text   | `ok`    | Append a task to `inboxFile`.     |
| `count`   | —      | string  | Number of open tasks.             |
| `refresh` | —      | —       | Re-scan the vault.                |
| `open`    | —      | —       | Open the popup.                   |
| `close`   | —      | —       | Close the popup.                  |
| `toggle`  | —      | —       | Toggle the popup open/closed.     |

## Security model

The plugin treats the vault as a trust boundary: every path it reads or writes
must stay inside the configured vault, refer to a validated regular file, and
consume bounded resources.

**Path handling**

- `vaultPath` is canonicalized once with `realpath -e` (symlinks, `~` and
  relative components resolved) before anything derives paths from it.
- Paths are only ever passed as **argv** to `find`/`stat`/`mv` — never
  interpolated into a shell command — and task text is likewise argv-only.

**Discovery and reads**

- `find -print0` streams NUL-delimited results; entries are validated as they
  arrive (plain basename, ≤ 255 bytes, no control characters) and enumeration
  stops at **256 files**.
- Every candidate is statted *before* a file view is created: `stat -c '%F:%s'`
  (no dereference) rejects symlinks, non-regular files, and anything over the
  **1 MiB** cap.
- The file list is committed only after `find` exits *and* the stat queue has
  drained; only candidates that passed their queued stat are published — raw
  `find` output never reaches a view.
- Watched-file reloads re-run the same gate; a failed check keeps the
  last-known-good content.

**Writes (quick-add, checkboxes)**

- Every write goes through a helper — `add-task.sh` (quick-add append) or
  `replace-line.sh` (checkbox toggle) — as `mktemp` (0600) → write → `mv -f`
  over the target. The in-process `FileView.setText()` path is deliberately
  not used: Quickshell implements `atomicWrites` with `QSaveFile`, which
  resolves an existing symlink before choosing the write target.
- `replace-line.sh` compare-and-swaps: line *N* must still match what the
  popup rendered, so an edit from a sync peer is refused, never overwritten.
  `remove-line.sh` does the same for deletes (a concurrently edited line is
  refused, not deleted).
- Task text — quick-add input and the expected/replacement lines — travels
  to the helpers on **stdin**, never in process arguments: argv is readable
  by every local user via `/proc/<pid>/cmdline` (`ps`), a pipe by nobody but
  the process itself. The reads are bounded (`read -t 10`), so a helper whose
  caller died before writing exits instead of blocking forever.
- A symlinked target is **refused**, never written through; the parent
  directory must be a real directory at rename time, so a swapped `Todos/`
  symlink can't redirect the write outside the vault.
- The existing file's mode is preserved on replace.

**Limits and residual risk**

- Validation happens stat-then-open, so a narrow TOCTOU window remains; closing
  it fully requires a native backend
  (`open`/`fstat`/`O_NOFOLLOW`/`openat2(RESOLVE_BENEATH)`), which belongs in
  Quickshell core rather than this plugin.
- If you intentionally symlink `inbox.md` (or `Todos/`) elsewhere, quick-add
  fails closed with a status message instead of following the link.

## Development

```
omarchy-todos/
├── manifest.json   # plugin metadata, settings schema
├── Model.js        # markdown parsing + path/stat validators (pure JS, node-testable)
├── Panel.qml       # bar widget + popup
├── add-task.sh     # fail-closed atomic quick-add write (used by Panel.qml)
├── replace-line.sh # fail-closed compare-and-swap line write (Panel.qml)
├── remove-line.sh  # fail-closed compare-and-swap line delete (Panel.qml)
├── test/           # model.test.js + adversarial vault-fixture.sh
└── README.md
```

`Model.js` is Qt-free so it can be unit tested under node:

```bash
node test/model.test.js       # validator unit tests
bash test/vault-fixture.sh    # adversarial filesystem fixture (54 checks)
```

To develop locally, clone a working copy into `~/.config/omarchy/plugins/`.
Saved changes hot-reload; force a reload with
`omarchy-shell shell rescanPlugins` (or `omarchy restart shell` for a clean
restart).

> **Note on the plugin id:** the id is `jeanhuit.todos` (reserving the
> `omarchy.*` namespace for first-party plugins). To rename it, change `id` in
> `manifest.json` and the three matching places in `Panel.qml` (`moduleName`,
> `ipcTarget`, and the `IpcHandler` `target`).

## License

MIT — see [LICENSE](LICENSE).
