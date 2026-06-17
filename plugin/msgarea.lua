local loaded
if loaded then return end
loaded = true

vim.g.msgarea_enabled = true
local ui2 = require("vim._core.ui2")

local _nvim_open_win = vim.api.nvim_open_win
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_open_win = function(buf, enter, opts)
  if not vim.g.msgarea_enabled or opts.relative ~= "msgarea" then
    return _nvim_open_win(buf, enter, opts)
  else
    return require("msgarea").open_win(_nvim_open_win, buf, enter, opts)
  end
end

local _msg_show = ui2.msg.msg_show
ui2.msg.msg_show = function(...)
  if not vim.g.msgarea_enabled then
    _msg_show(...)
  else
    require("msgarea.messages").msg_show(_msg_show, ...)
  end
end

local group = vim.api.nvim_create_augroup("msgarea-autocmds", { clear = true })
local on = function(event, pattern, desc, cb)
  vim.api.nvim_create_autocmd(event, {
    group = group,
    pattern = pattern,
    desc = "[msgarea.nvim] " .. desc,
    callback = function(...)
      if not vim.g.msgarea_enabled then return end
      cb(...)
    end,
  })
end

on("CmdlineEnter", "*", "hide msgarea windows when entering cmdline", function()
  require("msgarea").hide()
end)

local reset_msgarea = function()
  vim._with({ o = { splitkeep = "screen" } }, function()
    require("msgarea").show({ silent = true })
  end)
end

local in_dialog = function()
  return ui2.cmd.prompt
end

on("CmdlineLeave", "*", "reset msgarea view when leaving cmdline", function()
  -- NOTE: this needs to be scheduled
  vim.schedule(function()
    -- NOTE: the idea here is that we need to check if we exited cmdline directly into
    -- confirm/dialog window, for example if calling :restart while there are unsaved changes.
    -- Current solution is to start a timer and check if still in dialog every `DEBOUNCE`
    -- seconds, only resetting msgarea view when no longer in dialog
    if in_dialog() then
      local DEBOUNCE = 500 -- ms
      local timer = assert(vim.uv.new_timer())
      timer:start(DEBOUNCE, DEBOUNCE, function()
        if in_dialog() then
          -- vim.print("STILL IN DIALOG")
          return
        end
        -- vim.print("EXITED DIALOG")
        if not timer:is_closing() then timer:close() end
        vim.schedule(reset_msgarea)
      end)
    else
      reset_msgarea()
    end
  end)
end)

on("OptionSet", "cmdheight", "refresh height of active windows on cmdheight change", function()
  if vim.fn.mode() == "c" then return end
  local wins = require("msgarea").state.active_windows
  local h = vim.v.option_new
  for _, win in ipairs(wins) do
    h = h - win.border_height
    vim.api.nvim_win_set_height(win.winid, h)
  end
end)

-- NOTE: this occurs if, for example, you press a keymap to focus a msgarea window
-- and it's not the currently focused window in require("msgarea").state.focused
on("WinEnter", "*", "ensure msgarea window is brought to front when focused", function(ev)
  local msgarea = require("msgarea")
  local winid
  for _, win in ipairs(msgarea.state.active_windows) do
    if win.bufnr == ev.buf then
      winid = win.winid
      break
    end
  end
  if
    winid == nil
    or vim.api.nvim_get_current_win() ~= winid
    or msgarea.state.focused == winid
  then
    return
  end
  msgarea.state.focused = winid
  msgarea.show({ silent = true })
end)
