# msgarea.nvim

An experimental proof-of-concept for a "msgarea" view similar to "minibuffer" in emacs (although I've never used emacs, so this is just my idea of what it is). It's built on top of Neovim's ui2 system, so Neovim >= 0.12 is required.

> [!WARNING]
> This is only wrapped up like a plugin for fun and convenience of installation. It's currently NOT a "plugin" in the sense that it will be stable or maintained.

<img width="1855" height="1082" alt="msgarea_pic" src="https://github.com/user-attachments/assets/dd3915ab-0fbb-45ec-9942-3022dafc0049" />

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
Here, _any_ arbitrary window can be opened in the `msgarea` (see [Usage](#usage) and [Examples](#examples)), where the winbar provides clickable tabs to see which windows are active.

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

-- set a keymap to collapse the msgarea
vim.keymap.set("n", "<M-n>", function() require("msgarea").close_all() end)
-- two other api functions are available:
-- require("msgarea").hide()   hide (but do not close) all windows and collapse cmdheight 
-- require("msgarea").show()   reveal all windows and expand cmdheight 
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
-- assuming you already called require("vim._core.ui2").enable({ ... }) in your config
local targets = require("vim._core.ui2").cfg.msg.targets
for _, target in ipairs({
  "wmsg",
  "emsg",
  "typed_cmd",
  "list_cmd",
  "lua_error",
  "lua_print",
  "echoerr",
}) do
  ---@diagnostic disable-next-line: assign-type-mismatch
  targets[target] = "msgarea"
end
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

Here's a video where I demonstrate having multiple windows in the view:

https://github.com/user-attachments/assets/429393aa-8635-4792-a89d-7205796265bb

## Examples
Here are some examples I use in my config that I find really nice:

### ● blink.cmp cmdline completions (like [vertico](https://github.com/minad/vertico) in emacs)</summary>
This requires you to call <code>require("msgarea.blink_integration").enable()</code> somewhere in your config. 

> [!NOTE]
> if you want command descriptions like I have here see my blink config https://github.com/edisj/dotfiles/blob/8b17faf5f6882153e9456ecf4a6b69d9e042f777/linux/.config/nvim/plugin/4_plugins/blink.lua#L125-L178

https://github.com/user-attachments/assets/aea1b357-702a-463c-8a65-f6ae8740cf30

### ● picker (I use [mini](https://github.com/nvim-mini/mini.pick))
Just add this to your `mini.pick` config (or whichever picker you use that lets you set win config options):

```lua
require("mini.pick").setup({
  window = {
    config = {
      relative = "msgarea",
      border = { "▔", "▔", "▔", " ", " ", " ", " ", " " },
      height = 15,
    },
  },
})
```

<img width="1855" height="1082" alt="minidemo2" src="https://github.com/user-attachments/assets/ffe31d96-f6c7-41fe-a8a5-af8187814195" />

### ● output of vim.system command

https://github.com/user-attachments/assets/8cb5fb3a-ed33-4306-b791-004805e79aeb

### ● quickfix list (2 example usecases)
- in edit->compile->edit context:

https://github.com/user-attachments/assets/e4e8ca4a-8936-423e-8047-0201566c86c8

- quickfix diagnostics:

https://github.com/user-attachments/assets/b35915e5-7a57-41f9-8239-edd87a89de1b

### ● terminal
Here's the minimal amount of code to set it set it up:
```lua
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_call(buf, function() vim.cmd.terminal() end)
vim.api.nvim_open_win(buf, true, {
  title = "THIS WILL GO IN THE WINBAR",
  relative = "msgarea",
  style = "minimal",
  height = 15,
})
```

https://github.com/user-attachments/assets/0f320eb0-3746-4af6-b54c-07f872521317
