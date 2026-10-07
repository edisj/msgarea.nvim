local api = vim.api
local ui2 = require("vim._core.ui2")
local M = {
  original = {
    nvim_open_win = vim.api.nvim_open_win,
    nvim_win_set_config = vim.api.nvim_win_set_config,
    show_msg = ui2.msg.show_msg,
    set_pos = ui2.msg.set_pos,
    expand_msg = ui2.msg.expand_msg,
  },
}

M.setup = function(config)
  local view = require("msgarea.view")
  local messages = require("msgarea.messages")

  if not config.enable then
    api.nvim_open_win = M.original.nvim_open_win
    api.nvim_win_set_config = M.original.nvim_win_set_config
    ui2.msg.show_msg = M.original.show_msg
    ui2.msg.set_pos = M.original.set_pos
    ui2.msg.expand_msg = M.original.expand_msg
    return
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  api.nvim_open_win = function(buf, enter, opts)
    if opts.relative == "msgarea" then
      return view.open_win(buf, enter, opts)
    else
      return M.original.nvim_open_win(buf, enter, opts)
    end
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  api.nvim_win_set_config = function(win, win_config)
    if win_config.relative == "msgarea" then
      view.win_set_config(win, win_config)
    else
      M.original.nvim_win_set_config(win, win_config)
    end
  end

  ui2.msg.show_msg = function(...)
    messages.show_msg(...)
  end

  ui2.msg.set_pos = function(...)
    messages.set_pos(...)
  end

  ui2.msg.expand_msg = function(...)
    messages.expand_msg(...)
  end
end

return M
