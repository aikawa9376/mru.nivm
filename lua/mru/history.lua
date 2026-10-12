local uv = vim.uv or vim.loop
local M = {}
M.__index = M
M.VERSION = "0.3.0"

local function key(path)
  return (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and vim.fn.tolower(path) or path
end

local function unique(paths, limit)
  local result, seen = {}, {}
  for _, path in ipairs(paths) do
    local id = key(path)
    if path ~= "" and not seen[id] and #result < limit then
      seen[id] = true
      result[#result + 1] = path
    end
  end
  return result
end

function M.read(path, import)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  assert(lines[1] == M.VERSION, "mru: unsupported history version in " .. path)
  table.remove(lines, 1)
  if import then
    for i, line in ipairs(lines) do
      lines[i] = line:match("^[^\t]*")
    end
  end
  return lines
end

function M.new(path, limit, validate, interval)
  return setmetatable({
    path = path, limit = limit, validate_path = validate,
    interval = interval, candidates = {}, operations = {}, last_save = 0,
  }, M)
end

function M:sync()
  local paths = M.read(self.path) or {}
  for _, op in ipairs(self.operations) do
    if op.kind == "append" or op.kind == "delete" then
      local filtered = {}
      for _, path in ipairs(paths) do
        if key(path) ~= key(op.path) then
          filtered[#filtered + 1] = path
        end
      end
      paths = filtered
      if op.kind == "append" then
        table.insert(paths, 1, op.path)
      end
    elseif op.kind == "import" then
      vim.list_extend(paths, op.paths)
    end
  end
  self.candidates = unique(paths, self.limit)
  return self.candidates
end

function M:append(path)
  self:sync()
  if self.candidates[1] == path then
    return
  end
  self.operations[#self.operations + 1] = { kind = "append", path = path }
  self:sync()
  if self.interval == 0 or os.time() >= self.last_save + self.interval then
    self:save()
  end
end

function M:import(paths)
  self.operations[#self.operations + 1] = { kind = "import", paths = paths }
  self:save()
end

function M:delete(paths)
  for _, path in ipairs(paths) do
    self.operations[#self.operations + 1] = { kind = "delete", path = path }
  end
  self:save()
end

function M:reload()
  self:sync()
  -- Explicit reload always validates; exit validation is independently configurable.
  local invalid = {}
  for _, path in ipairs(self.candidates) do
    if not self.validate_path(path) then
      invalid[#invalid + 1] = path
    end
  end
  for _, path in ipairs(invalid) do
    self.operations[#self.operations + 1] = { kind = "delete", path = path }
  end
  self:sync()
end

function M:save(validate)
  vim.fn.mkdir(vim.fn.fnamemodify(self.path, ":h"), "p")
  -- Serialize the complete read/merge/write, including same-second updates.
  local lock = self.path .. ".lock"
  local fd
  vim.wait(250, function()
    fd = uv.fs_open(lock, "wx", 384)
    return fd ~= nil
  end, 10)
  assert(fd, "mru: cannot acquire history lock " .. lock)
  local temp = self.path .. "." .. uv.os_getpid() .. ".tmp"
  local ok, err = pcall(function()
    self:sync()
    local paths = self.candidates
    if validate then
      paths = vim.tbl_filter(self.validate_path, paths)
    end
    local lines = { M.VERSION }
    vim.list_extend(lines, paths)
    vim.fn.writefile(lines, temp)
    local renamed, rename_err = uv.fs_rename(temp, self.path)
    assert(renamed, rename_err)
    self.candidates, self.operations = paths, {}
    self.last_save = os.time()
  end)
  uv.fs_unlink(temp)
  uv.fs_close(fd)
  uv.fs_unlink(lock)
  if not ok then
    error(err)
  end
end

return M
