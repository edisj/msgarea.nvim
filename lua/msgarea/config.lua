---@type Msgarea.Config
local default_config = {
  -- Whether to enable the plugin. Can be disabled at runtime
  -- with `require("msgarea").config({ enabled = false })`
  enabled = true,

  -- List of message `kind`s that should be sent to the msgarea
  -- NOTE: equivalent to setting <kind> = "msgarea" in ui2.cfg.msg.targets
  -- Valid message kinds:
  --   - "lua_print"
  --   - "lua_error"
  --   - "list_cmd"
  --   - ...
  -- (see :h ui-messages for all valid kinds)
  msgarea_targets = {},

  -- Title for persistent messages in message area
  -- These messages are routed through `<target> = "msgarea"` in ui2 config.
  -- Can either be:
  --   string   - A static title to use for all messages.
  --   function - A callable that receives parameter `kind` (:h ui-messages)
  --              and returns a string or `nil`.
  --              If return is `nil`, message is treated as ephemeral.
  -- For example, to treat `lua_print` and `lua_error` kinds as persistent
  -- and everything else as ephemeral:
  --   function(kind)
  --     local titles = { lua_print = " Lua Print ", lua_error = " Lua Error " }
  --     return titles[kind]
  --   end
  messages_title = " Messages ",

  -- View options
  view = {
    -- Determines whether to place the view below statusline
    -- or as a regular split.
    -- Valid styles are:
    --   msgarea - Open below statusline in the message area.
    --   split   - Open as a regular "below" split.
    style = "msgarea",
    -- While in cmdline, the view is shifted to this position.
    style_while_in_cmdline = "split",
    -- While an ephemeral window is open, view is shifted to this position.
    style_while_in_ephemeral_win = "split",

    -- Min and max height of the view, if fraction between 0-1,
    -- it is % of editor size, otherwise absolute size
    min_height = 1,
    max_height = 0.3,

    -- Determines position of tabs in winbar.
    -- Analagous to `title_pos` in win config (:h nvim_open_win())
    -- Valid positions are: "left" | "center" | "right"
    winbar_pos = "left",

    -- Optional separator between tabs in winbar.
    winbar_separator = "",

    -- Minimum number of msgarea windows needed to show tabs.
    -- e.g. if 2, then tab is hidden when only a single window is open.
    winbar_min_tabs = 1,
  },

  -- Cmdline completion options
  cmdline = {
    -- Whether to enable cmdline completion behaviors.
    -- If using an external cmdline like `tiny-cmdline.nvim`,
    -- you probably want to disable this.
    enabled = false,

    -- Which completion plugin you use.
    -- Currently only `blink.cmp` is supported... working on native
    -- Valid providers:
    --   "blink.cmp"
    cmp_provider = "blink.cmp",

    -- Whether to dynamically resize cmdheight as completion window changes height.
    -- If `false`, the height is set to `vim.o.pumheight`, otherwise
    -- `vim.o.pumheight` is used as the max height.
    dynamic_height = true,

    -- Debounce in ms for resizing the cmdheight. If set to 0, typing quickly
    -- will cause the the cmdheight to bounce rapidly.
    -- If `dynamic_height = false` then this has no effect.
    resize_throttle_ms = 200,

    -- Whether to add description text to cmdline completions.
    -- For ex-cmds, parsed directly from `index.txt` (:h ex-cmds-index),
    -- for usercmds, obtained from `vim.api.nvim_get_commands({})`.
    -- Notes:
    --   - If you find some usercmds are missing descriptions, they may have
    --     been lazy loaded after cache was populated.
    --     Call `require("msgarea.cache").refresh()` to repopulate cache at any time.
    --   - If using `blink.cmp` and you are not seeing descriptions, make sure in
    --     your bilnk config, `cmdline.completion.menu.draw.columns` includes "label_description".
    --   - Subject to change depending on https://github.com/neovim/neovim/pull/39672
    descriptions = true,
  },
}

---@type Msgarea.Config
local _config

local M = {}

---Return merged config if setup was called, otherwise default config
---@return Msgarea.Config
M.get = function()
  return _config or default_config
end

