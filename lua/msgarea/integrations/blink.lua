local api, fn = vim.api, vim.fn
local config = require("msgarea.config")
local cache = require("msgarea.cache")
local view = require("msgarea.view")
local util = require("msgarea.util")

local menu, _update_position

local WINHL = table.concat({
  "NormalFloat:MsgArea",
  "BlinkCmpMenu:MsgAreaCmpMenu",
  "BlinkCmpLabel:MsgAreaCmpLabel",
  "BlinkCmpLabelDescription:MsgAreaCmpLabelDescription",
  "Search:",
}, ",")

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
local update_throttled = util.throttled(function()
  local n = #require("blink.cmp").get_items()
  local height = config.get().cmdline.dynamic_height and math.min(n + 1, vim.o.pumheight) or vim.o.pumheight
  _cached_win_config = { relative = "msgarea", height = math.max(1, height - 1) }
  menu.win:set_win_config(_cached_win_config)
end)

local update_position = function()
  if not (menu.context and menu.win:is_open()) then return end
  if fn.mode() ~= "c" then _update_position(); return end
  if update_throttled() then menu.win:set_win_config(_cached_win_config) end
end

local id
local _saved_blink_config = {}
local setup_autocmds = function()
  id = api.nvim_create_augroup("msgarea-blinkcmp-autocmds", { clear = true })
  local on = function(event, pattern, desc, cb)
    api.nvim_create_autocmd(event, {
      group = id,
      pattern = pattern,
      desc = "(msgarea.nvim) " .. desc,
      callback = cb,
    })
  end

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
  on({ "CmdlineEnter", "CmdlineLeave" }, { ":", "\\/", "\\?" }, "update blink.cmp menu config in cmdline", function(ev)
    if ev.event == "CmdlineEnter" then
      set_blink_menu_config({ winhighlight = WINHL })
    elseif ev.event == "CmdlineLeave" then
      view.close_ephemeral()
      set_blink_menu_config(_saved_blink_config)
      -- NOTE: this fixes a bug when <C-c> out of cmdline, for some reason the scrollbar sticks around
      local sb = menu.win.scrollbar
      if sb:is_visible() then sb.win:hide() end
    end
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

M.transform_items = function(_, items)
  local include_desc = fn.getcmdcompltype() == "command"
  if not include_desc then return items end
  return vim
    .iter(ipairs(items))
    :map(function(_, item)
      item.labelDetails = item.labelDetails or {}
      item.labelDetails.description = cache.excmds[item.label] or cache.usercmds[item.label] or ""
      return item
    end)
    :totable()
end

M.enable = function()
  if menu == nil then
    menu = require("blink.cmp.completion.windows.menu")
    _update_position = menu.update_position
  end
  menu.update_position = update_position
  setup_autocmds()
  if not config.get().cmdline.descriptions then return end
  local p = require("blink.cmp.sources.lib").get_provider_by_id("cmdline")
  p.config.transform_items = M.transform_items
  cache.refresh()
end

M.disable = function()
  menu.update_position = _update_position
  pcall(api.nvim_del_augroup_by_id, id)
end

return M
