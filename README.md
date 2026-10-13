# mru.nvim

Lua MRU/MRW tracking for Neovim 0.10+, with project and time filters, rename tracking, and an optional fzf-lua picker.

Ported from `aikawa9376/neomru.vim`'s `mrw` branch (commit `6ad76cf`). The core has no external dependencies.

- `file`: recently visited or saved files.
- `write`: recently saved files, tracked separately by `BufWritePost`.
- `directory`: recently visited files' parent directories.

## Install locally with lazy.nvim

Replace the existing `aikawa9376/neomru.vim` entry with:

```lua
{
  dir = "/home/aikawa/workspace/mru.nivm",
  event = "BufReadPre",
  opts = {},
}
```

## Picker

With fzf-lua installed and loaded, `:Mru` opens visited files and `:Mrw` opens saved files. Both start in the current project, showing last visit and save times. The project and cwd are captured when the picker opens, so preview buffers do not change the scope.

```lua
require("mru.fzf").open({ kind = "write", scope = "project", period = "today" })
require("mru.fzf").open({ scope = "all" })
```

| Key | Action |
| --- | --- |
| `ctrl-t` | Switch MRU / MRW |
| `ctrl-g` | Cycle project / all / cwd |
| `alt-d` | Cycle all time / last hour / today / yesterday / last 7 days |
| `ctrl-h` | Toggle missing files |
| `ctrl-r` | Refresh |
| `ctrl-x` | Forget selected history entries; files remain untouched |
| `enter` | Open |
| `ctrl-s` / `ctrl-v` | Split / vertical split |
| `alt-enter` | Open in a tab |
| `ctrl-q` | Send selected paths to quickfix |

Paths appear first, with highlighted filenames and muted directories. Visit/save times follow in aligned, muted columns; unknown historical times display as `--`. Path padding stops at 60 display cells so a long entry does not push every row's times offscreen; longer paths retain their full text and extend the row. Search matches paths, excluding timestamps. The header shows the active MRU/MRW mode, even when both histories contain the same files. Colors follow your theme through `MruFileName` (Directory), `MruDirectory` and `MruTime` (Comment), and `MruMissing` (DiagnosticWarn) highlight groups.

Switches, refresh, and forgetting preserve the search query. Timestamps and labels are separate from the paths used for opening and previewing.

Picker options accept the query options below, plus `query`, `previewer`, and `picker` for fzf-lua display settings. Custom `actions` are functions receiving actual selected paths and fzf-lua action options (or `false` to disable a binding):

```lua
require("mru.fzf").open({
  kind = "write",
  scope = "project",
  picker = { winopts = { width = 0.9, height = 0.9 } },
  actions = {
    ["alt-y"] = function(paths) vim.fn.setreg("+", table.concat(paths, "\n")) end,
  },
})
```

## Query API

```lua
local mru = require("mru")

mru.list()                         -- paths, newest first; all projects
mru.list("write")                  -- saved file paths
mru.list("directory")              -- parent directories
mru.list("file", { scope = "project" })
mru.list("file", { scope = "cwd", cwd = "/path/to/project/src" })
mru.list("file", { scope = "project", project = "/path/to/project" })
mru.list("write", { period = "today" })
mru.list("file", { period = "yesterday", time_field = "visited_at" })
mru.list("write", { since = os.time() - 3600, ["until"] = os.time() })
mru.list("file", { include_missing = true })

mru.entries("file", { scope = "project" })
-- { { path = "/...", visited_at = 123, written_at = 456, missing = false }, ... }

mru.project_root()                 -- current normal buffer's project, or cwd
mru.project_root("/path/to/project/src")
```

`list()` and `entries()` return independent copies. Existing `list(kind, { cwd = ... })` calls keep filtering by cwd unless `scope` is explicitly specified. Directory matching respects boundaries. Project detection searches upward for the nearest root marker, including `.git` files used by Git worktrees; if none is found, it uses the current cwd.

Timestamps are Unix seconds recorded by Neovim events, separate from filesystem modification times. `visited_at` updates on visits; `written_at` updates on saves. File and write queries join the latest known timestamps for the same path, without changing their separate ordering or membership. Repeated events for the top entry in the same second do not cause redundant saves.

Time filtering uses `written_at` for MRW, and the latest visit/save for MRU unless `time_field` selects one explicitly. `since` is inclusive; `until` is exclusive. `today` and `yesterday` use local calendar boundaries. Unknown times do not match bounded time queries.

Missing files are hidden by default, retained within the history limit, and become visible again when they return. `reload()` and exit validation do not remove missing paths. To forget one permanently, use `delete()` or the picker action. Paths matching ignore rules stay hidden; optional exit validation removes ignored entries from storage.

## Recording, import, and rename

```lua
local mru = require("mru")

mru.append("/path/to/file")             -- visit: file and its parent directory
mru.append("/path/to/file", "write")    -- record a save in MRW
mru.append("/path/to/dir", "directory")
mru.delete("write", { "/path/to/file" })
mru.save()                              -- persist buffered changes
mru.reload()                            -- reread storage; presence is evaluated by queries
mru.sync()                              -- synchronize, keeping pending local changes

mru.import("file", "/path/to/old-mru", { oldfiles = true })
mru.import("write", "/path/to/native/write.json")
mru.migrate()                           -- migrate all histories and regenerate exports

mru.rename("/old/file", "/new/file")
mru.rename("/old/directory", "/new/directory", { directory = true })
```

