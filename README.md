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
(`find`, `bash`, `printf`, `mkdir`) plus Omarchy's built-in shell components.

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
plugin caps what it watches and parses:

- Up to `256` markdown files are watched (alphabetically first).
- Each file is parsed for up to `512 KB` / `10 000` lines, retaining at most
  `1000` tasks per file.

Tasks beyond those limits are simply not shown; the underlying files are never
truncated or rewritten.

## Usage

- **Bar** — shows the open count; `✓` when all clear, `!` when unconfigured.
- **Click** the widget to open the popup: check tasks off, add a new one, or
  set the vault path on first run.
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

## Development

```
omarchy-todos/
├── manifest.json   # plugin metadata, settings schema
├── Model.js        # Obsidian-tasks markdown parsing (pure JS, node-testable)
├── Panel.qml       # bar widget + popup
└── README.md
```

`Model.js` is Qt-free so it can be unit tested under node:

```bash
node -e 'var m=require("./Model.js"); console.log(m.parseTasks("- [ ] a\n- [x] b"))'
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
