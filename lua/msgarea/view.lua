local api = vim.api
local fn = vim.fn
local ui2 = require("vim._core.ui2")
local config = require("msgarea.config")
local util = require("msgarea.util")
local internal = {}
local M = {
  original_cmdheight = vim.o.cmdheight, ---@type integer
  state = {
    windows = {
      ephemeral = nil ---@type MsgArea.WinSpec
    },
    height = vim.o.cmdheight,
    refresh_pending = false,
    refresh_opts = {}, ---@type MsgArea.View.ShowOpts
  }
}
setmetatable(M.state, {
  __index = function(t, k)
    if k == "focused" then
      return internal.focused_winid
    else
      return rawget(t, k)
    end
  end,
  __newindex = function(t, k, v)
    if k == "focused" then
      local i = internal.history_ring.idx
      if v == internal.history_ring[i] then return end
      internal.set_focus_and_add_to_history_ring(v)
    else
      rawset(t, k, v)
    end
  end,
})

local WIN_ERROR = 0
local WINHL_STR = "WinBar:MsgAreaWinBar,WinBarNC:MsgAreaWinBar,NormalFloat:MsgArea,Normal:MsgArea"
local WINBAR_STR = "%{%v:lua.require'msgarea.winbar'.render()%}"

---@class (exact) MsgArea.WinSpec
---@field bufnr integer
---@field winid integer
---@field title? string
---@field height integer
---@field border any[]|"none"|"single"|"double"|"rounded"|"solid"|"shadow"
---@field border_height integer

---monkey-patched nvim_open_win
M.open_win = function(nvim_open_win, buf, enter, opts)
  assert(opts.relative == "msgarea")
  opts = opts or {}
  local title = opts.title
  local is_ephemeral = title == nil
  if is_ephemeral and M.state.windows.ephemeral then
    if M.in_ephemeral() then
      util.error("cannot open an ephemeral win while currently focusing another ephemeral win")
      return WIN_ERROR
    else
      local eph_winid = M.state.windows.ephemeral.winid
      pcall(api.nvim_win_close, eph_winid, true)
    end
  end
  -- The key idea here is that every window is opened as a hidden float,
  -- where the cmdheight and which window is shown is handled in `M.show()`
  local win_config = internal.initial_win_config(opts, is_ephemeral)
  local winid = nvim_open_win(buf, enter, win_config)
  if winid == WIN_ERROR then return WIN_ERROR end
  vim.wo[winid].winfixheight = true
  vim.wo[winid].winhl = WINHL_STR
  internal.win_set_autocmds(winid, buf, is_ephemeral)

  ---@type MsgArea.WinSpec
  local win_spec = {
    bufnr = buf,
    winid = winid,
    title = title,
    height = win_config.height,
    border = win_config.border,
    border_height = internal.border_height(win_config.border),
  }
  local k = is_ephemeral and "ephemeral" or #M.state.windows + 1
  M.state.windows[k] = win_spec

  ui2.msg.cmd:clear()
  M.show({ silent = true, focused = not is_ephemeral and winid or nil })
  return winid
end

---monkey-patched nvim_win_set_config
M.win_set_config = function(nvim_win_set_config, win, win_config)
  assert(win_config.relative == "msgarea")
  local buf = api.nvim_win_get_buf(win)
  local title = win_config.title
  local is_ephemeral = title == nil

  local k = internal.key_of(win)
  if k == nil then
    k = is_ephemeral and "ephemeral" or #M.state.windows + 1
    vim.wo[win].winfixheight = true
    vim.wo[win].winhl = WINHL_STR
    internal.win_set_autocmds(win, buf, is_ephemeral)
  end

  win_config = internal.initial_win_config(win_config)
  win_config.title = nil
  win_config.title_pos = nil
  local win_spec = {
    bufnr = buf,
    winid = win,
    title = title,
    height = win_config.height,
    border = win_config.border,
    border_height = internal.border_height(win_config.border),
  }
  M.state.windows[k] = win_spec

  nvim_win_set_config(win, win_config)
  M.show({ silent = true, focused = not is_ephemeral and win or nil })
end