`rename()` updates history only; it does not move files. Directory moves update descendant paths and directory history. When records collide at the destination, their newest known timestamps are merged while preserving MRU order. When `directory` is omitted, it is inferred if either path currently names a directory; pass it explicitly if both paths are absent.

Neovim buffer name changes (`BufFilePre`/`BufFilePost`) and successful local Oil moves (`OilActionsPost`) update history automatically. Integrations can also notify the plugin without adding a dependency:

```lua
vim.api.nvim_exec_autocmds("User", {
  pattern = "MruRename",
  data = { from = "/old/file", to = "/new/file", directory = false },
})
```

External moves are not guessed from unrelated deletions and creations. Use the API or `:MruRename /old/file /new/file`; use `:MruRename! /old/dir /new/dir` for directories. Escape spaces in command arguments or use the Lua API.

Other commands: `MruSave`, `MruReload`, `MruMigrate`, `MruImportFile {path}`, `MruImportWrite {path}`, `MruImportDirectory {path}`. `NeoMRUSave` and `NeoMRUReload` remain aliases.

## Configuration

```lua
require("mru").setup({
  -- storage_dir = vim.fn.expand("~/.cache/neomru"),
  max_entries = 1000,             -- retained records, including missing files
  save_interval = 0,              -- seconds; 0 persists each change
  validate_on_exit = true,        -- prune ignored paths, retain missing files
  follow_links = false,
  focus_oldfiles = false,         -- true seeds BOTH MRU and MRW on FocusGained
  project_root = false,          -- optional fixed path or function(start) -> root or nil
  root_markers = { ".git", ".hg", "package.json", "pyproject.toml", "Cargo.toml", "go.mod" },
  histories = {
    file = {},
    write = { limit = 1000 },     -- optional path and per-history limit
    directory = {},
  },
  -- Optional replacement for the default ignore predicate:
  -- ignore = function(path, kind) return path:find("/generated/", 1, true) ~= nil end,
})
```

A `project_root` function receives the starting file/directory path. Returning `nil` falls back to marker detection. A fixed path or resolver is useful for monorepos and projects without Git. A limit of `0` retains no entries.

With a positive `save_interval`, the first change is saved immediately. Further changes stay in memory until another change occurs after the interval, an explicit save/import/delete/rename, reconfiguration, or exit. Queries include pending changes. There is no background flush timer.

Defaults exclude temporary/mounted paths, VCS internals, backup/compiled files, and `fugitive://`, `gitgutter://`, `term://` buffers. Automatic tracking accepts named, normal buffers outside preview windows. Manual recording supports custom URI paths. Symlink paths are preserved unless `follow_links` is enabled. Unix paths retain case distinctions.

## Storage and migration

The default directory remains `$XDG_CACHE_HOME/neomru` (or `~/.cache/neomru`). Each history has:

- `file.json`, `write.json`, `directory.json`: authoritative schema version 1, containing paths, known timestamps, and rename records.
- `file`, `write`, `directory`: generated `0.3.0` plain-path exports for existing fzf and shell consumers. These include paths available and non-ignored at the last save.

When metadata is absent, the corresponding old `0.3.0` history and optional `_long` companion are read automatically. The first save creates metadata; `:MruMigrate` migrates all three immediately. Old ordering is retained within configured limits. Old operation times remain unknown rather than being inferred from file modification times. Imports also accept native JSON, preserve known times and missing paths, and never modify the source file unless it is itself configured as the destination.

Once JSON exists, editing the plain export does not modify the authoritative history. Configure the old plugin out of every instance; it does not participate in the new storage or locking protocol. Existing consumers can continue reading the generated path lists.

Saves hold an exclusive `<history>.lock` over the entire read/merge/write. Metadata and exports are each replaced atomically; metadata is committed first. If a process stops between the two replacements, the next save regenerates the export from metadata. Pending events recorded before another instance's rename follow that rename, while later explicit visits can reuse the old pathname.

Unsupported versions or malformed metadata are reported and never overwritten. If a process is killed while saving, a lock may remain: confirm no writer is active, remove the stale lock, then retry `:MruSave`. Lock acquisition times out after 250 ms, preserving pending changes for retry.

## Development

Core tests require only Neovim:

```sh
nvim --headless --clean -u NONE -i NONE -l tests/run.lua
```

For real picker integration, use an installed fzf-lua checkout and fzf:

```sh
MRU_FZF_LUA_PATH=/path/to/fzf-lua nvim --headless --clean -u NONE -i NONE -l tests/fzf.lua
```

Tests use isolated temporary storage. Coverage includes concurrent Neovim writers, migration, project/time filters, missing-file restoration, metadata-preserving renames, pending events across renames, and real picker switching, previews, forgetting, and opening.

MIT licensed. Original authors: Shougo Matsushita and Zhao Cai; fork: aikawa9376.
