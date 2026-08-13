local api = vim.api
local ui2 = require("vim._core.ui2")
local config = require("msgarea.config")
local M = {}

M.warn = function(msg)
  local chunks = {
    { "[" }, { "WARN", "DiagnosticWarn" }, { "]" },
    { " (msgarea.nvim): " .. msg, nil },
  }
  api.nvim_echo(chunks, true, {})
end

M.error = function(msg)
  local chunks = {
    { "[" }, { "ERROR", "DiagnosticError" }, { "]" },
    { " (msgarea.nvim): " .. msg, nil },
  }
  api.nvim_echo(chunks, true, {})
end

---@return fun(...): boolean true if throttled, false if went through
M.throttled = function(f, ms)
  ms = ms or config.get().cmdline.resize_throttle_ms
  local last = 0
  return function(...)
    local now = vim.uv.now()
    if now - last >= ms then
      f(...)
      last = now
      return false
    end
    return true
  end
end

M.msg_clear = function() ui2.msg.msg:clear() end
if vim.fn.has("nvim-0.13") == 0 then M.msg_clear = function() ui2.msg.msg_clear() end end

M.cmd_clear = function() ui2.msg.cmd:clear() end
if vim.fn.has("nvim-0.13") == 0 then M.cmd_clear = function() api.nvim_echo({{ "" }}, false, {}) end end

return M
