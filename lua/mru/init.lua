local History = require("mru.history")
local M = {}
local histories
local config
local buffer_names = {}

---@class mru.Entry
---@field path string
---@field visited_at? number Unix seconds, absent for unknown visits.
---@field written_at? number Unix seconds, absent for unknown saves.
---@field missing boolean

---@class mru.Query
---@field scope? 'all'|'cwd'|'project'
---@field cwd? string
---@field project? string Explicit project root.
---@field period? 'all'|'hour'|'today'|'yesterday'|'week'
---@field since? number Inclusive Unix seconds; the "until" key is exclusive.
---@field time_field? 'visited_at'|'written_at'
---@field include_missing? boolean
---@field validate? boolean

local function is_uri(path)
  return path:match("^%a[%w+.-]*://") ~= nil
end

local function normalize(path)
  if is_uri(path) then
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

local function allowed(path, kind)
  if config.ignore(path, kind) or path:find("[\r\n]") then
    return false
  end
  return true
end

local function exists(path, kind)
  if is_uri(path) then
    return true
  end
  if kind == "directory" then
    return vim.fn.isdirectory(path) == 1
  end
  local filetype = vim.fn.getftype(path)
  return filetype == "file" or filetype == "link"
end

local function valid(path, kind)
  return allowed(path, kind) and exists(path, kind)
end

local function path_key(path)
  return (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and vim.fn.tolower(path) or path
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
  local timestamp = kind == "write" and { written_at = os.time() } or { visited_at = os.time() }
  if valid(path, kind or "file") then
    get(kind):append(path, timestamp)
  end
  if (kind == nil or kind == "file") and not is_uri(path) then
    local directory = normalize(vim.fn.fnamemodify(path, ":h"))
    if valid(directory, "directory") then
      get("directory"):append(directory, { visited_at = os.time() })
    end
  end
end

---Resolve the project of a file/directory (defaults to the current buffer or cwd).
function M.project_root(start)
  get()
  if not start then
    local buffer = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buffer)
    start = vim.bo[buffer].buftype == "" and name ~= "" and not is_uri(name)
      and name or vim.fn.getcwd()
  end
  return require("mru.project").resolve(start, config, normalize)
end

