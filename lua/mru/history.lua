local uv = vim.uv or vim.loop
local M = {}
M.__index = M
M.VERSION = "0.3.0" -- Plain-path export and legacy import version.
M.SCHEMA = 1

local function key(path)
  return (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and vim.fn.tolower(path) or path
end

local function clock()
  local seconds, micros = uv.gettimeofday()
  return seconds + micros / 1000000
end

local function copy(record)
  return vim.deepcopy(record)
end

local function merge(target, source)
  for _, field in ipairs({ "visited_at", "written_at" }) do
    if source[field] then
      target[field] = math.max(target[field] or 0, source[field])
    end
  end
  return target
end

local function unique(records, limit)
  local result, seen = {}, {}
  for _, record in ipairs(records) do
    local id = key(record.path)
    if seen[id] then
      merge(seen[id], record)
    elseif #result < limit then
      local item = copy(record)
      seen[id] = item
      result[#result + 1] = item
    end
  end
  return result
end

local function legacy(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  assert(lines[1] == M.VERSION, "mru: unsupported history version in " .. path)
  local records = {}
  for i = 2, #lines do
    local name = lines[i]:match("^[^\t]*")
    if name ~= "" then
      records[#records + 1] = { path = name }
    end
  end
  return records
end

local function validate_record(record, path)
  assert(type(record) == "table" and type(record.path) == "string"
    and record.path ~= "" and not record.path:find("[\r\n]"), "mru: invalid entry in " .. path)
  for _, field in ipairs({ "visited_at", "written_at" }) do
    assert(record[field] == nil or type(record[field]) == "number"
      and record[field] >= 0 and record[field] < math.huge, "mru: invalid timestamp in " .. path)
  end
end

local function decode_state(metadata)
  local state = vim.json.decode(table.concat(vim.fn.readfile(metadata), "\n"))
  assert(type(state) == "table" and state.version == M.SCHEMA,
    "mru: unsupported metadata version in " .. metadata)
  assert(type(state.entries) == "table" and vim.islist(state.entries), "mru: invalid entries in " .. metadata)
  state.moves = state.moves or {}
  assert(type(state.moves) == "table" and vim.islist(state.moves), "mru: invalid moves in " .. metadata)
  for _, record in ipairs(state.entries) do
    validate_record(record, metadata)
  end
  for _, move in ipairs(state.moves) do
    assert(type(move) == "table" and type(move.from) == "string" and type(move.to) == "string"
      and move.from ~= "" and move.to ~= "" and not move.from:find("[\r\n]") and not move.to:find("[\r\n]")
      and type(move.at) == "number" and move.at >= 0 and move.at < math.huge
      and type(move.directory) == "boolean", "mru: invalid move in " .. metadata)
  end
  return state
end

local function read_state(path)
  local metadata = path .. ".json"
  if uv.fs_lstat(metadata) then
    assert(vim.fn.filereadable(metadata) == 1, "mru: metadata is not readable: " .. metadata)
    return decode_state(metadata)
  end
  local records = legacy(path) or {}
  local long = legacy(path .. "_long")
  if long then
    vim.list_extend(records, long)
  end
  return { entries = records, moves = {} }
end

---Read paths from canonical storage, or directly from a legacy import file.
function M.read(path, import)
  local records
  if import then
    records = M.read_records(path)
  elseif uv.fs_lstat(path .. ".json") or vim.fn.filereadable(path) == 1 then
    records = read_state(path).entries
  end
  return records and vim.tbl_map(function(record) return record.path end, records) or nil
end

function M.read_records(path)
  if uv.fs_lstat(path .. ".json") then
    return read_state(path).entries
  end
  if vim.fn.filereadable(path) == 1 then
    local first = vim.fn.readfile(path, "", 1)[1] or ""
    if first:match("^%s*{") then
      return decode_state(path).entries
    end
  end
  return legacy(path)
end

local function translated(path, move)
  if key(path) == key(move.from) then
    return move.to
  end
  local prefix = move.from:sub(-1) == "/" and move.from or move.from .. "/"
  if move.directory and key(path):sub(1, #prefix) == key(prefix) then
    return move.to:gsub("/$", "") .. "/" .. path:sub(#prefix + 1)
  end
  return path
end

function M.new(path, limit, exists, interval, allowed)
  return setmetatable({
    path = path, limit = limit, validate_path = exists, allowed_path = allowed or function() return true end,
    interval = interval, candidates = {}, records = {}, operations = {}, last_save = 0,
  }, M)
end

function M:sync()
  local state = read_state(self.path)
  local records = state.entries
  for _, op in ipairs(self.operations) do
    if op.kind == "append" or op.kind == "delete" then
      local path = op.path
      -- A buffered event recorded before another instance's rename follows that rename.
      for _, move in ipairs(state.moves) do
        if op.at <= move.at then
          path = translated(path, move)
        end
      end
      local filtered, prior = {}, { path = path }
      for _, record in ipairs(records) do
        if key(record.path) ~= key(path) then
          filtered[#filtered + 1] = record
        else
          merge(prior, record)
        end
      end
      records = filtered
      if op.kind == "append" then
        merge(prior, op.record)
        table.insert(records, 1, prior)
      end
    elseif op.kind == "import" then
      vim.list_extend(records, copy(op.records))
    elseif op.kind == "rename" then
      for _, record in ipairs(records) do
        record.path = translated(record.path, op.move)
      end
      local known = false
      for _, move in ipairs(state.moves) do
        if vim.deep_equal(move, op.move) then
          known = true
          break
        end
      end
      if not known then
        state.moves[#state.moves + 1] = copy(op.move)
      end
    end
  end
  self.records = unique(records, self.limit)
  self.candidates = vim.tbl_map(function(record) return record.path end, self.records)
  self.moves = state.moves
  return self.candidates
end

function M:append(path, metadata)
  self:sync()
  if self.candidates[1] == path then
    local same = true
    for field, value in pairs(metadata or {}) do
      if self.records[1][field] ~= value then
        same = false
        break
      end
    end
    if same then
      return
    end
  end
  local record = metadata and copy(metadata) or {}
  record.path = path
  validate_record(record, self.path)
  self.operations[#self.operations + 1] = { kind = "append", path = path, record = record, at = clock() }
  self:sync()
  if self.interval == 0 or os.time() >= self.last_save + self.interval then
    self:save()
  end
end

function M:import(items)
  local records = {}
  for _, item in ipairs(items) do
    local record = type(item) == "string" and { path = item } or copy(item)
    validate_record(record, self.path)
    records[#records + 1] = record
  end
  self.operations[#self.operations + 1] = { kind = "import", records = records }
  self:save()
end

function M:delete(paths)
  for _, path in ipairs(paths) do
    self.operations[#self.operations + 1] = { kind = "delete", path = path, at = clock() }
  end
  self:save()
end

function M:rename(from, to, directory)
  self.operations[#self.operations + 1] = {
    kind = "rename", move = { from = from, to = to, directory = directory == true, at = clock() },
  }
  self:save()
end

function M:reload()
  -- Presence is evaluated by the query. Missing records survive branch changes.
  self:sync()
end

function M:save(validate)
  vim.fn.mkdir(vim.fn.fnamemodify(self.path, ":h"), "p")
  local lock = self.path .. ".lock"
  local fd
  vim.wait(250, function()
    fd = uv.fs_open(lock, "wx", 384)
    return fd ~= nil
  end, 10)
  assert(fd, "mru: cannot acquire history lock " .. lock)
  local temp = self.path .. "." .. uv.os_getpid() .. ".tmp"
  local metadata_temp = temp .. ".json"
  local ok, err = pcall(function()
    self:sync()
    local records = self.records
    if validate then
      records = vim.tbl_filter(function(record) return self.allowed_path(record.path) end, records)
    end
    local lines = { M.VERSION }
    for _, record in ipairs(records) do
      if self.allowed_path(record.path) and self.validate_path(record.path) then
        lines[#lines + 1] = record.path
      end
    end
    local state = { version = M.SCHEMA, entries = records, moves = self.moves }
    vim.fn.writefile({ vim.json.encode(state) }, metadata_temp)
    vim.fn.writefile(lines, temp)
    -- Metadata is authoritative. A failed export is regenerated on the next save.
    local renamed, rename_err = uv.fs_rename(metadata_temp, self.path .. ".json")
    assert(renamed, rename_err)
    renamed, rename_err = uv.fs_rename(temp, self.path)
    assert(renamed, rename_err)
    self.records, self.operations = records, {}
    self.candidates = vim.tbl_map(function(record) return record.path end, records)
    self.last_save = os.time()
  end)
  uv.fs_unlink(temp)
  uv.fs_unlink(metadata_temp)
  uv.fs_close(fd)
  uv.fs_unlink(lock)
  if not ok then
    error(err)
  end
end

return M
