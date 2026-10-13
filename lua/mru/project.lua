local uv = vim.uv or vim.loop
local M = {}

function M.resolve(start, config, normalize)
  if type(config.project_root) == "string" then
    return normalize(config.project_root)
  end
  start = normalize(start)
  if type(config.project_root) == "function" then
    local root = config.project_root(start)
    if root then
      assert(type(root) == "string", "mru: project_root resolver must return a path or nil")
      return normalize(root)
    end
  end
  local directory = start
  if vim.fn.isdirectory(directory) == 0 then
    directory = vim.fn.fnamemodify(directory, ":h")
  end
  while directory and directory ~= "" do
    for _, marker in ipairs(config.root_markers) do
      if uv.fs_stat(directory .. "/" .. marker) then
        return normalize(directory)
      end
    end
    local parent = normalize(vim.fn.fnamemodify(directory, ":h"))
    if parent == directory then
      break
    end
    directory = parent
  end
  return normalize(vim.fn.getcwd())
end

return M
