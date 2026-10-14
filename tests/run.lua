vim.opt.rtp:prepend(vim.fn.getcwd())
local uv = vim.uv or vim.loop
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_CACHE_HOME = root .. "/cache"
local mru = require("mru")
local History = require("mru.history")
local count = 0
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local function test(name, callback)
  local ok, err = pcall(callback)
  if not ok then
    io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    vim.fn.delete(root, "rf")
    vim.cmd("cquit 1")
  end
  count = count + 1
  print("PASS " .. name)
end
local function file(name)
  local path = root .. "/" .. name
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ name }, path)
  return path
end
local a, b, c = file("project/a"), file("project/b"), file("project-other/c")
local setup_id = 0
local storage_dir
local function setup(extra)
  setup_id = setup_id + 1
  storage_dir = root .. "/history-" .. setup_id
  mru.setup(vim.tbl_deep_extend("force", {
    storage_dir = storage_dir,
    ignore = function() return false end,
  }, extra or {}))
end

test("MRU order, MRW separation, directory and cwd boundary", function()
  setup()
  mru.append(a)
  mru.append(b)
  mru.append(c)
  mru.append(a)
  equal(mru.list(), { a, c, b })
  equal(mru.list("write"), {})
  mru.append(b, "write")
  equal(mru.list("write"), { b })
  equal(mru.list("directory"), { root .. "/project", root .. "/project-other" })
  equal(mru.list("file", { cwd = root .. "/project" }), { a, b })
  local list = mru.list()
  list[1] = "changed"
  equal(mru.list()[1], a)
end)

test("buffer events record reads and only actual writes in MRW", function()
  setup()
  vim.cmd.edit(vim.fn.fnameescape(a))
  equal(mru.list("file"), { a })
  equal(mru.list("write"), {})
  vim.cmd.write()
  equal(mru.list("write"), { a })
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, b)
  vim.api.nvim_set_current_buf(buffer)
  equal(mru.list("file"), { a })
  vim.cmd.edit(vim.fn.fnameescape(a))
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

test("external same-second writes and deletes survive stale sessions", function()
  local path = root .. "/shared"
  local first = History.new(path, 100, function() return true end, 0)
  local second = History.new(path, 100, function() return true end, 0)
  first:append(a)
  second:sync()
  first:append(b)
  second:append(c)
  equal(first:sync(), { c, b, a })
  second:delete({ b })
  first:save()
  equal(History.read(path), { c, a })
end)

test("FocusGained keeps buffered local writes and does not seed MRW", function()
  setup({ save_interval = 3600 })
  mru.append(a)
  mru.append(b)
  local path = storage_dir .. "/file"
  local external = History.new(path, 1000, function() return true end, 0)
  external:append(c)
  vim.api.nvim_exec_autocmds("FocusGained", {})
  equal(mru.list(), { b, c, a })
  equal(mru.list("write"), {})
  mru.save()
  equal(History.read(path), { b, c, a })
end)

test("legacy import, long history, deduplication and persisted format", function()
  setup()
  local path = root .. "/legacy"
  vim.fn.writefile({ "0.3.0", a .. "\t123", b .. "\t456" }, path)
  vim.fn.writefile({ "0.3.0", c, a }, path .. "_long")
  mru.import("file", path)
  equal(mru.list(), { a, b, c })
  equal(vim.fn.readfile(storage_dir .. "/file"), { "0.3.0", a, b, c })
end)

test("limits including zero and Unix case-sensitive names", function()
  setup({ max_entries = 2, histories = { write = { limit = 0 } } })
  mru.append(a)
  mru.append(b)
  mru.append(c)
  equal(mru.list(), { c, b })
  mru.append(a, "write")
  equal(mru.list("write"), {})
  if vim.fn.has("win32") == 0 then
    setup()
    local upper = file("project/A")
    mru.append(a)
    mru.append(upper)
    equal(mru.list(), { upper, a })
  end
end)

test("symlinks and explicit validation", function()
  setup()
  local link = root .. "/link"
  assert(uv.fs_symlink(a, link))
  mru.append(link)
  equal(mru.list(), { link })
  setup({ follow_links = true })
  mru.append(link)
  equal(mru.list(), { a })
  local gone = file("gone")
  mru.append(gone)
  uv.fs_unlink(gone)
  mru.reload()
  equal(mru.list(), { a })
  equal(mru.list("file", { include_missing = true }), { gone, a })
  mru.save()
  local restored = file("gone")
  equal(mru.list()[1], restored)
end)

