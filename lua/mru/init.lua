local History = require("mru.history")
local M = {}
local histories
local config

local function normalize(path)
  if path:match("^%a[%w+.-]*://") then
    return path
  end
  -- Expand only a leading home marker; literal %, # and $ in filenames stay literal.
  if path == "~" or path:sub(1, 2) == "~/" then
    path = vim.fn.expand("~") .. path:sub(2)
  end
  path = vim.fn.simplify(vim.fn.fnamemodify(path, ":p"))
  if config.follow_links then
    path = vim.fn.resolve(path)
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    path = path:gsub("\\", "/")
  end
  if #path > 1 and not path:match("^%a:/$") then
    path = path:gsub("/$", "")
  end
  return path
end

local function valid(path, kind)
  if config.ignore(path, kind) or path:find("[\r\n]") then
    return false
  end
  if path:match("^%a[%w+.-]*://") then
    return true
  end
  if kind == "directory" then
    return vim.fn.isdirectory(path) == 1
  end
  local filetype = vim.fn.getftype(path)
  return filetype == "file" or filetype == "link"
end

local function get(kind)
  if not histories then
    M.setup()
  end
  kind = kind or "file"
  assert(histories[kind], "mru: unknown history " .. tostring(kind))
  return histories[kind]
end

local function safe(callback)
  return function(...)
    local ok, err = pcall(callback, ...)
    if not ok then
      vim.notify(tostring(err), vim.log.levels.ERROR, { title = "mru.nvim" })
    end
  end
end

---Record a file and its containing directory, or a specific history.
---@param path string
---@param kind? 'file'|'write'|'directory'
function M.append(path, kind)
  get(kind)
  assert(type(path) == "string", "mru: path must be a string")
  if path == "" then
    return
  end
  path = normalize(path)
  if valid(path, kind or "file") then
    get(kind):append(path)
  end
  if kind == nil or kind == "file" then
    local directory = normalize(vim.fn.fnamemodify(path, ":h"))
    if valid(directory, "directory") then
      get("directory"):append(directory)
    end
  end
end

---Return recent paths, newest first. The returned list is an independent copy.
---@param kind? 'file'|'write'|'directory'
---@param opts? {cwd?: string, validate?: boolean}
---@return string[]
function M.list(kind, opts)
  local history = get(kind)
  opts = opts or {}
  if opts.validate then
    history:reload()
  else
    history:sync()
  end
  local paths = vim.deepcopy(history.candidates)
  if opts.cwd then
    local cwd = normalize(opts.cwd)
    local prefix = cwd:sub(-1) == "/" and cwd or cwd .. "/"
    paths = vim.tbl_filter(function(path)
      return path == cwd or path:sub(1, #prefix) == prefix
    end, paths)
  end
  return paths
end

---@param kind 'file'|'write'|'directory'
---@param paths string[]
function M.delete(kind, paths)
  local history = get(kind)
  history:delete(vim.tbl_map(normalize, paths))
end

---Import a neomru 0.3.0 file (and optional _long file).
---@param kind 'file'|'write'|'directory'
---@param path string
---@param opts? {oldfiles?: boolean}
function M.import(kind, path, opts)
  local history = get(kind)
  path = normalize(path)
  local paths = History.read(path, true)
  assert(paths, "mru: import file not found: " .. path)
  local long = History.read(path .. "_long", true)
  if long then
    vim.list_extend(paths, long)
  end
  if opts and opts.oldfiles then
    vim.list_extend(paths, vim.v.oldfiles)
  end
  paths = vim.tbl_map(normalize, paths)
  history:import(vim.tbl_filter(function(item)
    return valid(item, kind)
  end, paths))
end

function M.save(opts)
  get()
  for _, kind in ipairs({ "file", "write", "directory" }) do
    histories[kind]:save(opts and opts.validate)
  end
end

function M.reload()
  get()
  for _, history in pairs(histories) do
    history:reload()
  end
end

function M.sync()
  get()
  for _, history in pairs(histories) do
    history:sync()
  end
  if config.focus_oldfiles then
    for _, kind in ipairs({ "file", "write" }) do
      local paths = vim.tbl_filter(function(path)
        return valid(path, kind)
      end, vim.tbl_map(normalize, vim.v.oldfiles))
      histories[kind]:import(paths)
    end
  end
end

local function record_buffer(event, write)
  local buffer = event.buf or vim.api.nvim_get_current_buf()
  if buffer ~= vim.api.nvim_get_current_buf() or not vim.api.nvim_buf_is_valid(buffer)
    or vim.bo[buffer].buftype ~= "" or vim.wo.previewwindow then
    return
  end
  local path = vim.api.nvim_buf_get_name(buffer)
  if path ~= "" then
    M.append(path)
    if write then
      M.append(path, "write")
    end
  end
end

---@param opts? table
function M.setup(opts)
  local resolved = require("mru.config").resolve(opts)
  if histories then
    for _, history in pairs(histories) do
      if #history.operations > 0 then
        history:save()
      end
    end
  end
  config, histories = resolved, {}
  for kind, settings in pairs(config.histories) do
    histories[kind] = History.new(settings.path, settings.limit, function(path)
      return valid(path, kind)
    end, config.save_interval)
  end
  local group = vim.api.nvim_create_augroup("mru.nvim", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "VimEnter", "BufWinEnter" }, {
    group = group, callback = safe(function(event) record_buffer(event, false) end),
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, callback = safe(function(event) record_buffer(event, true) end),
  })
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = safe(M.sync) })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group, callback = safe(function() M.save({ validate = config.validate_on_exit }) end),
  })
  for _, prefix in ipairs({ "Mru", "NeoMRU" }) do
    vim.api.nvim_create_user_command(prefix .. "Save", safe(function() M.save() end), { force = true })
    vim.api.nvim_create_user_command(prefix .. "Reload", safe(M.reload), { force = true })
  end
  for _, kind in ipairs({ "file", "write", "directory" }) do
    local title = kind:sub(1, 1):upper() .. kind:sub(2)
    vim.api.nvim_create_user_command("MruImport" .. title, safe(function(args)
      M.import(kind, args.args)
    end), { nargs = 1, complete = "file", force = true })
  end
end

function M._ensure_setup()
  get()
end

return M
