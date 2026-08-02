local api = vim.api
local _nvim_open_win = api.nvim_open_win
local _nvim_win_set_config = api.nvim_win_set_config

local ui2 = require("vim._core.ui2")
local _msg_show = ui2.msg.msg_show
local _set_pos = ui2.msg.set_pos
local _expand_msg = ui2.msg.expand_msg

local M = {}

M.setup = function(config)
  local view = require("msgarea.view")
  local messages = require("msgarea.messages")

  if not config.enabled then
    api.nvim_open_win = _nvim_open_win
    api.nvim_win_set_config = _nvim_win_set_config
    ui2.msg.msg_show = _msg_show
    ui2.msg.set_pos = _set_pos
    ui2.msg.expand_msg = _expand_msg
    return
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  api.nvim_open_win = function(buf, enter, opts)
    if opts.relative == "msgarea" then
      return view.open_win(_nvim_open_win, buf, enter, opts)
    else
      return _nvim_open_win(buf, enter, opts)
    end
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  api.nvim_win_set_config = function(win, win_config)
    if win_config.relative == "msgarea" then
      view.win_set_config(_nvim_win_set_config, win, win_config)
    else
      _nvim_win_set_config(win, win_config)
    end
  end

  ui2.msg.msg_show = function(...)
    messages.msg_show(_msg_show, ...)
  end

  ui2.msg.set_pos = function(...)
    messages.set_pos(_set_pos, ...)
  end

  ui2.msg.expand_msg = function(...)
    messages.expand_msg(_expand_msg, ...)
  end
end

return M
