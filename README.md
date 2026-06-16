# msgarea.nvim

An experimental proof-of-concept for a "msgarea" view similar to "minibuffer" in emacs (although I've never used emacs, so this is just my idea of what it is). It's built on top of Neovim's ui2 system, so Neovim >= 0.12 is required.

> [!WARNING]
> This is only wrapped up like a plugin for fun and convenience of installation. It's currently NOT a "plugin" in the sense that it will be stable or maintained.

## The main idea
The [Neovim 0.12 ui2 system](https://neovim.io/doc/user/lua/#ui2) introduced a new way for routing messages to different "views" as targets (e.g. "cmd", "pager", "msg").
While it's fantastic and eliminated the annoying "press enter" blocking messages, some messages are a bit _too_ ephermal.
Routing to `msg` only shows the message for a few seconds and requires you to click on the message window with your mouse to keep it alive.
Routing to `cmd` shows the message in a convenient bottom view, but is immediately removed on cursor move. 
Of course, you can always press `g<` to refocus the last message in the `pager`, but in some cases, I find myself having to reopen and close the last message several times to reread because it doesn't stick around when exiting (for example when reading a lua error and then going to the line referred to in stack trace).

The solution presented here is a new view (`msgarea`) that is sits somewhere in between `pager` and `cmd` in terms of function.
Setting a message target to `msgarea` will now open a "Messages" window below the statusline and automatically handle setting/resetting `cmdheight` when message content is emitted to the handler.
Focusing the `pager` with e.g. `g<` still closes the "Messages" window, so that behavior is the same.


When I say `msgarea`, I mean the view or region of the screen below the statusline, where the "Messages" window is just one window that can be opened in the view.
Here, _any_ arbitrary window can be opened in the `msgarea` (see Usage), where the winbar provides clickable tabs to see which windows are active.

### How it works
It's basically just monkey patching and autocmds... 
I patch `vim.api.nvim_open_win()` to now accept a `relative = "msgarea"` option in the win config, and patch `require("vim._core.ui2.messages").msg_show` to handle a new target `"msgarea"`.
Then, a bunch of autocmds handle the dynamic `vim.o.cmdheight` resizing based on the currently active windows in the `msagarea` (see `require("msgarea").state`)

## Installation
vim.pack:
```lua
vim.pack.add({
  "https://github.com/edisj/msgarea.nvim",
})
```

## Quickstart
This plugin does not export a `setup()` function. It is automatically enabled and modules are `require`'d lazily. 

To configure, there are only three options:
- `vim.g.msgarea_enabled`, `boolean` (toggle plugin on/off)
- `vim.g.msgarea_max_height`, `number` (lines if >= 1, % of lines if < 1)
- `vim.g.msgarea_min_height`, `number` (lines if >= 1, % of lines if < 1)

```lua
vim.pack.add({ "https://github.com/edisj/msgarea.nvim" })
vim.g.msgarea_max_height = 15
-- vim.g.msgarea_max_height = 0.4    OR fractional heights 0-1 are percentage of editor height
vim.g.msgarea_min_height = 3
-- vim.g.msgarea_min_height = 0.1    same as above

-- if you use blink.cmp and want to have cmdline completions render in msgarea
require("msgarea.blink_integration").enable()
-- require("msgarea.blink_integration").disable()  -- can be disabled at any time
```

## Usage
There are 2 ways to use it:

### 1. Set targets you want to appear in the "Messages" window in `require("vim._core.ui2").cfg.msg.targets`:
can be done when enabling ui2, for example:
```lua
require("vim._core.ui2").enable({
  enable = true,
  msg = {
    targets = {
      default = "msg",
      typed_cmd = "msgarea",
      wmsg = "msgarea",
      emsg = "msgarea",
      lua_error = "msgarea",
      list_cmd  = "msgarea",
      lua_print = "msgarea",
      echoerr = "msgarea",
      shell_out = "msgarea",
      shell_cmd = "msgarea",
      shell_err = "msgarea",

      confirm = "pager",
      rpc_error = "pager",
    },
    msg = { timeout = 4000 },
    pager = { height = 0.75 },
  }
})

```

or sometime after you've enabled it:
```lua
-- assuming you already called require("vim._core.ui2").enable({ ... })" in your config
local targets = require("vim._core.ui2").cfg.msg.targets
targets.list_cmd = "msgarea"
targets.lua_print = "msgarea"
targets.lua_error = "msgarea"
...
```

### 2. Open any window in the `msgarea`
The general idea is that any window can be opened in the "msgarea" view by setting `relative = "msgarea"` in the win config:
```lua
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_open_win(buf, false, {
  title = "Scratch",
  relative = "msgarea",
  height = 10,
})
```
The `title` field is removed from the window and instead used in the winbar as a clickable tab (left click focuses, right click closes). If no `title` is provided, there will be no tab in the winbar for that window.
Each window "requests" a `height`, but the actual msgarea height will be set to the maximum across all active windows in the view (clamped to min and max height).
This means if window A is set to `height=8`, and window B is set to `height=10`, 10 will be used for both windows, as this prevents "bouncing" when switching focus between windows in the view.

## Examples
Here are some examples I use in my config that I find really nice:

- blink.cmp completions (like [vertico](https://github.com/minad/vertico) in emacs)

- picker (I use [mini](https://github.com/nvim-mini/mini.pick))

- output of vim.system command

- quickfix list

- terminal

- 
