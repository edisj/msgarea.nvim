local api = vim.api
local fn = vim.fn
local ui2 = require("vim._core.ui2")
local view = require("msgarea.view")
local messages = require("msgarea.messages")
local M = {}

local skip_refresh = false

---@type { data: msgarea.view.WinData, idx: integer, prev_curwin: integer? }?
local saved_ephemeral_state = nil

local save_ephemeral_state = function()
  local eph = view.state.windows.ephemeral
  if not eph then return end

  if api.nvim_get_current_win() ~= eph.winid then
    view.close_ephemeral(1)
    return
  end

  local data = eph
  local idx = #view.state.windows + 1
  local prev_curwin = view.state.curwin
  saved_ephemeral_state = { data = data, idx = idx, prev_curwin = prev_curwin }
  view.state.windows[idx] = eph
  view.state.windows.ephemeral = nil

  local curwin = data.winid
  local height = data.inner_height + data.border_height
  return curwin, height
end

local restore_ephemeral_state = function()
  if not saved_ephemeral_state then return end

  local curwin = saved_ephemeral_state.prev_curwin
  table.remove(view.state.windows, saved_ephemeral_state.idx)
  if api.nvim_win_is_valid(saved_ephemeral_state.data.winid) then
    view.state.windows.ephemeral = saved_ephemeral_state.data
  end
  saved_ephemeral_state = nil

  return curwin
end

local autocmds = {
  {
    ev = "CmdlineEnter",
    desc = "refresh msgarea state on cmdline enter",
    pattern = "*",
    nested = true,
    cb = function(ev)
      if ev.match == "-" then
        view.hide({ cmdheight = view.original_cmdheight })
      else
        local curwin, height = save_ephemeral_state()
        vim.schedule(function()
          -- NOTE: this check is still needed even though we filter out the
          -- "@" and "-" patterns because here we're scheduling the refresh.
          -- For example, calling `:restart` with unsaved changes will trigger a
          -- CmdlineEnter event, the refresh will be scheduled, and THEN the confirm()
          -- prompt will trigger it's own CmdlineEnter refresh, at which point the
          -- scheduled refresh is still queued, so you get buggy dialog visual artifacts.
          if ev.match == "-" and ui2.cmd.prompt then return end
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
        local autocmd_opts = {
          once = true,
          callback = function()
            messages.msg_expanded = false
            if not (api.nvim_get_current_win() == ui2.wins.pager) then
              view.show({ silent = true })
            end
          end
        }
        api.nvim_create_autocmd("CursorMoved", autocmd_opts)
      else
        vim.schedule(function()
          if ui2.cmd.prompt or (api.nvim_get_current_win() == ui2.wins.pager) then return end
          if skip_refresh then skip_refresh = false; return end
          local curwin = restore_ephemeral_state()
          view.show({ flush = true, silent = true, curwin = curwin })
        end)
      end
    end,
  },
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
        or vim.v.option_new == vim.v.option_old
        or view.state.setting_cmdheight
      then
        return
      end
      local new_cmdheight = vim.v.option_new
      local data
      if view.style() == "split" then
        data = view.state.windows["ephemeral"]
      else
        local state = view.get_state()
        for i, _data in ipairs(state.windows) do
          if _data.winid == state.curwin then
            data = view.state.windows[i]
            break
          end
        end
      end
      if data and api.nvim_win_is_valid(data.winid) then
        local height = new_cmdheight - data.border_height
        api.nvim_win_set_height(data.winid, height)
      end
    end,
  },
  {
    ev = "QuitPre",
    desc = "close msgarea before closing tabpage",
    pattern = "*",
    cb = function()
      local tab_will_close = true
      local curwin = api.nvim_get_current_win()
      local active_wins = vim
        .iter(pairs(view.state.windows))
        :map(function(_, data) return data.winid end)
        :totable()
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if
          win ~= curwin
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
      nested = autocmd.nested,
      callback = autocmd.cb,
    }
    api.nvim_create_autocmd(autocmd.ev, autocmd_opts)
  end
end

return M
