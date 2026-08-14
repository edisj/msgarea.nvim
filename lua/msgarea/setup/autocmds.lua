local api = vim.api
local fn = vim.fn
local ui2 = require("vim._core.ui2")
local view = require("msgarea.view")
local messages = require("msgarea.messages")
local M = {}

-- NOTE: `skip_refresh` only exists to fix annoying behavior when pressing
-- keymaps that use ":" for <Cmd>, for example %
-- Cursor still bounces to cmdline... not sure how to fix
local skip_refresh = false

local saved_ephemeral_state
local saved_ephemeral_idx
local prev_curwin

local autocmds = {
  {
    ev = "WinEnter",
    desc = "ensure msgarea window is focused when entered",
    pattern = "*",
    cb = function(ev)
      -- NOTE: this occurs if, for example, you press a keymap to focus a msgarea window
      -- and that is not the currently focused window in require("msgarea.view").state.focused
      local winid
      for _, data in ipairs(view.get_state().windows) do
        if data.bufnr == ev.buf then
          winid = data.winid
          break
        end
      end
      if
        winid == nil                                -- not a msgarea win
        or vim.api.nvim_get_current_win() ~= winid  -- is msgarea win but not focused
        or view.state.curwin == winid              -- already focused
      then
        return
      end
      view.show({ silent = true, curwin = winid })
    end,
  },
  {
    ev = "WinLeave",
    desc = "refresh mesgarea when leaving pager",
    pattern = "*",
    cb = function(ev)
      if ev.buf == ui2.bufs.pager then view.show({ silent = true }) end
    end,
  },
  {
    ev = "OptionSet",
    desc = "refresh height of active windows on cmdheight change",
    pattern = "cmdheight",
    cb = function()
      if
        fn.mode() == "c"
        or view.style() == "split"
        or vim.v.option_new == vim.v.option_old
      then
        return
      end
      local h = vim.v.option_new
      for _, data in ipairs(view.state.windows) do
        if api.nvim_win_is_valid(data.winid) then
          h = h - data.bheight
          api.nvim_win_set_height(data.winid, h)
        end
      end
    end,
  },
  {
    ev = "QuitPre",
    desc = "close msgarea before closing tabpage",
    pattern = "*",
    cb = function()
      local tab_will_close = true
      local curr_win = api.nvim_get_current_win()
      local active_wins = vim.iter(view.state.windows):map(function(data) return data.winid end):totable()
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if
          win ~= curr_win
          and not vim.tbl_contains(active_wins, win)
          and api.nvim_win_get_config(win).relative == ""
        then
          tab_will_close = false
          break
        end
      end
      if tab_will_close then view.close_all() end
    end,
  },
  {
    ev = "CmdlineEnter",
    desc = "refresh msgarea state on cmdline enter",
    pattern = "*",
    cb = function(ev)
      if ev.match == "@" or ev.match == "-" then
        -- FIXME: why does confirm bug out sometimes and not render correctly?
        view.hide({ cmdheight = 0 })
      else
        local eph, curwin, height = view.state.windows.ephemeral, nil, nil
        if eph then
          if api.nvim_get_current_win() ~= eph.winid then
            view.close_ephemeral(1)
          else
            prev_curwin = view.state.curwin
            saved_ephemeral_state, saved_ephemeral_idx = eph, #view.state.windows + 1
            view.state.windows[saved_ephemeral_idx] = saved_ephemeral_state
            view.state.windows.ephemeral = nil
            curwin = saved_ephemeral_state.winid
            height = api.nvim_buf_line_count(saved_ephemeral_state.bufnr)
          end
        end
        vim.schedule(function()
          -- NOTE: this check is still needed even though we filter out the
          -- "@" and "-" patterns because here we're scheduling the refresh.
          -- For example, calling `:restart` with unsaved changes will trigger a
          -- CmdlineEnter event, the refresh will be scheduled, and THEN the confirm()
          -- prompt will trigger it's own CmdlineEnter refresh, at which point the
          -- scheduled refresh is still queued, so you get buggy dialog visual artifacts.
          if ui2.cmd.prompt then return end
          if fn.mode() ~= "c" then skip_refresh = true; return end
          view.show({ silent = true, cmdheight = 1, curwin = curwin, height = height })
        end)
      end
    end,
  },
  {
    ev = "CmdlineLeave",
    desc = "refresh msgarea state on cmdline leave",
    pattern = "*",
    cb = function()
      if messages.msg_expanded then
        api.nvim_create_autocmd("CursorMoved", {
          once = true,
          callback = function()
            messages.msg_expanded = false
            if not (api.nvim_get_current_win() == ui2.wins.pager) then
              view.show({ silent = true })
            end
          end
        })
      else
        vim.schedule(function()
          if ui2.cmd.prompt or (api.nvim_get_current_win() == ui2.wins.pager) then return end
          if skip_refresh then skip_refresh = false; return end

          local curwin
          if saved_ephemeral_state then
            curwin = prev_curwin
            table.remove(view.state.windows, saved_ephemeral_idx)
            if api.nvim_win_is_valid(saved_ephemeral_state.winid) then
              view.state.windows.ephemeral = saved_ephemeral_state
            end
            saved_ephemeral_state, saved_ephemeral_idx, prev_curwin = nil, nil, nil
          end
          view.show({ silent = true, curwin = curwin })
        end)
      end
    end,
  },
}

local id -- augroup id
M.setup = function(config)
  if not config.enable then
    pcall(api.nvim_del_augroup_by_id, id)
    return
  end
  id = vim.api.nvim_create_augroup("msgarea.autocmds", { clear = true })
  for _, autocmd in ipairs(autocmds) do
    local autocmd_opts = {
      group = id,
      desc = "(msgarea.nvim) " .. autocmd.desc,
      pattern = autocmd.pattern,
      callback = autocmd.cb,
    }
    api.nvim_create_autocmd(autocmd.ev, autocmd_opts)
  end
end

return M
