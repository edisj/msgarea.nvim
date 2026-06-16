local api = vim.api
local fn = vim.fn
local ui2 = require("vim._core.ui2")
local msgarea = require("msgarea")
local menu = require("blink.cmp.completion.windows.menu")

local redraw_cmdheight = function(height)
  vim._with({ o = { splitkeep = "screen" } }, function()
    vim.o.cmdheight = height
    vim.cmd.redraw()
  end)
end

local _update_position = menu.update_position
local update_position = function()
  if menu.context == nil or not menu.win:is_open() then return end

  if fn.mode() ~= "c" then
    _update_position()
    return
  end

  local cmd_win = ui2.wins.cmd
  local height = vim.o.pumheight
  height = math.max(height, msgarea.height())
  redraw_cmdheight(height)
  menu.win:set_win_config({
    relative = "win",
    anchor = "SW",
    win = cmd_win,
    border = "none",
    height = math.max(1, height - 1), -- -1 to add room for cmdline
    width = api.nvim_win_get_width(cmd_win),
    row = vim.o.cmdheight,
    col = 0,
    zindex = api.nvim_win_get_config(cmd_win).zindex + 1,
  })
end

local _saved_blink_config = {}
local setup_autocmds = function()

  local set_blink_menu_config = function(opts)
    -- NOTE: for whatever reason both fields in the regular
    -- blink config and the completion.windows.menu config
    -- need to be set for this to work
    local menu_config_1 = require("blink.cmp.config").completion.menu
    local menu_config_2 = require("blink.cmp.completion.windows.menu").win.config
    for k, v in pairs(opts) do
      -- NOTE: false because nil will remove from table
      _saved_blink_config[k] =
        (_saved_blink_config[k] and _saved_blink_config[k])
        or (menu_config_1[k] and menu_config_1[k])
        or false
      menu_config_1[k] = v
      menu_config_2[k] = v
    end
  end

  local group = api.nvim_create_augroup("msgarea-blink-autocmds", { clear = true })
  local on = function(event, pattern, desc, cb)
    api.nvim_create_autocmd(event, {
      group = group,
      pattern = pattern,
      desc = "[msgarea.nvim] " .. desc,
      callback = function(...)
        cb(...)
      end,
    })
  end

  on("CmdlineEnter", "*", "update blink.cmp menu config while in cmdline", function()
    local winhl = table.concat({
      "NormalFloat:MsgArea",
      "Normal:MsgArea",
      "BlinkCmpMenu:MsgArea",
      "BlinkCmpLabelDescription:Comment",
      "BlinkCmpLabelDetail:Comment",
      -- "BlinkCmpSelection:CursorLine",
      -- "CursorLine:CursorLine",
      "Search:None",
    }, ",")
    local min_width = api.nvim_win_get_width(ui2.wins.cmd)
    set_blink_menu_config({ min_width = min_width, winhighlight = winhl })
  end)

  on("CmdlineLeave", "*", "reset blink.cmp menu config when exiting cmdline", function()
    set_blink_menu_config(_saved_blink_config)
  end)

  on("User", "BlinkCmpMenuClose", "reset cmdheight when cmdline is empty", function()
    -- NOTE: seems to need to be scheduled for whatever reason
    vim.schedule(function()
      -- only want to collapse cmdheight WHILE typing in cmdline
      if not (fn.mode() == "c" and fn.getcmdline() == "") then
        return
      end
      local height = #msgarea.state.active_windows == 0 and 1 or msgarea.height()
      redraw_cmdheight(height)
    end)
  end)
end

local M = {}

M.enable = function()
  menu.update_position = update_position
  setup_autocmds()
end

M.disable = function()
  menu.update_position = _update_position
  api.nvim_del_augroup_by_name("msgarea-blink-autocmds")
end

return M
