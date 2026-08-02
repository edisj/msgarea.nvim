local api = vim.api
local fn = vim.fn
local ui2 = require("vim._core.ui2")
local M = {}

local _augroup_name = "msgarea-nativecmp-autocmds"
local setup_autocmds = function()
  local group = api.nvim_create_augroup(_augroup_name, { clear = true })
  local on = function(event, pattern, desc, cb)
    api.nvim_create_autocmd(event, {
      group = group,
      pattern = pattern,
      desc = desc,
      callback = cb,
    })
  end

  local _pumheight = vim.o.pumheight
  local _pumwidth = vim.o.pumwidth
  local _pummaxwidth = vim.o.pummaxwidth
  -- on("CmdlineEnter", "*", "", function(ev)
  --   local width = api.nvim_win_get_width(ui2.wins.cmd)
  --   vim.o.pumwidth = width
  --   vim.o.pummaxwidth = width
  -- end)
  -- on("CmdlineLeave", "*", "", function()
  --   vim.o.pumwidth = _pumwidth
  --   vim.o.pummaxwidth = _pummaxwidth
  -- end)

  -- on("CmdlineChanged", { ":", "/", "?" }, "", function()
  --   fn.wildtrigger()
  --   vim.schedule(function()
  --     local ok, items = pcall(fn.getcompletion, fn.getcmdcomplpat(), fn.getcmdcompltype())
  --     local n = ok and #items or 0
  --     local cap = vim.o.pumheight > 0 and vim.o.pumheight or math.huge
  --     local h = math.min(n, cap)
  --     vim.o.cmdheight = (h > 0 and h or 0) + 1
  --     vim.cmd.redraw()
  --   end)
  -- end)

end

M.enable = function()
  setup_autocmds()
end

M.disable = function()
  api.nvim_del_augroup_by_name(_augroup_name)
end

return M