local is_integer = function(value)
  return type(value) == "number"
    and value == math.floor(value)
    and value ~= math.huge
    and value ~= -math.huge
end

---Validate user config options.
---@return string? nil on success, error message on fail
local validate = function(field, value, expected)
  if (expected == "integer" and is_integer(value)) or type(value) == expected then
    return
  end
  if type(expected) == "table" then
    if vim.tbl_contains(expected, value) or vim.tbl_contains(expected, type(value)) then
      return
    else
      local valid_fields = "{ " .. table.concat(expected, ", ") .. " }"
      return "invalid config field `" .. field .. "`, expected one of: " .. valid_fields .. "."
    end
  end
  return "invalid config field `" .. field .. "`, expected " .. expected .. "."
end

---Validates user config and merges with default config.
---Returns true and merged config on success
---or false and list of error messages on fail.
---
---@param user_config Msgarea.UserConfig
---@return boolean
---@return Msgarea.Config|string[]
M.setup = function(user_config)
  local config = vim.tbl_deep_extend("force", _config or default_config, user_config)

  local errors = {}

  errors[#errors + 1] = validate("enabled", config.enabled, "boolean")
  errors[#errors + 1] = validate("msgarea_targets", config.msgarea_targets, "table")
  errors[#errors + 1] = validate("messages_title", config.messages_title, { "string", "function" })

  local VALID_STYLES = { "msgarea", "split" }
  for field, expected in pairs {
    style = VALID_STYLES,
    style_while_in_cmdline = VALID_STYLES,
    style_while_in_ephemeral_win = VALID_STYLES,
    min_height = "number",
    max_height = "number",
    winbar_pos = { "left", "center", "right" },
    winbar_min_tabs = "integer",
  } do
    errors[#errors + 1] = validate("view." .. field, config.view[field], expected)
  end

  for field, expected in pairs {
    enabled = "boolean",
    -- cmp_provider = { "native", "blink.cmp" }, TODO: native
    cmp_provider = { "blink.cmp" },
    descriptions = "boolean",
    dynamic_height = "boolean",
    resize_throttle_ms = "number",
  } do
    errors[#errors + 1] = validate("cmdline." .. field, config.cmdline[field], expected)
  end

  if #errors == 0 then
    _config = config
    return true, _config
  else
    return false, errors
  end
end

---@class (exact) Msgarea.UserConfig : Msgarea.Config
---@field enabled? boolean
---@field messages_title? string|fun(kind?: string):string
---@field view? Msgarea.Config.ViewPartial
---@field cmdline? Msgarea.Config.CmdlinePartial
---@field msgarea_targets? string[]

---@class (exact) Msgarea.Config.ViewPartial : Msgarea.Config.View
---@field style? "msgarea"|"split"
---@field style_while_in_cmdline? "msgarea"|"split"
---@field style_while_in_ephemeral_win? "msgarea"|"split"
---@field max_height? number
---@field min_height? number
---@field winbar_pos? "left"|"center"|"right"
---@field winbar_separator? string
---@field winbar_min_tabs? integer

---@class (exact) Msgarea.Config.CmdlinePartial : Msgarea.Config.Cmdline
---@field enabled? boolean
---@field cmp_provider? "native"|"blink.cmp"
---@field descriptions? boolean
---@field dynamic_height? boolean
---@field resize_throttle_ms? number

---@class (exact) Msgarea.Config
---@field enabled boolean
---@field messages_title string|fun(kind?:string):string
---@field msgarea_targets string[]
---@field view Msgarea.Config.View
---@field cmdline Msgarea.Config.Cmdline

---@class (exact) Msgarea.Config.View
---@field style "msgarea"|"split"
---@field style_while_in_cmdline "msgarea"|"split"
---@field style_while_in_ephemeral_win "msgarea"|"split"
---@field max_height number
---@field min_height number
---@field winbar_pos "left"|"center"|"right"
---@field winbar_separator string
---@field winbar_min_tabs integer

---@class (exact) Msgarea.Config.Cmdline
---@field enabled boolean
---@field cmp_provider "native"|"blink.cmp"
---@field descriptions boolean
---@field dynamic_height boolean
---@field resize_throttle_ms number

return M