test("invalid versions cannot overwrite storage or leak locks", function()
  local path = root .. "/bad-version"
  vim.fn.writefile({ "0.2.0", a }, path)
  local history = History.new(path, 100, function() return true end, 0)
  assert(not pcall(function() history:save() end))
  equal(vim.fn.readfile(path), { "0.2.0", a })
  equal(uv.fs_stat(path .. ".lock"), nil)
  vim.fn.writefile({ "0.3.0", a }, path)
  history:save()
end)

test("default ignores, URI filtering and root preservation", function()
  setup({ ignore = require("mru.config").resolve().ignore })
  mru.append(a)
  mru.append("term://something", "write")
  mru.append("gitgutter://something", "write")
  mru.append("/", "directory")
  equal(mru.list("file"), {})
  equal(mru.list("write"), {})
  equal(mru.list("directory"), { "/" })
  mru.append("custom://path", "write")
  equal(mru.list("write"), {})
  setup() -- A custom ignore predicate can opt into manual URI recording.
  mru.append("custom://path", "write")
  equal(mru.list("write"), { "custom://path" })
  mru.append("custom:///home/aikawa/dotfiles/file")
  equal(mru.list("file"), { "custom:///home/aikawa/dotfiles/file" })
  equal(mru.list("directory"), {})
end)

test("URI buffers never enter automatic history before becoming nofile", function()
  setup() -- Even a custom ignore predicate must not admit automatic URI events.
  mru.append(a)
  for _, scheme in ipairs({ "git-worktree", "git-branch", "git-stash", "custom" }) do
    local buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buffer, scheme .. "://" .. root .. "/project")
    vim.api.nvim_set_current_buf(buffer) -- BufEnter fires while buftype is still empty.
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buffer })
    vim.bo[buffer].buftype = "nofile"
    equal(mru.list("file"), { a })
    equal(mru.list("write"), {})
    equal(mru.list("directory"), { root .. "/project" })
    vim.cmd.edit(vim.fn.fnameescape(a))
    vim.api.nvim_buf_delete(buffer, { force = true })
  end
end)

test("default URI exclusion covers existing histories, imports and exports", function()
  setup({ ignore = require("mru.config").resolve().ignore })
  local uri = "git-worktree:///home/aikawa/dotfiles"
  local source = root .. "/uri-import"
  vim.fn.writefile({ "0.3.0", uri, "git-branch:///repo", "custom://path", "/" }, source)
  vim.fn.mkdir(storage_dir, "p")
  for _, kind in ipairs({ "file", "write", "directory" }) do
    local path = storage_dir .. "/" .. kind
    -- Native and legacy histories may already contain temporary buffer names.
    if kind == "file" then
      vim.fn.writefile({ "0.3.0", uri, "custom://path", "/" }, path)
    else
      vim.fn.writefile({ vim.json.encode({ version = 1, entries = {
        { path = uri }, { path = "custom://path" }, { path = "/" },
      } }) }, path .. ".json")
    end
    local expected = kind == "directory" and { "/" } or {}
    equal(mru.list(kind, { scope = "all" }), expected)
    equal(mru.list(kind, { scope = "all", include_missing = true }), { "/" })
    mru.append(uri, kind)
    mru.import(kind, source)
    mru.save()
    equal(vim.fn.readfile(path), kind == "directory" and { "0.3.0", "/" } or { "0.3.0" })
    mru.save({ validate = true })
    equal(History.read(path), { "/" }) -- Validation retains ordinary missing paths.
  end
end)

