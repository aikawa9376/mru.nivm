-- Integration test against installed fzf-lua and a real fzf terminal.
vim.opt.rtp:prepend(vim.fn.getcwd())
local dependency = vim.env.MRU_FZF_LUA_PATH or vim.fn.stdpath("data") .. "/lazy/fzf-lua"
assert(vim.fn.isdirectory(dependency) == 1, "Set MRU_FZF_LUA_PATH to an fzf-lua checkout")
vim.opt.rtp:prepend(dependency)
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_RUNTIME_DIR = root
local mru = require("mru")
local fzf = require("fzf-lua")
fzf.setup({
  winopts = { height = 0.8, width = 0.8 }, file_icons = false, git_icons = false,
  fzf_opts = { ["--history"] = root .. "/query-history" },
})
mru.setup({ storage_dir = root .. "/history", ignore = function() return false end })
local target = root .. "/needle:7 with space"
local other = root .. "/another"
local missing = root .. "/needle-missing"
vim.fn.writefile({ "target preview" }, target)
vim.fn.writefile({ "other" }, other)
mru.append(target)
mru.append(other)
mru.append(target, "write")
mru.append(other, "write") -- Identical visible histories must still visibly change mode.
vim.fn.writefile({ "missing" }, missing)
mru.append(missing)
vim.fn.delete(missing)

local function terminal()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buffer].buftype == "terminal" then
      local channel = vim.bo[buffer].channel
      if channel > 0 then
        return buffer, channel
      end
    end
  end
end

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 20), message)
end

local function screen_contains(text)
  local buffer = terminal()
  if not buffer then return false end
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"):find(text, 1, true) ~= nil
end

local function send(bytes)
  local _, channel = terminal()
  assert(channel, "No fzf terminal")
  vim.api.nvim_chan_send(channel, bytes)
  return channel
end

local ok, err = pcall(function()
  require("mru.fzf").open({ scope = "all", project = root, cwd = root })
  wait_for(function() return screen_contains("needle") end, "Initial candidates missing")
  send("\20")
  wait_for(function() return screen_contains("MRW | File / Seen / Saved") end, "Identical-history switch failed")
  send("\20")
  wait_for(function() return screen_contains("MRU | File / Seen / Saved") end, "Identical-history return failed")
  send("needle")
  wait_for(function() return screen_contains("1/2") end, "Path fuzzy filtering failed")
  wait_for(function()
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buffer].buftype == "nofile" then
        local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
        if text:find("target preview", 1, true) then return true end
      end
    end
    return false
  end, "Preview did not decode the decorated row into a file path")
  send("\20") -- ctrl-t: switch MRU -> MRW, preserving query
  wait_for(function() return screen_contains("MRW / all") end, "MRW switch failed")
  local opts = require("fzf-lua.config").__resume_data.opts
  assert(opts.query == "needle", "Kind switch lost query")
  send("\7") -- ctrl-g: all -> cwd
  wait_for(function() return screen_contains("MRW / cwd") end, "Scope switch failed")
  opts = require("fzf-lua.config").__resume_data.opts
  assert(opts.query == "needle", "Scope switch lost query")
  send("\27d") -- alt-d: all -> hour; ctrl-p remains available for navigation
  wait_for(function() return screen_contains("MRW / cwd / hour") end, "Period switch failed")
  opts = require("fzf-lua.config").__resume_data.opts
  assert(opts.query == "needle", "Period switch lost query")
  send("\24") -- ctrl-x: forget history, keep file and picker query
  wait_for(function() return #mru.list("write") == 1 and screen_contains("0/1") end, "History deletion failed")
  assert(vim.fn.filereadable(target) == 1, "History deletion removed the file")
  send("\20") -- ctrl-t: return to MRU even when the filtered MRW list is empty
  wait_for(function() return screen_contains("MRU / cwd / hour") end, "Return to MRU failed")
  send("\8") -- ctrl-h: include missing files without forgetting them
  wait_for(function() return screen_contains("[missing]") end, "Missing toggle failed")
  local previous = send("\8")
  wait_for(function()
    local _, channel = terminal()
    return channel and channel ~= previous and screen_contains("1/2") and not screen_contains("[missing]")
  end, "Missing files were not hidden again")
  send("\r")
  wait_for(function() return vim.api.nvim_buf_get_name(0) == target end, "Opening decorated filename failed")
end)
if not ok then
  local buffer = terminal()
  if buffer then
    io.stderr:write(table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n") .. "\n")
  end
end
vim.api.nvim_del_augroup_by_name("mru.nvim")
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
print("Real fzf-lua integration passed: query, scope, period, deletion and open")
