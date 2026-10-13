local M = {}

function M.timestamp(record, kind, field)
  if field then
    assert(field == "visited_at" or field == "written_at", "mru: invalid time_field")
    return record[field]
  end
  if kind == "write" then
    return record.written_at
  end
  return record.visited_at and record.written_at and math.max(record.visited_at, record.written_at)
    or record.visited_at or record.written_at
end

function M.bounds(opts)
  assert(opts.time_field == nil or opts.time_field == "visited_at" or opts.time_field == "written_at",
    "mru: invalid time_field")
  local since, before = opts.since, opts["until"]
  if opts.period and opts.period ~= "all" then
    local now = os.time()
    local date = os.date("*t", now)
    date.hour, date.min, date.sec, date.isdst = 0, 0, 0, nil
    local today = os.time(date)
    if opts.period == "today" then
      since = since or today
    elseif opts.period == "yesterday" then
      date.day = date.day - 1
      since, before = since or os.time(date), before or today
    elseif opts.period == "hour" then
      since = since or now - 3600
    elseif opts.period == "week" then
      since = since or now - 7 * 86400
    else
      error("mru: unknown period " .. tostring(opts.period))
    end
  end
  assert(since == nil or type(since) == "number", "mru: since must be a Unix timestamp")
  assert(before == nil or type(before) == "number", "mru: until must be a Unix timestamp")
  return since, before
end

function M.under(path, root)
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    path, root = vim.fn.tolower(path), vim.fn.tolower(root)
  end
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  return path == root or path:sub(1, #prefix) == prefix
end

return M
