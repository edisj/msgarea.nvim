local api, fn = vim.api, vim.fn
local ui2 = require("vim._core.ui2")
local config = require("msgarea.config")
local util = require("msgarea.util")
local internal = {}
local M = {
  original_cmdheight = vim.o.cmdheight, ---@type integer
  state = {
    windows = {
      ephemeral = nil ---@type msgarea.view.WinData
    },
    height = vim.o.cmdheight,
    refresh_pending = false,
    refresh_opts = {}, ---@type msgarea.view.ShowOpts
  }
}
setmetatable(M.state, {
  __index = function(t, k)
    if k == "curwin" then
      return internal.curwin
    else
      return rawget(t, k)
    end
  end,
  __newindex = function(t, k, v)
    if k == "curwin" then
      local i = internal.history_ring.idx
      if v == internal.history_ring[i] then return end
      internal.set_curwin_and_add_to_history_ring(v)
    else
      rawset(t, k, v)
    end
  end,
})

local WIN_ERROR = 0
local WINHL_STR = "WinBar:MsgAreaWinBar,WinBarNC:MsgAreaWinBar,FloatBorder:MsgArea,NormalFloat:MsgArea,Normal:MsgArea"
local WINBAR_STR = "%{%v:lua.require'msgarea.winbar'.render()%}"

---monkey-patched nvim_open_win
M.open_win = function(nvim_open_win, buf, enter, opts)
  assert(opts.relative == "msgarea")
  opts = opts or {}
  local title = opts.title

  local is_ephemeral = title == nil
  if is_ephemeral and M.state.windows.ephemeral then
    if M.in_ephemeral() then
      ui2.msg.show_msg("msgarea", nil, buf) -- TODO: handle all args
      return
    end
    local eph_winid = M.state.windows.ephemeral.winid
    M.close_safely(eph_winid)
  end

  -- The key idea here is that every window is opened as a hidden float,
  -- where the cmdheight and which window is shown is handled in `M.show()`
  local win_config = internal.initial_win_config(opts, is_ephemeral)
  local winid = nvim_open_win(buf, enter, win_config)
  if winid == WIN_ERROR then return WIN_ERROR end
  vim.wo[winid].winfixheight = true
  vim.wo[winid].winhl = WINHL_STR
  internal.win_set_autocmds(winid, buf, is_ephemeral)

  local windata = { ---@type msgarea.view.WinData
    bufnr = buf,
    winid = winid,
    title = title,
    height = win_config.height,
    border = win_config.border,
    bheight = internal.get_bheight(win_config.border),
  }
  local k = is_ephemeral and "ephemeral" or #M.state.windows + 1
  M.state.windows[k] = windata

  util.cmd_clear()
  M.show({ silent = true, curwin = not is_ephemeral and winid or nil })
  return winid
end

---monkey-patched nvim_win_set_config
M.win_set_config = function(nvim_win_set_config, win, win_config)
  assert(win_config.relative == "msgarea")
  if not (win and api.nvim_win_is_valid(win)) then return end
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
  local windata = { ---@type msgarea.view.WinData
    bufnr = buf,
    winid = win,
    title = title,
    height = win_config.height,
    border = win_config.border,
    bheight = internal.get_bheight(win_config.border),
  }
  M.state.windows[k] = windata

  nvim_win_set_config(win, win_config)
  M.show({ flush = true, silent = true, curwin = not is_ephemeral and win or nil })
end

local redraw_if_needed = function()
  if
    fn.mode() == "c"
    or (_G.MiniPick and _G.MiniPick.is_picker_active())
  then
    api.nvim__redraw({ flush = true })
  end
end

local schedule_refresh = function(opts)
  local state = M.state
  state.refresh_pending, state.refresh_opts = true, opts
  vim.schedule(function()
    if not state.refresh_pending then return end
    state.refresh_opts.flush = true
    M.show(state.refresh_opts)
    redraw_if_needed()
    state.refresh_pending, state.refresh_opts = false, {}
  end)
end