local schedule_refresh = function(opts)
  local state = M.state
  state.refresh_pending, state.refresh_opts = true, opts
  vim.schedule(function()
    if not state.refresh_pending then return end
    state.refresh_opts.flush = true
    M.show(state.refresh_opts)
    api.nvim__redraw({ flush = true })
    state.refresh_pending, state.refresh_opts = false, {}
  end)
end

---@class (exact) MsgArea.View.ShowOpts
---@field silent? boolean suppress warning msg (default false)
---@field focused? integer focused winid override
---@field height? integer view height override
---@field cmdheight? integer cmdheight override
---@field style? "msgarea"|"split" style override
---@field winbar_min_tabs? integer config.view.winbar_min_tabs override
---@field flush? boolean (default false)

---Show or refresh the msgarea view.
---@param opts? MsgArea.View.ShowOpts
M.show = function(opts)
  local state = M.state
  opts = vim.tbl_deep_extend("force", state.refresh_opts, opts or {})
  if not opts.flush then schedule_refresh(opts); return end

  if vim.tbl_isempty(state.windows) then
    if not opts.silent then util.warn("no active windows") end -- TODO: do i need silent?
    if fn.mode() ~= "c" then vim.o.cmdheight = M.original_cmdheight end
    return
  end

  local style = opts.style or M.style()
  local height = opts.height or M.height()
  state.height = height

  local eph = state.windows.ephemeral
  local new_cmdheight = opts.cmdheight
    or (eph and eph.height + eph.border_height)
    or (style == "split" and fn.mode() ~= "c" and M.original_cmdheight)
    or (style == "msgarea" and height)
  if new_cmdheight then vim.o.cmdheight = new_cmdheight end

  if opts.focused then
    if internal.key_of(opts.focused) == nil then
      error("winid " .. opts.focused .. " not found")
    end
    state.focused = opts.focused
  else
    -- NOTE: this case occurs when focus needs to return to a window not in history...
    -- can increase buffer size or maybe think of a better idea than ring buffer
    if state.focused == nil then
      state.focused = state.windows[1] and state.windows[1].winid
    end
  end

  local min_tabs = opts.winbar_min_tabs or config.get().view.winbar_min_tabs
  local N_active = #state.windows
  for _, win_spec in ipairs(state.windows) do
    local winid = win_spec.winid
    if api.nvim_win_is_valid(winid) then
      local win_config = internal.win_config(win_spec, height - win_spec.border_height, style)
      api.nvim_win_set_config(winid, win_config)
      vim.wo[winid].winbar = N_active >= min_tabs and WINBAR_STR or ""
    end
  end
  if eph then
    local win_cfg = internal.ephemeral_win_config(eph)
    api.nvim_win_set_config(eph.winid, win_cfg)
  end
end

---Close all msgarea windows and reset state.
M.close_all = function()
  M.state.closing = true
  -- NOTE: interesting bug if you don't deepcopy this.
  -- Because elements are removed from windows in WinClosed
  -- autocmd, windows is shifted every time a window is closed,
  -- which means by the time ipairs gets to an index, the element may not
  -- exist anymore in that index
  local windows = vim.deepcopy(M.state.windows)
  for _, win_spec in pairs(windows) do
    pcall(api.nvim_win_close, win_spec.winid, true)
  end
  M.state.focused = nil
  M.state.windows = {}
  M.state.closing = false
  vim.o.cmdheight = M.original_cmdheight
end

---@class (exact) MsgArea.View.HideOpts
---@field cmdheight? integer cmdheight override

---Hide, but do not close, all msgarea windows.
---Subsequent `require("msgarea").show()` will restore saved view state.
---@param opts? MsgArea.View.HideOpts
M.hide = function(opts)
  opts = opts or {}
  local state = M.state
  state.refresh_pending, state.refresh_opts = false, {}
  if vim.tbl_isempty(M.state.windows) then return end
  ui2.msg.msg_clear()
  local hide_opts = {
    hide = true,
    relative = "editor",
    row = vim.o.lines,
    col = 0,

    width = vim.o.columns,
    height = M.state.height
  }
  for _, win_spec in pairs(M.state.windows) do
    pcall(api.nvim_win_set_config, win_spec.winid, hide_opts)
  end
  if opts.cmdheight then
    ui2.cmdheight = opts.cmdheight
    vim.o.cmdheight = opts.cmdheight
  end

