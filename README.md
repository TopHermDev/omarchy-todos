# omarchy-todos

A todo-list bar widget for [Omarchy](https://omarchy.org/) backed by plain
Obsidian markdown, kept in sync across machines with
[Syncthing](https://syncthing.net/).

Your todos are just `- [ ]` / `- [x]` lines in markdown files inside an
Obsidian vault. The plugin watches those files, shows the open count (with an
overdue marker) in the bar, and lets you check tasks off from a popup that
groups tasks per file and filters by file or `#tag`. Because the source of
truth is a folder on disk that Syncthing (or Dropbox, rsync, anything) keeps
identical everywhere, every machine's bar shows the same list — no server, no
API, no account.

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

When quick-adding (popup or IPC), a trailing natural-language date is
converted to a `📅` tag automatically:

| You type                    | Becomes                          |
| --------------------------- | -------------------------------- |
| `water plants tomorrow`     | `water plants 📅 2026-10-16`     |
| `ship report friday`        | `ship report 📅 2026-10-16`      |
| `ship report next friday`   | `ship report 📅 2026-10-23`      |
| `file report in 3 days`     | `file report 📅` + 3 days        |
| `file report in 2 weeks`    | `file report 📅` + 14 days       |

Weekdays roll forward — "friday" added on a Friday means next Friday, never
today. An explicit `📅` in the text always wins; text that is nothing but a
date word ("tomorrow") is stored verbatim.

## Groups

Every `.md` file in the todos folder is a group. Want separate lists for
school and home?

```bash
touch ~/path/to/vault/Todos/school.md ~/path/to/vault/Todos/home.md
```

The popup shows one section per file (labeled by filename) whenever tasks
span multiple files, and the file chips from the filter row double as
one-click group views. Any file you add is picked up automatically — no
configuration.

## Resource limits

Because the vault is populated by sync tools, a peer could in principle drop
many files or very large files into it. To keep the long-lived shell safe, the
plugin bounds what it reads, watches, and parses:

- Up to `256` markdown files are watched (alphabetically first).
- Files at or above `256 KiB` are not read at all — `find` excludes them before
  any content reaches the shell.
- Each file is parsed for at most `10 000` lines / `1000` tasks (the `512 KB`
  parse cap remains as defense in depth).
- A single task added via the bar or IPC must fit in `512` characters after
  sanitization (longer input is rejected, never partially written); a
  natural-language date suffix is dropped rather than exceeding the cap.

Tasks beyond those limits are simply not shown; the underlying files are never
truncated or rewritten.

## Path safety

`todosDir` and `inboxFile` are treated as a single safe directory/file name:
path separators, control characters, and leading dots/dashes are stripped, so a
setting like `../../.config` can never escape the vault. The vault path itself
is canonicalized (`~` expanded, trailing slashes removed) and must be absolute.

## Usage

- **Bar** — shows the open count (plus `·overdue` when any are overdue);
  `✓` when all clear, `!` when unconfigured.
- **Click** the widget to open the popup: check tasks off, add a new one, or
  set the vault path on first run.
- **Filter chips** — narrow the list by source file or `#tag`; click the
  active chip again (or close the popup) to clear the filter.
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
- Watched-file reloads re-run the same gate; a failed check keeps the
  last-known-good content.

**Writes (quick-add, checkboxes)**

- Writes are atomic: `mktemp` (0600) → write → `mv -f` over the target
  (`add-task.sh` is the fail-closed fallback used when the in-process path
  isn't available).
- A symlinked target is **refused**, never written through; the parent
  directory must be a real directory at rename time, so a swapped `Todos/`
  symlink can't redirect the write outside the vault.
- The existing file's mode is preserved on replace.
- Quick-add text is flattened to one line, whitespace-collapsed, capped at
  `512` chars, and passed as argv only; the natural-language date conversion
  is pure string work and cannot exceed the cap or introduce newlines.

**Rendering**

- Task text and filenames are attacker-influenced (a sync peer writes them),
  so every `Text` that displays them forces `Text.PlainText` — QML's default
  `AutoText` would otherwise promote an HTML-looking filename
  (`<img …>.md`) to rich text.
- Grouping/filter maps key on prefixed entries, so hostile filenames like
  `__proto__` cannot forge object keys.

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
├── add-task.sh     # fail-closed atomic quick-add fallback (used by Panel.qml)
├── test/           # model.test.js + adversarial vault-fixture.sh
└── README.md
```

`Model.js` is Qt-free so it can be unit tested under node:

```bash
node test/model.test.js       # model unit tests (parsing, dates, filters, validators)
bash test/vault-fixture.sh    # adversarial filesystem fixture (22 checks)
```

To develop locally, clone a working copy into `~/.config/omarchy/plugins/`.
Saved changes hot-reload; force a reload with
`omarchy-shell shell rescanPlugins` (or `omarchy restart shell` for a clean
restart).

> **Note on the plugin id:** the id is `jeanhuit.todos` (reserving the
> `omarchy.*` namespace for first-party plugins). To rename it, change `id` in
> `manifest.json` and the three matching places in `Panel.qml` (`moduleName`,
> `ipcTarget`, and the `IpcHandler` `target`).

## Changelog

### Unreleased

- **Due-date awareness in the bar** — overdue count shown as `N·overdue`,
  tooltip shows overdue count and the next due date; the date rolls over at
  midnight even in a long-running shell (and after suspend).
- **Natural-language quick-add** — trailing `tomorrow` / `friday` /
  `in 3 days` etc. converts to a `📅` tag (see [Markdown format](#markdown-format)).
- **Filter chips** — narrow the popup by source file or `#tag`.
- **Groups** — tasks are sectioned per file in the popup (see [Groups](#groups)).
- Security: quick-add length cap now holds end-to-end; sync-peer filenames
  render as plain text in filter chips (rich-text injection fix); hostile
  filenames cannot forge grouping keys.

### 1.0.0

- Initial release: vault-backed todo bar widget with checkbox toggling,
  quick-add IPC, due dates, and filesystem hardening.

## License

MIT — see [LICENSE](LICENSE).