---@param opts? msgarea.view.ShowOpts
M.show = function(opts)
  local state = M.state
  opts = vim.tbl_deep_extend("force", state.refresh_opts, opts or {})
  if not opts.flush then schedule_refresh(opts); return end

  for i = #state.windows, 1, -1 do
    if not api.nvim_win_is_valid(state.windows[i].winid) then
      table.remove(state.windows, i)
    end
  end
  if vim.tbl_isempty(state.windows) then
    if not opts.silent then util.warn("no active windows") end -- TODO: do i need silent?
    if fn.mode() ~= "c" then vim.o.cmdheight = M.original_cmdheight end
    return
  end

  local style = opts.style or M.style()
  local view_height = opts.height or M.height()
  state.height = view_height

  local eph = state.windows.ephemeral
  local new_cmdheight = opts.cmdheight
                        or (eph and eph.height + eph.bheight + (M.cmp_menu_open() and 1 or 0))
                        or (style == "split" and fn.mode() ~= "c" and M.original_cmdheight)
                        or (style == "msgarea" and view_height)
  if new_cmdheight then vim.o.cmdheight = new_cmdheight; ui2.cmdheight = new_cmdheight end

  if opts.curwin then
    if internal.key_of(opts.curwin) == nil then
      error("winid " .. opts.curwin .. " not found")
    end
    state.curwin = opts.curwin
  else
    -- NOTE: this case occurs when focus needs to return to a window not in history...
    -- can increase buffer size or maybe think of a better idea than ring buffer
    if state.curwin == nil or not api.nvim_win_is_valid(state.curwin) then
      state.curwin = state.windows[1] and state.windows[1].winid
    end
  end

  local min_tabs = opts.winbar_min_tabs or config.get().view.winbar_min_tabs
  local N_active = #state.windows
  -- all of the win_config logic is in this for loop
  for k, data in pairs(state.windows) do
    local win_cfg
    local winid = data.winid
    if k == "ephemeral" then
      win_cfg = internal.shared_win_cfg()
      win_cfg.hide = false
      win_cfg.height = new_cmdheight - (M.cmp_menu_open() and 1 or 0) - data.bheight
      win_cfg.border = data.border
    else
      if style == "split" and winid == state.curwin then
        win_cfg = { hide = false, height = view_height, split = "below", win = -1 }
      else
        win_cfg = internal.shared_win_cfg()
        win_cfg.hide = winid ~= state.curwin
        win_cfg.height = view_height - data.bheight
        win_cfg.border = data.border
      end
    end
    api.nvim_win_set_config(winid, win_cfg)
    vim.wo[winid].winbar = data.title and N_active >= min_tabs and WINBAR_STR or ""
  end
end

M.close_all = function()
  local state = M.state
  state.closing = true
  for _, data in pairs(M.get_state().windows) do
    M.close_safely(data.winid)
  end
  state.curwin = nil
  state.windows = {}
  state.closing = false
  vim.o.cmdheight = M.original_cmdheight
end

---@param opts? msgarea.view.HideOpts
M.hide = function(opts)
  if opts and opts.cmdheight then
    ui2.cmdheight = opts.cmdheight
    vim.o.cmdheight = opts.cmdheight
  end
  local state = M.state
  if vim.tbl_isempty(state.windows) then return end
  state.refresh_pending, state.refresh_opts = false, {}
  ui2.msg.msg_clear()
  local win_cfg = {
    hide = true, relative = "editor", row = vim.o.lines,
    col = 0, width = vim.o.columns, height = state.height,
  }
  for _, data in pairs(state.windows) do
    pcall(api.nvim_win_set_config, data.winid, win_cfg)
  end
end

---Return deepcopy of current state
M.get_state = function()
  local state = M.state
  return {
    height = state.height,
    windows = vim.deepcopy(state.windows),
    curwin = state.curwin
  }
end

---@return "msgarea" | "split"
M.style = function()
  return (fn.mode() == "c" or M.state.windows.ephemeral) and "split"
          or config.get().view.style
end

---@return integer height clamped to min_height <= h <= max_height
M.height = function()
  -- NOTE: Current idea is to take the maximum height across all active
  -- windows open in the msgarea and use that height for all windows
  -- to prevent "height bouncing" when switching between them.
  local h, state = M.original_cmdheight, M.state
  local N_active = #state.windows
  if N_active == 0 then return h end
  for _, data in ipairs(M.state.windows) do
    h = math.max(h, data.height + data.bheight)
  end
  local winbar_is_showing = N_active >= config.get().view.winbar_min_tabs
  h = h + (winbar_is_showing and 1 or 0)
  h = math.max(math.min(h, M.max_height()), M.min_height())
  return h
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
  return min
end

---Whether an ephemeral window is currently focused.
---Currently treating in cmdline as in ephemeral
---@return boolean
M.in_ephemeral = function()
  return (api.nvim_get_current_win() == (M.state.windows.ephemeral or {}).winid) or fn.mode() == "c"
end

M.cmp_menu_open = function()
  local eph = M.state.windows.ephemeral
  if not (eph and api.nvim_buf_is_valid(eph.bufnr)) then return false end
  local ft = api.nvim_get_option_value("filetype", { buf = eph.bufnr })
  return eph and (ft == "blink-cmp-menu" or ft == "native-cmp-menu")
