local api = vim.api
local fn = vim.fn
local ui2 = require("vim._core.ui2")
local view = require("msgarea.view")
local messages = require("msgarea.messages")
local M = {}

local id
M.setup = function(config)
  if not config.enabled then
    pcall(api.nvim_del_augroup_by_id, id)
    return
  end

  id = vim.api.nvim_create_augroup("msgarea.autocmds", { clear = true })
  local on = function(event, pattern, desc, cb)
    local opts = { group = id, pattern = pattern, desc = "(msgarea.nvim) " .. desc, callback = cb }
    api.nvim_create_autocmd(event, opts)
  end

  do
    local desc = "refresh height of active windows on cmdheight change"
    local refresh_heights = function()
      if
        fn.mode() == "c"
        or view.style() == "split"
        or vim.v.option_new == vim.v.option_old
      then
        return
      end
      local h = vim.v.option_new
      for _, win_spec in ipairs(view.state.windows) do
        if api.nvim_win_is_valid(win_spec.winid) then
          h = h - win_spec.border_height
          api.nvim_win_set_height(win_spec.winid, h)
        end
      end
    end
    on("OptionSet", "cmdheight", desc, refresh_heights)
  end

  do
    -- NOTE: this occurs if, for example, you press a keymap to focus a msgarea window
    -- and that is not the currently focused window in require("msgarea.view").state.focused
    local desc = "ensure msgarea window is focused when entered"
    local ensure_focused = function(ev)
      local winid
      for _, win in ipairs(view.state.windows) do
        if win.bufnr == ev.buf then
          winid = win.winid
          break
        end
      end
      if
        winid == nil                                -- not a msgarea win
        or vim.api.nvim_get_current_win() ~= winid  -- is msgarea win but not focused
        or view.state.focused == winid              -- already focused
      then
        return
      end
      view.show({ flush = true, silent = true, focused = winid })
    end
    on("WinEnter", "*", desc, ensure_focused)
  end

  local in_prompt = function()
    -- NOTE: it may be preferrable to use getcmdtype() or getcmdprompt() instead...
    -- not sure about if there will be issues with async ordering
    return ui2.cmd.prompt
  end

  local in_pager = function()
    return api.nvim_get_current_win() == ui2.wins.pager
  end

  do
    local desc = "hide msgarea when entering any prompt"
    local hide_msgarea_in_prompt = function() view.hide() end
    -- @ means input()
    -- - means confirm() or inputlist() or :s///c
    on("CmdlineEnter", { "@", "-" }, desc, hide_msgarea_in_prompt)
  end

  -- NOTE: `skip_refresh` only exists to fix annoying behavior when pressing
  -- keymaps that use ":" for <Cmd>, for example %
  -- Cursor still bounces to cmdline... not sure how to fix
  local skip_refresh = false

  do
    local desc = "refresh msgarea style on CmdlineEnter"
    local refresh_msgarea = vim.schedule_wrap(function()
      -- NOTE: this check is still needed even though we filter out the
      -- "@" and "-" patterns because here we're scheduling the refresh.
      -- For example, calling `:restart` with unsaved changes will trigger a
      -- CmdlineEnter event, the refresh will be scheduled, and THEN the confirm()
      -- prompt will trigger it's own CmdlineEnter refresh, at which point the
      -- scheduled refresh is still queued, so you get buggy dialog visual artifacts.
      if in_prompt() then return end
      if fn.mode() ~= "c" then skip_refresh = true; return end
      local cmdheight = config.view.style_while_in_cmdline == "split" and 1 or nil
      view.show({ silent = true, cmdheight = cmdheight })
    end)
    on("CmdlineEnter", { ":", "/", "\\?" }, desc, refresh_msgarea)
  end

  do
    local desc = "refresh msgarea style on CmdlineLeave"
    local refresh_msgarea = vim.schedule_wrap(function()
      if messages.msg_expanded then
        api.nvim_create_autocmd("CursorMoved", {
          once = true,
          callback = function()
            messages.msg_expanded = false
            if not in_pager() then view.show({ silent = true }) end
          end
        })
      else
        if in_prompt() or in_pager() then return end
        if skip_refresh then skip_refresh = false; return end
        view.show({ silent = true })
      end
    end)
    on("CmdlineLeave", "*" , desc, refresh_msgarea)
  end

  do
    local desc = "refresh mesgarea when leaving pager"
    local refresh_msgarea = function(ev)
      if ev.buf == ui2.bufs.pager then view.show({ flush = true, silent = true }) end
    end
    on("WinLeave", "*", desc, refresh_msgarea)
  end

  do
    local desc = "close msgarea before quitting"
    on("QuitPre", "*", desc, function() view.close_all() end)
  end

end

return M
