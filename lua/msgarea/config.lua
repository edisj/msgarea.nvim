---@type msgarea.Config
local default_config = {
  -- Whether to enable the plugin. Can be disabled at runtime
  -- with `require("msgarea").config({ enable = false })`
  enable = true,

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
  -- These messages are routed through `<kind> = "msgarea"` in ui2 config.
  -- Can either be:
  --   string   - A static title to use for all messages.
  --   function - A callable that receives parameter `kind` (:h ui-messages)
  --              and returns a string or `nil`.
  --              If return is `nil`, message is treated as ephemeral.
  -- Examples:
  --   - to treat `lua_print` and `lua_error` kinds as persistent
  --     and everything else as ephemeral:
  --       message_title = function(kind)
  --         local titles = { lua_print = " Lua Print ", lua_error = " Lua Error " }
  --         return titles[kind]
  --       end
  --   - to make every message persistent with a static title:
  --       message_title = " Messages "
  message_title = function(kind) end,

  -- View options
  view = {
    -- Determines whether to place the view below statusline
    -- or as a regular split.
    -- Valid styles are:
    --   msgarea - Open below statusline in the message area.
    --   split   - Open as a regular "below" split.
    style = "msgarea",

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
    enable = false,

    -- Which completion plugin you use.
    -- Valid providers:
    --   "native"       - builtin cmdline completions
    --   "mini.cmdline" - https://github.com/nvim-mini/mini.cmdline
    --   "blink.cmp"    - https://github.com/saghen/blink.cmp
    cmp_provider = "native",

    -- Whether to dynamically resize cmdheight as completion window changes height.
    -- If `false`, the height is set to `vim.o.pumheight`, otherwise
    -- `vim.o.pumheight` is used as the max height.
    dynamic_height = false,

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

---@type msgarea.Config
local _config

local M = {}

---Return merged config if setup was called, otherwise default config
---@return msgarea.Config
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
---@param user_config msgarea.UserConfig
---@return boolean
---@return msgarea.Config|string[]
M.setup = function(user_config)
  local config = vim.tbl_deep_extend("force", _config or default_config, user_config)

  local errors = {}

  errors[#errors + 1] = validate("enable", config.enable, "boolean")
  errors[#errors + 1] = validate("msgarea_targets", config.msgarea_targets, "table")
  errors[#errors + 1] = validate("message_title", config.message_title, { "string", "function" })

  for field, expected in pairs {
    style = { "msgarea", "split" },
    min_height = "number",
    max_height = "number",
    winbar_pos = { "left", "center", "right" },
    winbar_min_tabs = "integer",
  } do
    errors[#errors + 1] = validate("view." .. field, config.view[field], expected)
  end

  for field, expected in pairs {
    enable = "boolean",
    cmp_provider = { "native", "mini.cmdline", "blink.cmp" },
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

---@class (exact) msgarea.UserConfig : msgarea.Config
---@field enable? boolean
---@field msgarea_targets? string[]
---@field message_title? string|fun(kind?: string):string|nil
---@field view? msgarea.config.ViewPartial
---@field cmdline? msgarea.config.CmdlinePartial

---@class (exact) msgarea.config.ViewPartial : msgarea.config.View
---@field style? "msgarea"|"split"
---@field max_height? number
---@field min_height? number
---@field winbar_pos? "left"|"center"|"right"
---@field winbar_separator? string
---@field winbar_min_tabs? integer

---@class (exact) msgarea.config.CmdlinePartial : msgarea.config.Cmdline
---@field enable? boolean
---@field cmp_provider? "native"|"blink.cmp"|"mini.cmdline"
---@field dynamic_height? boolean
---@field resize_throttle_ms? number
---@field descriptions? boolean

---@class (exact) msgarea.Config
---@field enable boolean
---@field msgarea_targets string[]
---@field message_title string|fun(kind?:string):string|nil
---@field view msgarea.config.View
---@field cmdline msgarea.config.Cmdline

---@class (exact) msgarea.config.View
---@field style "msgarea"|"split"
---@field max_height number
---@field min_height number
---@field winbar_pos "left"|"center"|"right"
---@field winbar_separator string
---@field winbar_min_tabs integer

---@class (exact) msgarea.config.Cmdline
---@field enable boolean
---@field cmp_provider "native"|"blink.cmp"|"mini.cmdline"
---@field dynamic_height boolean
---@field resize_throttle_ms number
---@field descriptions boolean

return M