test("URI buffer renames cannot move ordinary file history", function()
  setup()
  vim.cmd.edit(vim.fn.fnameescape(a))
  local buffer = vim.api.nvim_get_current_buf()
  mru.append(a, "write")
  vim.api.nvim_buf_set_name(0, "git-worktree://" .. root .. "/project")
  equal(mru.list("write"), { a })
  vim.api.nvim_buf_set_name(0, b)
  equal(mru.list("write"), { a })
  vim.cmd.edit(vim.fn.fnameescape(a))
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

test("setup idempotence and command registration", function()
  setup()
  local n = #vim.api.nvim_get_autocmds({ group = "mru.nvim" })
  setup()
  equal(#vim.api.nvim_get_autocmds({ group = "mru.nvim" }), n)
  vim.cmd.MruSave()
  vim.cmd.NeoMRUReload()
  assert(vim.fn.exists(":MruImportWrite") == 2)
  assert(not pcall(mru.setup, { max_entries = -1 }))
end)

test("literal filenames and imported filesystem roots", function()
  setup()
  local literal = file("project/%#$literal name")
  mru.append(literal)
  equal(mru.list(), { literal })
  local source = root .. "/root-import"
  vim.fn.writefile({ "0.3.0", "/" }, source)
  mru.import("directory", source)
  assert(vim.tbl_contains(mru.list("directory"), "/"))
end)

test("failed lock acquisition preserves pending changes for retry", function()
  local path = root .. "/locked"
  local history = History.new(path, 100, function() return true end, 0)
  local fd = assert(uv.fs_open(path .. ".lock", "wx", 384))
  assert(not pcall(function() history:append(a) end))
  equal(history:sync(), { a })
  assert(uv.fs_stat(path .. ".lock"))
  uv.fs_close(fd)
  uv.fs_unlink(path .. ".lock")
  history:save()
  equal(History.read(path), { a })
end)

test("automatic legacy migration retains missing paths and unknown timestamps", function()
  setup()
  local gone = root .. "/not-here"
  vim.fn.mkdir(storage_dir, "p")
  vim.fn.writefile({ "0.3.0", a, gone }, storage_dir .. "/file")
  equal(mru.list(), { a })
  equal(mru.list("file", { include_missing = true }), { a, gone })
  equal(mru.entries()[1].visited_at, nil)
  mru.migrate()
  local state = vim.json.decode(table.concat(vim.fn.readfile(storage_dir .. "/file.json"), "\n"))
  equal(state.version, 1)
  equal(state.entries, { { path = a }, { path = gone } })
  equal(vim.fn.readfile(storage_dir .. "/file"), { "0.3.0", a })
  mru.save({ validate = true })
  equal(mru.list("file", { include_missing = true }), { a, gone })
end)

test("visit and save timestamps are independent and durable", function()
  setup()
  local path = storage_dir .. "/file"
  local history = History.new(path, 100, function() return true end, 0)
  history:append(a, { visited_at = 100 })
  history:append(a, { written_at = 200 })
  local record = mru.entries()[1]
  equal(record.visited_at, 100)
  equal(record.written_at, 200)
  record.visited_at = 999
  equal(mru.entries()[1].visited_at, 100)
  history:append(a, { visited_at = 50 })
  equal(mru.entries()[1].visited_at, 100)
  mru.append(b)
  local now = os.time()
  assert(mru.entries()[1].visited_at <= now and mru.entries()[1].visited_at >= now - 1)
  vim.cmd.edit(vim.fn.fnameescape(b))
  vim.cmd.write()
  assert(mru.entries()[1].written_at >= now - 1)
  assert(mru.entries("write")[1].written_at >= now - 1)
end)

test("period and time-field filters respect inclusive since and exclusive until", function()
  setup()
  local history = History.new(storage_dir .. "/file", 100, function() return true end, 0)
  history:append(a, { visited_at = 100, written_at = 300 })
  history:append(b, { visited_at = 200 })
  history:import({ c }) -- Unknown times do not satisfy bounded queries.
  equal(mru.list("file", { since = 200, ["until"] = 301 }), { b, a })
  equal(mru.list("file", { since = 200, ["until"] = 300 }), { b })
  equal(mru.list("file", { since = 200, time_field = "visited_at" }), { b })
  equal(mru.list("file", { since = 200, time_field = "written_at" }), { a })
  equal(mru.list("file", { period = "today" }), {})
  mru.append(c)
  equal(mru.list("file", { period = "hour" }), { c })
  equal(mru.list("file", { period = "today" }), { c })
  assert(not pcall(mru.list, "file", { period = "invalid" }))
end)

test("project roots detect Git worktree markers and include sibling directories", function()
  setup()
  vim.fn.writefile({ "gitdir: /some/worktree" }, root .. "/project/.git")
  local sibling = file("project/tests/sibling")
  mru.append(a)
  mru.append(sibling)
  mru.append(c)
  equal(mru.project_root(root .. "/project/tests"), root .. "/project")
  equal(mru.list("file", { scope = "project", cwd = root .. "/project/tests" }), { sibling, a })
  equal(mru.list("file", { scope = "cwd", cwd = root .. "/project/tests" }), { sibling })
  equal(mru.list("file", { scope = "project", project = root .. "/project" }), { sibling, a })
  equal(mru.list("file", { scope = "all", cwd = root .. "/project/tests" }), { c, sibling, a })
  setup({ project_root = root .. "/project" })
  equal(mru.project_root(root .. "/project-other"), root .. "/project")
  setup({ project_root = function(start)
    assert(start == c)
    return root .. "/project-other"
  end })
  equal(mru.project_root(c), root .. "/project-other")
end)

test("rename preserves order and combines metadata at an existing destination", function()
  setup()
  local history = History.new(storage_dir .. "/file", 100, function() return true end, 0)
  history:append(a, { visited_at = 100, written_at = 300 })
  history:append(b, { visited_at = 200 })
  local writes = History.new(storage_dir .. "/write", 100, function() return true end, 0)
  writes:append(a, { written_at = 300 })
  mru.rename(a, b)
  equal(mru.list(), { b })
  equal(mru.list("write"), { b })
  equal(mru.entries()[1].visited_at, 200)
  equal(mru.entries()[1].written_at, 300)
end)

test("directory rename handles descendants and respects directory boundaries", function()
  setup()
  mru.append(a)
  mru.append(b, "write")
  mru.append(c)
  local moved = root .. "/renamed-project"
  assert(uv.fs_rename(root .. "/project", moved))
  mru.rename(root .. "/project", moved, { directory = true })
  equal(mru.list(), { c, moved .. "/a" })
  equal(mru.list("write"), { moved .. "/b" })
  equal(mru.list("directory"), { root .. "/project-other", moved })
  assert(uv.fs_rename(moved, root .. "/project"))
end)

test("buffer and explicit User rename events update histories", function()
  setup()
  vim.cmd.edit(vim.fn.fnameescape(a))
  mru.append(a, "write")
  local renamed = file("buffer-renamed")
  vim.api.nvim_buf_set_name(0, renamed)
  equal(mru.list("write"), { renamed })
  vim.api.nvim_exec_autocmds("User", { pattern = "MruRename", data = { from = renamed, to = b } })
  equal(mru.list("write"), { b })
  vim.api.nvim_exec_autocmds("User", {
    pattern = "OilActionsPost", data = { actions = {
      { type = "move", src_url = "oil://" .. b, dest_url = "oil://" .. c, entry_type = "file" },
    } },
  })
  equal(mru.list("write"), { c })
  vim.api.nvim_exec_autocmds("User", {
    pattern = "OilActionsPost", data = { err = "move failed", actions = {
      { type = "move", src_url = "oil://" .. c, dest_url = "oil://" .. a, entry_type = "file" },
    } },
  })
  equal(mru.list("write"), { c })
end)

test("pending events in another instance follow a later rename", function()
  local path = root .. "/rename-shared"
  local first = History.new(path, 100, function() return true end, 3600)
  local second = History.new(path, 100, function() return true end, 0)
  first:append(a, { visited_at = 100 })
  first:append(a, { visited_at = 200 }) -- Buffered, before second's rename.
  second:rename(a, b, false)
  first:save()
  equal(first:sync(), { b })
  equal(first.records[1].visited_at, 200)
  first:append(a, { visited_at = 300 }) -- A later explicit visit may reuse the old name.
  first:save()
  equal(first:sync(), { a, b })
end)

test("native imports preserve metadata and reject corrupt metadata without overwriting", function()
  setup()
  local source = root .. "/native-source"
  local history = History.new(source, 100, function() return true end, 0)
  history:append(a, { visited_at = 123, written_at = 456 })
  mru.import("file", source .. ".json")
  equal(mru.entries()[1].visited_at, 123)
  equal(mru.entries()[1].written_at, 456)
  local path = root .. "/corrupt"
  vim.fn.writefile({ '{"version":999,"entries":[]}' }, path .. ".json")
  local corrupt = History.new(path, 100, function() return true end, 0)
  assert(not pcall(function() corrupt:save() end))
  equal(vim.fn.readfile(path .. ".json"), { '{"version":999,"entries":[]}' })
  equal(uv.fs_stat(path .. ".lock"), nil)
end)

test("metadata commit survives export failure and retries without duplicating entries", function()
  local path = root .. "/export-failure"
  vim.fn.mkdir(path)
  local history = History.new(path, 100, function() return true end, 0)
  assert(not pcall(function() history:append(a, { visited_at = 123 }) end))
  equal(History.read(path), { a })
  equal(uv.fs_stat(path .. ".lock"), nil)
  assert(#history.operations > 0)
  uv.fs_rmdir(path)
  history:save()
  equal(vim.fn.readfile(path), { "0.3.0", a })
  equal(history.records, { { path = a, visited_at = 123 } })
end)

test("unreadable metadata cannot silently fall back to an export and lose timestamps", function()
  local path = root .. "/unreadable"
  local history = History.new(path, 100, function() return true end, 0)
  history:append(a, { written_at = 456 })
  local metadata = path .. ".json"
  assert(uv.fs_chmod(metadata, 0))
  if vim.fn.filereadable(metadata) == 0 then
    assert(not pcall(function() history:save() end))
  end
  assert(uv.fs_chmod(metadata, 384))
  history:sync()
  equal(history.records[1].written_at, 456)
  equal(uv.fs_stat(path .. ".lock"), nil)
end)

test("native JSON and legacy files can use arbitrary filename extensions", function()
  setup()
  local legacy = root .. "/legacy.json"
  vim.fn.writefile({ "0.3.0", a }, legacy)
  mru.import("file", legacy)
  equal(mru.list(), { a })
  local source = root .. "/metadata-no-extension"
  vim.fn.writefile({ vim.json.encode({ version = 1, entries = { { path = b, written_at = 321 } } }) }, source)
  mru.import("write", source)
  equal(mru.entries("write")[1].written_at, 321)
  assert(not pcall(mru.list, "directory", { time_field = "invalid" }))
end)

test("LS_COLORS adapter preserves labels and passes literal paths in one batch", function()
  local lscolors = require("mru.lscolors")
  local script = root .. "/colorizer.lua"
  local log = root .. "/colorizer-args"
  vim.fn.writefile({
    "vim.fn.writefile({ vim.json.encode(arg) }, vim.env.MRU_COLOR_TEST_LOG, 'a')",
    "local style = vim.env.LS_COLORS:match('%*%.lua=([^:]+)') or '0'",
    "for _, path in ipairs(arg) do io.write('\\27[' .. style .. 'm' .. path .. '\\27[0m\\n') end",
  }, script)
  local command = { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-i", "NONE", "-l", script }
  local paths = {
    root .. "/project/日本語 $(literal) :7 with space.lua",
    root .. "/project/absolute.lua",
    "/home/example/name.lua", "/home/example", root .. "/control\tname.lua",
  }
  local labels = { "日本語 $(literal) :7 with space.lua", paths[2], "~/name.lua", "~", "control\\tname.lua" }
  local previous_colors, previous_log = vim.env.LS_COLORS, vim.env.MRU_COLOR_TEST_LOG
  vim.env.LS_COLORS, vim.env.MRU_COLOR_TEST_LOG = "*.lua=35", log
  local result = lscolors.colorize(paths, labels, command)
  for i = 1, 4 do
    equal((result[i]:gsub("\27%[[0-9;]*m", "")), labels[i])
    assert(result[i]:find("\27[35m", 1, true))
  end
  equal(result[5], nil) -- Control characters cannot enter the line protocol.
  local calls = vim.fn.readfile(log)
  equal(#calls, 1)
  local arguments = vim.json.decode(calls[1])
  for i = 1, 4 do equal(arguments[tostring(i)], paths[i]) end
  equal(arguments["5"], nil)
  vim.env.LS_COLORS = "*.lua=36"
  assert(lscolors.colorize({ paths[1] }, { labels[1] }, command)[1]:find("\27[36m", 1, true))
  equal(lscolors.colorize(paths, labels, false), {})
  equal(lscolors.colorize(paths, labels, root .. "/missing-colorizer"), {})
  vim.fn.writefile({ "for _, path in ipairs(arg) do io.write('wrong path\\n') end" }, script)
  equal(lscolors.colorize(paths, labels, command), {})
  vim.fn.writefile({ "vim.cmd('cquit 1')" }, script)
  equal(lscolors.colorize(paths, labels, command), {})
  vim.env.LS_COLORS, vim.env.MRU_COLOR_TEST_LOG = previous_colors, previous_log
end)

test("picker theme fallback keeps compact, unpadded times", function()
  setup()
  local known = file("project/short.lua")
  local unknown = file("project/日本語のファイル.lua")
  local source = root .. "/picker-import"
  vim.fn.writefile({ "0.3.0", unknown }, source)
  mru.import("file", source)
  mru.append(known)
  local original = package.loaded["fzf-lua"]
  local captured
  package.loaded["fzf-lua"] = { fzf_exec = function(rows, opts) captured = { rows = rows, opts = opts } end }
  require("mru.fzf").open({ scope = "all", project = root .. "/project", previewer = false, color_cmd = false })
  local function plain(text) return (text:gsub("\27%[[0-9;]*m", "")) end
  for i, row in ipairs(captured.rows) do
    local fields = vim.split(row, "\t", { plain = true })
    local path, times = plain(fields[2]), plain(fields[3])
    assert(fields[2]:find("\27[", 1, true), "Filename coloring missing")
    assert(fields[3]:find("\27[", 1, true), "Timestamp coloring missing")
    equal(path, i == 1 and "short.lua" or "日本語のファイル.lua")
    if i == 1 then
      assert(times:match("^%d%d%-%d%d %d%d:%d%d %-%-$"))
    else
      equal(times, "-- --")
    end
    equal(captured.opts._fmt.from(row), i == 1 and known or unknown)
  end
  equal(captured.opts.fzf_opts["--tabstop"], "1")
  equal(captured.opts.fzf_opts["--nth"], "1")
  equal(captured.opts.fzf_opts["--ansi"], true)
  equal(vim.api.nvim_get_hl(0, { name = "MruTime" }).link, "Comment")
  local long = file("project/" .. string.rep("long-directory/", 10) .. "long.lua")
  mru.append(long)
  require("mru.fzf").open({ scope = "all", project = root .. "/project", previewer = false, color_cmd = false })
  local fields = vim.split(captured.rows[2], "\t", { plain = true })
  equal(plain(fields[2]), "short.lua")
  equal(captured.opts._fmt.from(captured.rows[1]), long)
  assert(plain(captured.rows[1]):find(string.rep("long-directory/", 10), 1, true))
  package.loaded["fzf-lua"] = original
end)

test("picker switches preserve the query and act on paths rather than labels", function()
  setup()
  local literal = file("project/picker:7 with space")
  mru.append(literal)
  mru.append(literal, "write")
  local calls = {}
  local original = package.loaded["fzf-lua"]
  package.loaded["fzf-lua"] = {
    fzf_exec = function(rows, opts) calls[#calls + 1] = { rows = rows, opts = opts } end,
    get_last_query = function() return "fallback" end,
  }
  local picker = require("mru.fzf")
  picker.open({ scope = "all", query = "initial", previewer = false })
  local first = calls[#calls]
  equal(first.opts._fmt.from(first.rows[1]), literal)
  first.opts.actions["ctrl-t"][1]({}, { last_query = "with space" })
  local second = calls[#calls]
  equal(second.opts.query, "with space")
  assert(second.opts.prompt:find("MRW", 1, true))
  assert(second.opts.header:match("^MRW |"))
  second.opts.actions["ctrl-g"][1]({}, { last_query = "" })
  local third = calls[#calls]
  equal(third.opts.query, "")
  assert(third.opts.prompt:find("cwd", 1, true))
  second.opts.actions["ctrl-x"][1]({ second.rows[1] }, { last_query = "with space" })
  equal(mru.list("write"), {})
  assert(vim.fn.filereadable(literal) == 1) -- Forgetting never deletes the file.
  first.opts.actions.enter({ first.rows[1] })
  equal(vim.api.nvim_buf_get_name(0), literal)
  package.loaded["fzf-lua"] = original
end)

test("concurrent Neovim processes retain every update", function()
  local path = root .. "/concurrent"
  local processes = {}
  for worker = 1, 3 do
    local code = string.format([[vim.opt.rtp:prepend(%q)
local h = require('mru.history').new(%q, 1000, function() return true end, 0)
for i = 1, 20 do h:append('worker-%d-' .. i) end]], vim.fn.getcwd(), path, worker)
    local script = root .. "/worker-" .. worker .. ".lua"
    vim.fn.writefile(vim.split(code, "\n"), script)
    processes[#processes + 1] = vim.system({ vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-i", "NONE", "-l", script })
  end
  for _, process in ipairs(processes) do
    local result = process:wait(10000)
    assert(result.code == 0, result.stderr)
  end
  local paths = History.read(path)
  equal(#paths, 60)
  for worker = 1, 3 do
    for i = 1, 20 do
      assert(vim.tbl_contains(paths, "worker-" .. worker .. "-" .. i))
    end
  end
end)

-- Flush before removing fixtures; disable exit handlers so they cannot recreate them.
mru.save()
vim.api.nvim_del_augroup_by_name("mru.nvim")
vim.fn.delete(root, "rf")
print(string.format("%d tests passed", count))
