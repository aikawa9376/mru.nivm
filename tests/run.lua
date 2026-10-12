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
  vim.fn.writefile({ "0.3.0", c, a }, path)
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
  mru.save()
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
  equal(mru.list("write"), { "custom://path" })
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
