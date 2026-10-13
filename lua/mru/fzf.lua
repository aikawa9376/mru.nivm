local M = {}

local function display_time(timestamp)
  return timestamp and os.date("%m-%d %H:%M", timestamp) or "--"
end

local function colors()
  local result = {}
  for name, link in pairs({
    FileName = "Directory", Directory = "Comment", Time = "Comment", Missing = "DiagnosticWarn",
  }) do
    local group = "Mru" .. name
    vim.api.nvim_set_hl(0, group, { default = true, link = link })
    local fg = vim.api.nvim_get_hl(0, { name = group, link = false }).fg
    result[name] = fg and string.format("\27[38;2;%d;%d;%dm",
      math.floor(fg / 65536), math.floor(fg / 256) % 256, fg % 256) or ""
  end
  return function(name, value)
    return result[name] == "" and value or result[name] .. value .. "\27[39m"
  end
end

local function cycle(value, choices)
  for i, choice in ipairs(choices) do
    if value == choice then
      return choices[i % #choices + 1]
    end
  end
  return choices[1]
end

---Open the optional fzf-lua picker. The core plugin does not depend on fzf-lua.
---@param opts? table
function M.open(opts)
  local ok, fzf = pcall(require, "fzf-lua")
  assert(ok, "mru: install/load fzf-lua to use this picker")
  local mru = require("mru")
  opts = vim.deepcopy(opts or {})
  opts.kind = opts.kind or "file"
  opts.scope = opts.scope or "project"
  opts.period = opts.period or "all"
  opts.project = opts.project or mru.project_root(opts.cwd)
  opts.cwd = opts.cwd or vim.fn.getcwd()
  local records = mru.entries(opts.kind, opts)
  local rows = {}
  local color = colors()
  for i, record in ipairs(records) do
    local path = vim.fn.fnamemodify(record.path, ":~")
    if require("mru.query").under(record.path, opts.project) then
      local prefix = opts.project:sub(-1) == "/" and opts.project or opts.project .. "/"
      if record.path ~= opts.project then
        path = record.path:sub(#prefix + 1)
      end
    end
    path = path:gsub("[\t\r\n]", { ["\t"] = "\\t", ["\r"] = "\\r", ["\n"] = "\\n" })
    local directory, filename = path:match("^(.-)([^/]*)$")
    local label = color("Directory", directory) .. color("FileName", filename)
    if record.missing then
      label = color("Missing", "[missing] ") .. label
    end
    local times = color("Time", display_time(record.visited_at) .. " " .. display_time(record.written_at))
    rows[i] = table.concat({ tostring(i), label, times }, "\t")
  end

  -- Stable row IDs keep labels, timestamps and filename punctuation out of actions.
  local function paths(selected)
    local result = {}
    for _, row in ipairs(selected or {}) do
      local id = tonumber(row:match("^(%d+)\t"))
      local record = id and records[id]
      if record then
        result[#result + 1] = record.path
      end
    end
    return result
  end

  local function open_files(command)
    return function(selected)
      for _, path in ipairs(paths(selected)) do
        vim.api.nvim_cmd({ cmd = command, args = { path } }, {})
      end
    end
  end

  local function refresh(change)
    -- Action arrays let fzf-lua reuse the window while launching fresh contents.
    return { function(selected, action_opts)
      local query = action_opts and action_opts.last_query
      if query == nil and type(fzf.get_last_query) == "function" then
        query = fzf.get_last_query()
      end
      opts.query = query or opts.query or ""
      if change then
        change(selected)
      end
      M.open(opts)
    end }
  end

  local actions = {
    ["enter"] = open_files("edit"),
    ["ctrl-s"] = open_files("split"),
    ["ctrl-v"] = open_files("vsplit"),
    ["alt-enter"] = open_files("tabedit"),
    ["ctrl-q"] = function(selected)
      local items = vim.tbl_map(function(path) return { filename = path, lnum = 1 } end, paths(selected))
      vim.fn.setqflist({}, " ", { title = "MRU", items = items })
      vim.cmd.copen()
    end,
    ["ctrl-t"] = refresh(function()
      opts.kind = opts.kind == "write" and "file" or "write"
    end),
    ["ctrl-g"] = refresh(function()
      opts.scope = cycle(opts.scope, { "project", "all", "cwd" })
    end),
    ["alt-d"] = refresh(function()
      opts.period = cycle(opts.period, { "all", "hour", "today", "yesterday", "week" })
    end),
    ["ctrl-h"] = refresh(function()
      opts.include_missing = not opts.include_missing
    end),
    ["ctrl-r"] = refresh(),
    ["ctrl-x"] = refresh(function(selected)
      mru.delete(opts.kind, paths(selected))
    end),
  }
  for binding, action in pairs(opts.actions or {}) do
    assert(type(action) == "function" or action == false, "mru: custom picker actions must be functions or false")
    actions[binding] = action and function(selected, action_opts)
      return action(paths(selected), action_opts)
    end or false
  end
  local mode = opts.kind == "write" and "MRW" or "MRU"
  local picker_opts = vim.tbl_deep_extend("force", {
    prompt = mode .. " / " .. opts.scope .. " / " .. opts.period .. "> ",
    header = mode .. " | File / Seen / Saved | ctrl-t: MRU/MRW  ctrl-g: scope  alt-d: period  ctrl-h: missing  ctrl-x: forget",
    previewer = "builtin",
    query = opts.query,
    cwd = opts.cwd,
    actions = actions,
    file_icons = false,
    git_icons = false,
    fzf_opts = {
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      -- Internal fields stay separate for path-only search. A one-cell tab stop
      -- displays their separator as a single space without aligning columns.
      ["--tabstop"] = "1",
      -- --nth addresses the displayed fields after --with-nth removes the ID.
      ["--nth"] = "1",
      ["--ansi"] = true,
      ["--multi"] = true,
      ["--tiebreak"] = "index",
      ["--scheme"] = "history",
    },
    _fmt = { from = function(row) return paths({ row })[1] or "" end },
  }, opts.picker or {})
  -- Preserve the ID fields needed by previews/actions even with custom display options.
  picker_opts.actions = actions
  picker_opts.query = opts.query or picker_opts.query
  picker_opts._fmt = { from = function(row) return paths({ row })[1] or "" end }
  if opts.previewer ~= nil then
    picker_opts.previewer = opts.previewer
  end
  return fzf.fzf_exec(rows, picker_opts)
end

return M
