local api = vim.api
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

return M