end

M.close_ephemeral = function(new_cmdheight)
  M.close_safely((M.state.windows.ephemeral or {}).winid)
  -- TODO: find out why this is needed!
  -- without it seems the state isn't updated in time?
  -- as in I get errors about win not being valid in some nvim_set_win_config call
  M.state.windows.ephemeral = nil
  if new_cmdheight then
    vim.o.cmdheight = new_cmdheight
    ui2.cmdheight = new_cmdheight
  end
end

M.close_safely = function(winid)
  if winid and api.nvim_win_is_valid(winid) then api.nvim_win_close(winid, true) end
end


-- internal helpers -----------------------------------------------------------

internal.shared_win_cfg = function()
  return {
    anchor = "SW",
    relative= "editor",
    row = vim.o.lines,
    col = 0,
    width = vim.o.columns,
    zindex = api.nvim_win_get_config(ui2.wins.cmd).zindex + 1
  }
end

internal.initial_win_config = function(opts, is_ephemeral)
  opts.border = opts.border or "none"

  local height = opts.height or 1
  if is_ephemeral then
    -- NOTE: max height of ephemeral window is determined by ui2 cmd setting
    height = math.min(height, M.max_height(util.cmd_height()))
  else
    height = math.min(height, M.max_height())
    height = math.max(height, M.min_height())
  end
  height = height - internal.get_bheight(opts.border)

  local win_config = vim.tbl_deep_extend("force", opts, internal.shared_win_cfg())
  win_config.border = opts.border
  win_config.height = height
  win_config.hide = true
  win_config.title = nil
  win_config.title_pos = nil
  win_config.split = nil
  return win_config
end

internal.get_bheight = function(b)
  if b == nil then return 0 end
  if type(b) == "string" then
    local border_heights = {
      none = 0, single = 2, double = 2, rounded = 2,
      solid = 2, shadow = 1, bold = 2,
    }
    return border_heights[b] or 0
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

  do
    local remove_win_from_state = function()
      vim.schedule(function() pcall(api.nvim_del_augroup_by_id, id) end)
      local state = M.state
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
      local curwin = winid == internal.curwin and internal.get_prev_curwin() or nil
      -- FIXME: special case to prevent showing when closing ephemeral
      -- to enter pager. Need to think of a better solution
      if api.nvim_get_current_win() ~= ui2.wins.pager then
        M.show({ silent = true, curwin = curwin })
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
      M.close_safely(winid)
    end)
    on("WinLeave", { buf = bufnr }, scheduled_close)
    -- NOTE: defer CursorMoved in case cursor is moved while cmdheight changes
    vim.defer_fn(function()
      -- wrapped in pcall because group id can be deleted by the time defer is called
      pcall(on, "CursorMoved", {}, function()
        -- NOTE: fn.mode() == "c" is needed for nvim-0.12
        if api.nvim_get_current_win() == winid or fn.mode() == "c" then return end
        scheduled_close()
      end)
    end, 50)
  end

end

internal.key_of = function(winid)
  local state = M.state
  for i, win in ipairs(state.windows) do
    if win.winid == winid then return i end
  end
  if (state.windows.ephemeral or {}).winid == winid then
    return "ephemeral"
  end
end

internal.curwin = nil
internal.history_ring = { idx = 0, size = 20 }
internal.set_curwin_and_add_to_history_ring = function(winid)
  -- IMPORTANT: set curwin even when winid is nil
  -- otherwise M.state.focused will have invalid winid
  internal.curwin = winid
  if not winid then return end
  internal.history_ring.idx = internal.history_ring.idx + 1
  local i, size = internal.history_ring.idx, internal.history_ring.size
  i = ((i - 1) % size) + 1 -- clamp i to 1..size
  internal.history_ring[i] = winid
end

---@return integer? window-ID of last focused win in msgarea
internal.get_prev_curwin = function()
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
      and winid ~= internal.curwin
    then
      return winid
    end
  end
end

---@class (exact) msgarea.view.WinData
---@field bufnr integer
---@field winid integer
---@field title? string
---@field height integer
---@field bheight integer
---@field border any[]|"none"|"single"|"double"|"rounded"|"solid"|"shadow"

---@class (exact) msgarea.view.ShowOpts
---@field silent? boolean suppress warning msg (default false)
---@field flush? boolean (default false)
---@field curwin? integer curwin winid override
---@field height? integer view height override
---@field cmdheight? integer cmdheight override
---@field style? "msgarea"|"split" style override
---@field winbar_min_tabs? integer config.view.winbar_min_tabs override

---@class (exact) msgarea.view.HideOpts
---@field cmdheight? integer cmdheight override

return M
