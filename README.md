# msgarea.nvim

Extends Neovim's [ui2 system](https://neovim.io/doc/user/lua/#ui2) with a new target: `msgarea`.

This lets you:
<table>
  <tr>
    <td align="center">
      <img width="1891" height="1161" alt="msgarea_cmdline" src="https://github.com/user-attachments/assets/a01e2b83-a493-4732-a03b-23c6e9cece56" />
      <sub>Open cmdline completions in a <a href="https://github.com/minad/vertico">vertico</a> + <a href="https://github.com/minad/marginalia">marginalia</a> style layout.
      (currently only <code>blink.cmp</code> is supported, working on native completions...)</sub>
    </td>
    <td align="center">
      <img width="1891" height="1153" alt="msgarea_picker" src="https://github.com/user-attachments/assets/524136fb-6f23-4970-81fe-425eb066ebfc" />
      <sub>Open arbitrary ephemeral windows (like your favorite picker) in the <code>msgarea</code> view. (<code>mini.pick</code> is shown here)</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img width="1897" height="1152" alt="msgarea_error" src="https://github.com/user-attachments/assets/65a2dd7c-3b8d-45e3-b174-45bfcc39b4d3" />
      <sub>Route ui-messages to the <code>msgarea</code> view either as ephemeral or persistent windows.</sub>
    </td>
    <td align="center">
      <img width="1896" height="1152" alt="msgarea_tabs" src="https://github.com/user-attachments/assets/dc25269d-d3cc-47e8-a5e6-8f43388ea166" />
      <sub>Open as many persistent <code>msgarea</code> windows as you like in an organized, tabbed view.</sub>
    </td>
  </tr>
</table>

and more...

## Features
  - Route `ui-messages` to the msgarea as ephemeral or persistent windows.
    See `:h msgarea-ephemeral` for distinction between ephemeral vs persistent.
  - Open persistent or ephemeral windows in the msgarea with the native
    `nvim_open_win()` api. This plugin patches `nvim_open_win` and
    `nvim_win_set_config` to accept a new option, `relative = "msgarea"`.
  - Integrate with any plugin that exposes `win_config` options
    somewhere in the plugin config. See `:h msgarea-integrating-with-plugins` for details.

## Dependencies
- Neovim >= 0.12

## Installation

> [!WARNING]
> This is an experimental plugin built on top of the _already_ experimental `ui2`.
> As this plugin monkey-patches several `ui2` functions and aims to follow the development of `ui2` closely, any upstream
> breaking changes may introduce breaking changes here.

<details>
<summary>vim.pack (recommended)</summary>

```lua
vim.pack.add({
  "https://github.com/edisj/msgarea.nvim",
})
```
</details>

<details>
<summary>lazy.nvim</summary>

```lua
{
  "edisj/msgarea.nvim",
  opts = {},
}
```

</details>

## Quick start
Make sure `ui2` is enabled
```lua
-- highly recommended to set the default target to "msg", otherwise "cmd" messages will be covered by msgarea windows
require("vim._core.ui2").enable({ msg = { targets = { default = "msg" } } })
```

Add the following to your init.lua or somewhere in your config
```lua
-- *highly* recommended to use one of these settings,
-- otherwise screen lines bounce around a lot when the view is opened/closed
-- vim.o.splitkeep = "topline"
-- vim.o.splitkeep = "screen"

-- pass no argument or `{}` to use default config
require("msgarea").setup()
```

You may want to set a keymap to close the msgarea
```lua
vim.keymap.set("n", "<C-w>m", function()
  require("msgarea").close_all()
end, { desc = "close msgarea" })
```

## Options

```lua
require("msgarea").setup({
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
})
```

## Usage overview

The [Neovim 0.12 ui2 system](https://neovim.io/doc/user/lua/#ui2) introduced a new way for routing messages to different "views" as targets (e.g. "cmd", "pager", "msg").
While it's fantastic and eliminated the annoying "press enter" blocking messages, some messages are a bit _too_ ephermal.
Routing to `msg` only shows the message for a few seconds and requires you to click on the message window with your mouse to keep it alive.
Routing to `cmd` shows the message in a convenient bottom view, but is immediately removed on cursor move.
Of course, you can always press `g<` to refocus the last message in the `pager`, but in some cases, I find myself having to reopen and close the last message several times to reread because it doesn't stick around when exiting (for example when reading a lua error and then going to the line referred to in stack trace).

The solution presented here is a new view (`msgarea`) that is sits somewhere in between `pager` and `cmd` in terms of function.
Setting a message target to `msgarea` will now open a "Messages" window below the statusline and automatically handle setting/resetting `cmdheight` when message content is emitted to the handler.
Focusing the `pager` with e.g. `g<` still closes the "Messages" window, so that behavior is the same.

When I say `msgarea`, I mean the view or region of the screen below the statusline, where the "Messages" window is just one window that can be opened in the view.
Here, _any_ arbitrary window can be opened in the `msgarea` (see [Usage](#usage) and [Examples](#examples)), where the winbar provides clickable tabs to see which windows are active.

## Recipes
- [Open a terminal window in the msgarea](doc/recipes.md#open-a-terminal-window-in-the-msgarea)
- [Open quickfix/loclist in the msgarea](doc/recipes.md#open-quickfix/loclist-in-the-msgarea)
- [Open a picker in the msgarea](doc/recipes.md#open-a-picker-in-the-msgarea)
- [Emulating Emacs `M-x find-file` with 'mini.pick'](doc/recipes.md#emulating-emacs-m-x-find-file-with-minipick)

## API

### `require("msgarea").close_all()`

Close all active msgarea windows.

### `require("msgarea").show(opts)`

Show or refresh the msgarea view.

- `opts` (`table?`)
  - `silent?` (`boolean`) — supress warning message (default: `false`)
  - TODO


### `require("msgarea").hide(opts)`

Hide, but do not close, all msgarea windows.
Subsequent `require("msgarea").show()` will restore saved view state.

- `opts` (`table?`)
  - `cmdheight?` (`integer`) — set cmdheight to this after hiding (default: `nil`)