end

---@return "msgarea" | "split"
M.style = function()
  local view_config = config.get().view
  return (fn.mode() == "c" and view_config.style_while_in_cmdline)
          or (M.state.windows.ephemeral and view_config.style_while_in_ephemeral_win)
          or view_config.style
end

---Current idea is to take the maximum height across all active windows
---open in the msgarea and use that height for all windows to prevent
---"height bouncing" when switching between them.
---@return integer height clamped to min_height <= h <= max_height
M.height = function()
  local h = M.original_cmdheight
  if #M.state.windows == 0 then return h end
  for _, win in ipairs(M.state.windows) do
    h = math.max(h, win.height + win.border_height)
  end
  return math.max(math.min(h, M.max_height()), M.min_height())
end

---Compute max height based on `config.view.max_height`.
---@return integer
M.max_height = function(max)
  max = max or config.get().view.max_height
  if max > 0 and max < 1 then
    max = math.floor(max * vim.o.lines)
  end
  return max
end

---Compute min height based on `config.view.min_height`.
---@return integer
M.min_height = function(min)
  min = min or config.get().view.min_height
  if min > 0 and min < 1 then
    min = math.floor(min * vim.o.lines)
  end
  local actual_min_height =
    #M.state.windows >= config.get().view.winbar_min_tabs and 2 or 1
  min = min < actual_min_height and actual_min_height or min
  return min
end

---Whether an ephemeral window is currently focused.
---Currently treating in cmdline as in ephemeral
---@return boolean
M.in_ephemeral = function()
  return (api.nvim_get_current_win() == (M.state.windows.ephemeral or {}).winid) or fn.mode() == "c"
end


-- internal helpers -----------------------------------------------------------

local shared_win_opts = function()
  return {
    anchor = "SW",
    relative= "editor",
    row = vim.o.lines,
    col = 0,
    width = vim.o.columns,
    zindex = api.nvim_win_get_config(ui2.wins.cmd).zindex + 1
  }
end

internal.win_config = function(win_spec, height, style)
  if style == "split" and win_spec.winid == M.state.focused then
    return { split = "below", win = -1, height = height, hide = false }
  else -- style == "msgarea" or is unfocused window
    local hide = (fn.mode() == "c" and style == "msgarea") or win_spec.winid ~= M.state.focused
    return vim.tbl_deep_extend("force", shared_win_opts(), {
      hide = hide,
      border = win_spec.border,
      height = height,
    })
  end
end

internal.initial_win_config = function(opts, is_ephemeral)
  opts.border = opts.border or "none"
  local b_height = internal.border_height(opts.border)

  local height = opts.height or 1
  if is_ephemeral then
    height = math.min(height, M.max_height(ui2.cfg.msg.cmd.height))
  else
    height = math.min(height, M.max_height())
    height = math.max(height, M.min_height())
  end
  height = height - b_height

  local win_config = vim.tbl_deep_extend("force", opts, shared_win_opts(), {
    hide = true,
    height = height,
    border = opts.border,
  })
  win_config.title = nil
  win_config.title_pos = nil
  win_config.split = nil

  return win_config
end

internal.ephemeral_win_config = function(win_spec)
  local win_cfg
  if fn.mode() == "c" then
    win_cfg = { hide = false, height = win_spec.height, split = "below", win = -1 }
  else
    win_cfg = vim.tbl_deep_extend("force", shared_win_opts(), {
      hide = false,
      border = win_spec.border,
      height = win_spec.height,
    })
  end
  return win_cfg
end

internal.border_height = function(b)
  if b == nil then return 0 end
  if type(b) == "string" then
    local bheights = {
      none = 0, single = 2, double = 2, rounded = 2,
      solid = 2, shadow = 1, bold = 2,
    }
    return bheights[b] or 0
  end
  local h = 0
  if b[2] ~= "" then h = h + 1 end
  if b[6] ~= "" then h = h + 1 end
  return h
