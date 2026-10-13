local M = {}

local function command_for(command)
  if command == false then return end
  if command == nil then
    for _, candidate in ipairs({ vim.fn.stdpath("config") .. "/bin/color-ls", "color-ls" }) do
      if vim.fn.executable(candidate) == 1 then return { candidate } end
    end
    return
  end
  if type(command) == "string" then command = { command } end
  assert(type(command) == "table" and #command > 0, "mru: color_cmd must be a command string, argument list or false")
  for _, argument in ipairs(command) do
    assert(type(argument) == "string", "mru: color_cmd arguments must be strings")
  end
  if vim.fn.executable(command[1]) == 1 then return vim.deepcopy(command) end
end

local function plain(text)
  return (text:gsub("\27%[[0-9;:]*m", ""))
end

local function shorten(text, path, label)
  if plain(text) ~= path then return end
  if path == label then return text end
  local skip, replacement
  if path:sub(-#label) == label then
    skip, replacement = #path - #label, ""
  elseif label:sub(1, 1) == "~" and (label == "~" or path:sub(1 - #label) == label:sub(2)) then
    skip, replacement = #path - #label + 1, "~"
  else
    return
  end
  -- Discard only visible prefix bytes. Retain SGR sequences so colors still
  -- describe the actual path after displaying it relative to a project or home.
  local result, cursor = {}, 1
  while cursor <= #text do
    local first, last = text:find("\27%[[0-9;:]*m", cursor)
    local chunk = text:sub(cursor, first and first - 1 or #text)
    if skip >= #chunk then
      skip = skip - #chunk
      if skip == 0 then
        result[#result + 1], replacement = replacement, ""
      end
    else
      result[#result + 1] = replacement .. chunk:sub(skip + 1)
      skip, replacement = 0, ""
    end
    if not first then break end
    result[#result + 1] = text:sub(first, last)
    cursor = last + 1
  end
  return table.concat(result)
end

---Color actual paths in one process, retaining the corresponding display labels.
---Unavailable/failed colorizers and unsupported filenames use the picker theme.
function M.colorize(paths, labels, command)
  local argv = command_for(command)
  local result, indices = {}, {}
  if not argv then return result end
  for i, path in ipairs(paths) do
    -- The color-ls protocol is line-based; keep controls out of its output.
    if not path:find("%c") then
      argv[#argv + 1] = path
      indices[#indices + 1] = i
    end
  end
  if #indices == 0 then return result end
  local ok, process = pcall(function()
    return vim.system(argv, { text = true }):wait(1000)
  end)
  if not ok or process.code ~= 0 then return result end
  local lines = vim.split((process.stdout or ""):gsub("\n$", ""), "\n", { plain = true })
  if #lines ~= #indices then return result end
  for line, index in ipairs(indices) do
    result[index] = shorten(lines[line], paths[index], labels[index])
  end
  return result
end

return M
