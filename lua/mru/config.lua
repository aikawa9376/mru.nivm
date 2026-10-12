local M = {}

local function default_ignore(path, kind)
  if path:match("^\\\\") or path:match("^/mnt/") or path:match("^/media/")
    or path:match("^/temp/") or path:match("^/tmp/")
    or path:match("^/var/folders/") or path:match("^/private/var/folders/") then
    return true
  end
  for segment in path:gmatch("[^/]+") do
    if segment == ".git" or segment == ".hg" or segment == ".bzr" or segment == ".svn" then
      return true
    end
  end
  if kind ~= "directory" then
    if path:match("~$") or path:match("^fugitive://")
      or path:match("^gitgutter://") or path:match("^term://") then
      return true
    end
    local extension = path:match("%.([^./]+)$")
    return vim.tbl_contains({ "o", "exe", "dll", "bak", "zwc", "pyc", "swp", "swo" }, extension)
  end
  return false
end

function M.resolve(opts)
  opts = opts or {}
  local cache = vim.env.XDG_CACHE_HOME
  local config = vim.tbl_deep_extend("force", {
    storage_dir = (cache and cache ~= "" and cache or vim.fn.expand("~/.cache")) .. "/neomru",
    max_entries = 1000,
    save_interval = 0,
    validate_on_exit = true,
    follow_links = false,
    focus_oldfiles = false,
    ignore = default_ignore,
    histories = { file = {}, write = {}, directory = {} },
  }, opts)
  local known = { storage_dir = true, max_entries = true, save_interval = true,
    validate_on_exit = true, follow_links = true, focus_oldfiles = true,
    ignore = true, histories = true }
  for name in pairs(opts) do
    assert(known[name], "mru: unknown option " .. name)
  end
  assert(type(config.storage_dir) == "string" and config.storage_dir ~= "", "mru: invalid storage_dir")
  assert(type(config.ignore) == "function", "mru: ignore must be a function")
  for _, name in ipairs({ "validate_on_exit", "follow_links", "focus_oldfiles" }) do
    assert(type(config[name]) == "boolean", "mru: invalid " .. name)
  end
  assert(type(config.save_interval) == "number" and config.save_interval >= 0, "mru: invalid save_interval")
  assert(type(config.max_entries) == "number" and config.max_entries >= 0
    and config.max_entries % 1 == 0, "mru: max_entries must be a nonnegative integer")
  local paths = {}
  for kind, history in pairs(config.histories) do
    assert(kind == "file" or kind == "write" or kind == "directory", "mru: unknown history " .. kind)
    for name in pairs(history) do
      assert(name == "path" or name == "limit", "mru: unknown history option " .. name)
    end
    history.path = history.path or config.storage_dir .. "/" .. kind
    history.limit = history.limit or config.max_entries
    assert(type(history.path) == "string" and history.path ~= "", "mru: invalid history path")
    assert(type(history.limit) == "number" and history.limit >= 0
      and history.limit % 1 == 0, "mru: history limit must be a nonnegative integer")
    history.path = vim.fn.fnamemodify(vim.fn.expand(history.path), ":p")
    assert(not paths[history.path], "mru: history paths must be distinct")
    paths[history.path] = true
  end
  return config
end

return M
