# mru.nvim

Lua MRU/MRW tracking for Neovim 0.10+. No external dependencies or picker required.

Ported from `aikawa9376/neomru.vim`'s `mrw` branch (commit `6ad76cf`), with a native Lua API and new storage synchronization.

- `file`: recently visited or saved files.
- `write`: recently saved files, tracked separately by `BufWritePost`.
- `directory`: recently visited files' parent directories.

## Install locally with lazy.nvim

Replace the existing `aikawa9376/neomru.vim` entry with:

```lua
{
  dir = "/home/aikawa/workspace/mru.nivm",
  name = "mru.nvim",
  event = "BufReadPre",
  opts = {},
}
```

The default history directory remains `$XDG_CACHE_HOME/neomru` (or `~/.cache/neomru`). Existing `0.3.0` histories load automatically. The first line is the version; subsequent lines are absolute paths, newest first. Existing fzf consumers of `neomru/file` and `neomru/write` continue to work.

## Lua API

```lua
local mru = require("mru")

mru.list()                              -- file history, newest first
mru.list("write")                       -- saved files
mru.list("directory")                   -- directories
mru.list("file", { cwd = vim.uv.cwd() }) -- only this directory and its descendants
mru.list("file", { validate = true })   -- prune missing and ignored paths

mru.append("/path/to/file")             -- record file and its parent directory
mru.append("/path/to/file", "write")    -- record a save explicitly
mru.append("/path/to/dir", "directory")
mru.delete("write", { "/path/to/file" })
mru.save()                              -- persist buffered changes
mru.reload()                            -- synchronize and prune invalid paths
mru.sync()                              -- synchronize without validation
mru.import("file", "/path/to/old-mru", { oldfiles = true })
```

`list()` returns a copy. `cwd` matching respects directory boundaries. Imports understand the optional `_long` companion and tab-separated legacy metadata. Importing `v:oldfiles` is explicit.

Commands: `MruSave`, `MruReload`, `MruImportFile {path}`, `MruImportWrite {path}`, `MruImportDirectory {path}`. `NeoMRUSave` and `NeoMRUReload` are aliases.

To use fzf-lua without reading the cache through a shell:

```lua
require("fzf-lua").fzf_exec(require("mru").list("write"), {
  prompt = "MRW> ",
  actions = require("fzf-lua").defaults.actions.files,
})
```

## Configuration

```lua
require("mru").setup({
  -- storage_dir = vim.fn.expand("~/.cache/neomru"),
  max_entries = 1000,
  save_interval = 0,          -- seconds; 0 persists every change
  validate_on_exit = true,
  follow_links = false,
  focus_oldfiles = false,     -- true opts into the fork's oldfiles seeding for BOTH MRU and MRW
  histories = {
    file = {},
    write = { limit = 1000 }, -- optional path and per-history limit (0 disables retention)
    directory = {},
  },
  -- Optional replacement for the default ignore predicate:
  -- ignore = function(path, kind) return path:find("/generated/", 1, true) ~= nil end,
})
```

With a positive `save_interval`, the first change is saved immediately. Further changes stay in memory until another change occurs after the interval, an explicit save/import/delete, reconfiguration, or exit. `list()` includes pending changes. Exit validation can be disabled independently of explicit `reload()` validation.

Defaults exclude temporary/mounted paths, VCS internals, backup/compiled files, and `fugitive://`, `gitgutter://`, `term://` buffers. Automatic tracking accepts named, normal buffers outside preview windows. Manual `append()` also supports custom URI paths. Symlink paths are preserved unless `follow_links` is enabled. Unix paths retain case distinctions.

## Multiple instances and persistence

Changes are replayed onto the latest disk history inside an exclusive lock, then saved through an atomic rename. Same-second updates are detected by reading storage directly. A stale instance cannot restore an entry another instance deleted unless it actually records that entry again. `FocusGained` reads all three histories and keeps pending local edits.

Only Lua instances participate in this lock protocol; replace the old plugin in every running instance for concurrent use. If a process is killed while saving, its `<history>.lock` file may remain. After confirming that no writer is active, remove that lock and run `:MruSave`. Lock acquisition times out after 250 ms; pending operations remain available for retry. Unsupported versions are reported and never overwritten.

The Lua version intentionally does not seed MRW from `v:oldfiles` by default. Display formatting belongs to the picker; Vimscript globals and Unite/Denite adapters are replaced by `setup()` and `list()`.

## Development

```sh
nvim --headless --clean -u NONE -i NONE -l tests/run.lua
```

Tests use isolated temporary histories, including three concurrent Neovim processes writing to one history.

MIT licensed. Original authors: Shougo Matsushita and Zhao Cai; fork: aikawa9376.