end

internal.win_set_autocmds = function(winid, bufnr, is_ephemeral)
  local id = api.nvim_create_augroup("msgarea.nvim-" .. tostring(winid), { clear = true })
  local on = function(event, opts, cb)
    api.nvim_create_autocmd(event, {
      group = id,
      buf = opts.buf,
      pattern = opts.pattern and tostring(opts.pattern) or nil,
      callback = function(...)
        if not (winid and api.nvim_win_is_valid(winid)) then return true end
        cb(...)
      end
    })
  end

  local state = M.state

  do
    local remove_win_from_state = function()
      vim.schedule(function() pcall(api.nvim_del_augroup_by_id, id) end)
      if state.closing then return end
      local k = internal.key_of(winid)
      if k == nil then return end
      if k == "ephemeral" then
        state.windows[k] = nil
      else
        assert(type(k) == "number")
        -- NOTE: this is very inefficient when closing multiple windows in a single call
        -- due to excessively shifting elements, but shouldn't matter with such small `n`.
        -- Maybe look into better removal strategy...
        table.remove(state.windows, k)
      end
      local focused = winid == internal.focused_winid and internal.get_last_focused() or nil
      -- FIXME: special case to prevent showing when closing ephemeral
      -- to enter pager. Need to think of a better solution
      if api.nvim_get_current_win() ~= ui2.wins.pager then
        M.show({ silent = true, focused = focused })
      end
    end
    on("WinClosed", { pattern = winid }, remove_win_from_state)
  end

  do
    local update_winsize = vim.schedule_wrap(function(new_height)
      M.show({ flush = true, height = new_height })
      if not api.nvim_win_get_config(ui2.wins.msg).hide then
        ui2.msg.set_pos()
      end
    end)
    on({ "WinResized", "VimResized" }, { buf = bufnr }, function(ev)
      local new_height
      if ev.event == "WinResized" then
        new_height = api.nvim_win_get_height(winid)
      end
      update_winsize(new_height)
    end)
  end

  if is_ephemeral then
    local scheduled_close = vim.schedule_wrap(function()
      pcall(api.nvim_win_close, winid, true)
    end)
    on("WinLeave", { buf = bufnr }, scheduled_close)
    -- NOTE: defer CursorMoved in case cursor is moved while cmdheight changes
    vim.defer_fn(function()
      -- wrapped in pcall because group id can be deleted by the time defer is called
      pcall(on, "CursorMoved", {}, function()
        if api.nvim_get_current_win() == winid then return end
        scheduled_close()
      end)
    end, 50)
  end

end

internal.key_of = function(winid)
  for i, win in ipairs(M.state.windows) do
    if win.winid == winid then return i end
  end
  if (M.state.windows.ephemeral or {}).winid == winid then
    return "ephemeral"
  end
end

internal.focused_winid = nil
internal.history_ring = { idx = 0, size = 20 }
internal.set_focus_and_add_to_history_ring = function(winid)
  -- IMPORTANT: set focused_winid even when winid is nil
  -- otherwise M.state.focused will have invalid winid
  internal.focused_winid = winid
  if not winid then return end
  internal.history_ring.idx = internal.history_ring.idx + 1
  local i, size = internal.history_ring.idx, internal.history_ring.size
  i = ((i - 1) % size) + 1 -- clamp i to 1..size
  internal.history_ring[i] = winid
end

---@return integer? window-ID of last focused win in msgarea
internal.get_last_focused = function()
  local i, size = internal.history_ring.idx, internal.history_ring.size
  -- idea here is to walk backwards from current position
  -- in history ring until we find a valid winid
  for _ = 1, size do
    -- NOTE: add `size` before mod to ensure nonnegative value
    -- e.g. if `i` = 5 and `size` = 20,
    -- then walking backwards 20 steps will walk into negative values,
    -- so we make 5 -> 25 first
    i = (i + size - 2) % size + 1 -- add 1 for lua indexing
    local winid = internal.history_ring[i]
    if
      winid ~= nil
      and api.nvim_win_is_valid(winid)
      and winid ~= internal.focused_winid
    then
      return winid
    end
  end
end


return M
