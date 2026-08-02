local api = vim.api
local fn = vim.fn
local ui2 = require("vim._core.ui2")
local view = require("msgarea.view")
local config = require("msgarea.config")
local cache = require("msgarea.cache")
local menu = require("blink.cmp.completion.windows.menu")

local _last = 0
local throttled = function(f)
  local delay = config.get().cmdline.resize_throttle_ms
  return function(...)
    local now = vim.uv.now()
    if now - _last >= delay then
      f(...)
      _last = now
      return false
    end
    return true
  end
end

local _cached_win_config = {}
local update_win_config = function()
  local cmd_win = ui2.wins.cmd
  local n = #require("blink.cmp").get_items()
  local height = config.get().cmdline.dynamic_height and math.min(n + 1, view.max_height()) or vim.o.pumheight
  vim.o.cmdheight = height
  _cached_win_config = {
    relative = "win",
    anchor = "SW",
    win = cmd_win,
    border = "none",
    height = math.max(1, height - 1),
    width = api.nvim_win_get_width(cmd_win),
    row = vim.o.cmdheight,
    col = 0,
    zindex = api.nvim_win_get_config(cmd_win).zindex + 1,
  }
  menu.win:set_win_config(_cached_win_config)
end

local _update_position = menu.update_position
local update_position = function()
  if menu.context == nil or not menu.win:is_open() then return end
  if fn.mode() ~= "c" then _update_position(); return end
  if throttled(update_win_config)() then
    menu.win:set_win_config(_cached_win_config)
  end
end

local _augroup_name = "msgarea-blink-autocmds"
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

  local group = api.nvim_create_augroup(_augroup_name, { clear = true })
  local on = function(event, pattern, desc, cb)
    api.nvim_create_autocmd(event, {
      group = group,
      pattern = pattern,
      desc = "(msgarea.nvim) " .. desc,
      callback = function(...)
        cb(...)
      end,
    })
  end

  on("CmdlineEnter", "*", "update blink.cmp menu config while in cmdline", function()
    local winhl = table.concat({
      "NormalFloat:MsgArea",
      "BlinkCmpMenu:MsgAreaCmpMenu",
      "BlinkCmpLabel:MsgAreaCmpLabel",
      "BlinkCmpLabelDescription:MsgAreaCmpLabelDescription",
      "Search:",
    }, ",")
    local min_width = api.nvim_win_get_width(ui2.wins.cmd)
    set_blink_menu_config({ min_width = min_width, winhighlight = winhl })
  end)

  on("CmdlineLeave", "*", "reset blink.cmp menu config when exiting cmdline", function()
    set_blink_menu_config(_saved_blink_config)
  end)

  local collapse_cmdheight = vim.schedule_wrap(function()
    if fn.mode() ~= "c" or not config.get().cmdline.dynamic_height then
      return
    end
    -- FIXME: need a better solution here
    local reset = function()
      vim.o.cmdheight = 1
      api.nvim__redraw({ flush = true })
      _last = 0
    end
    (fn.getcmdline() == "" and reset or throttled(reset))()
  end)
  on("User", "BlinkCmpMenuClose", "reset cmdheight when cmdline is empty", collapse_cmdheight)
end

local M = {}

M.transform_items = function(ctx, items)
  -- HACK: some labels will incorrectly match descriptions, for example
  -- "lsp stop" will match the "stop" label for ":stop" command
  -- which is incorrect. Here I just check if there are any
  -- whitespaces before the cursor and don't match on those occurances
  local text_before_cursor = ctx.line:sub(1, ctx.cursor[2])
  if text_before_cursor:find("%s") then return items end

  return vim
    .iter(ipairs(items))
    :map(function(_, item)
      item.labelDetails = item.labelDetails or {}
      item.labelDetails.description =
        cache.excmds[item.label]
        or cache.usercmds[item.label]
        or ""
      return item
    end)
    :totable()
end

M.enable = function()
  menu.update_position = update_position
  setup_autocmds()
  if not config.get().cmdline.descriptions then return end
  local p = require("blink.cmp.sources.lib").get_provider_by_id("cmdline")
  p.config.transform_items = M.transform_items
  cache.refresh()
end

M.disable = function()
  menu.update_position = _update_position
  pcall(api.nvim_del_augroup_by_name,_augroup_name)
end

return M