---Return metadata records, newest first. Missing entries are hidden by default.
---@param kind? 'file'|'write'|'directory'
---@param opts? mru.Query
---@return mru.Entry[]
function M.entries(kind, opts)
  local history = get(kind)
  kind = kind or "file"
  opts = opts or {}
  if opts.validate then
    history:reload()
  else
    history:sync()
  end
  local scope = opts.scope or (opts.cwd and "cwd" or "all")
  assert(scope == "all" or scope == "cwd" or scope == "project", "mru: unknown scope " .. tostring(scope))
  local root
  if scope == "cwd" then
    root = normalize(opts.cwd or vim.fn.getcwd())
  elseif scope == "project" then
    root = opts.project and normalize(opts.project) or M.project_root(opts.cwd)
  end
  local query = require("mru.query")
  local since, before = query.bounds(opts)
  local related = {}
  if kind == "file" or kind == "write" then
    local other = get(kind == "file" and "write" or "file")
    other:sync()
    for _, record in ipairs(other.records) do
      related[path_key(record.path)] = record
    end
  end
  local records = {}
  for _, record in ipairs(history.records) do
    local item = vim.deepcopy(record)
    for _, field in ipairs({ "visited_at", "written_at" }) do
      local other = related[path_key(record.path)]
      if other and other[field] then
        item[field] = math.max(item[field] or 0, other[field])
      end
    end
    local timestamp = query.timestamp(item, kind, opts.time_field)
    local missing = not exists(record.path, kind)
    if allowed(record.path, kind) and (opts.include_missing or not missing)
      and (not root or query.under(record.path, root))
      and (not since or timestamp and timestamp >= since)
      and (not before or timestamp and timestamp < before) then
      item.missing = missing
      records[#records + 1] = item
    end
  end
  return records
end

---Return recent paths, newest first. The returned list is an independent copy.
---@param kind? 'file'|'write'|'directory'
---@param opts? mru.Query
---@return string[]
function M.list(kind, opts)
  return vim.tbl_map(function(record) return record.path end, M.entries(kind, opts))
end

---@param kind 'file'|'write'|'directory'
---@param paths string[]
function M.delete(kind, paths)
  local history = get(kind)
  history:delete(vim.tbl_map(normalize, paths))
end

---Import native JSON, headerless paths or legacy histories (and an optional _long file).
---@param kind 'file'|'write'|'directory'
---@param path string
---@param opts? {oldfiles?: boolean}
function M.import(kind, path, opts)
  local history = get(kind)
  path = normalize(path)
  local records = History.read_records(path)
  assert(records, "mru: import file not found: " .. path)
  local long = History.read_records(path .. "_long")
  if long then
    vim.list_extend(records, long)
  end
  if opts and opts.oldfiles then
    for _, oldfile in ipairs(vim.v.oldfiles) do
      records[#records + 1] = { path = oldfile }
    end
  end
  for _, record in ipairs(records) do
    record.path = normalize(record.path)
  end
  history:import(vim.tbl_filter(function(record)
    return allowed(record.path, kind)
  end, records))
end

---Update history after an explicit file or directory move. Does not move files.
function M.rename(from, to, opts)
  get()
  assert(type(from) == "string" and from ~= "" and type(to) == "string" and to ~= "", "mru: invalid rename paths")
  from, to = normalize(from), normalize(to)
  if from == to then
    return
  end
  local directory = opts and opts.directory
  if directory == nil then
    directory = vim.fn.isdirectory(from) == 1 or vim.fn.isdirectory(to) == 1
  end
  for _, kind in ipairs({ "file", "write", "directory" }) do
    if kind ~= "directory" or directory then
      get(kind):rename(from, to, directory)
    end
  end
end

---Persist native metadata and regenerate plain-path exports for all histories.
function M.migrate()
  M.save()
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
        return allowed(path, kind)
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
  -- Panels can enter the window before their creator sets buftype=nofile.
  if path ~= "" and not is_uri(path) then
    if write then
      if valid(path, "file") then
        get("file"):append(normalize(path), { written_at = os.time() })
      end
      M.append(path, "write")
    else
      M.append(path)
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
  buffer_names = {}
  for kind, settings in pairs(config.histories) do
    histories[kind] = History.new(settings.path, settings.limit, function(path)
      return exists(path, kind)
    end, config.save_interval, function(path)
      return allowed(path, kind)
    end)
  end
  local group = vim.api.nvim_create_augroup("mru.nvim", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "VimEnter", "BufWinEnter" }, {
    group = group, callback = safe(function(event) record_buffer(event, false) end),
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, callback = safe(function(event) record_buffer(event, true) end),
  })
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = safe(M.sync) })
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = group, callback = function(event)
      local name = vim.api.nvim_buf_get_name(event.buf)
      if vim.bo[event.buf].buftype == "" and not is_uri(name) then
        buffer_names[event.buf] = name
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group, callback = safe(function(event)
      local from = buffer_names[event.buf]
      buffer_names[event.buf] = nil
      local to = vim.api.nvim_buf_get_name(event.buf)
      if from and from ~= "" and to ~= "" and not is_uri(to) then
        M.rename(from, to)
      end
    end),
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group, callback = function(event) buffer_names[event.buf] = nil end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "MruRename", callback = safe(function(event)
      assert(type(event.data) == "table", "mru: MruRename requires data")
      M.rename(event.data.from, event.data.to, { directory = event.data.directory })
    end),
  })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "OilActionsPost", callback = safe(function(event)
      if not event.data or event.data.err then
        return
      end
      for _, action in ipairs(event.data.actions or {}) do
        if action.type == "move" and action.src_url:sub(1, 6) == "oil://"
          and action.dest_url:sub(1, 6) == "oil://" then
          M.rename(action.src_url:sub(7), action.dest_url:sub(7), { directory = action.entry_type == "directory" })
        end
      end
    end),
  })
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
  vim.api.nvim_create_user_command("MruMigrate", safe(M.migrate), { force = true })
  vim.api.nvim_create_user_command("MruRename", safe(function(args)
    assert(#args.fargs == 2, "mru: MruRename requires old and new paths")
    M.rename(args.fargs[1], args.fargs[2], { directory = args.bang })
  end), { nargs = "+", bang = true, complete = "file", force = true })
  for _, spec in ipairs({ { "Mru", "file" }, { "Mrw", "write" } }) do
    vim.api.nvim_create_user_command(spec[1], safe(function()
      require("mru.fzf").open({ kind = spec[2] })
    end), { force = true })
  end
end

function M._ensure_setup()
  get()
end

return M
