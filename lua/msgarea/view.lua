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
    height = nil, ---@type integer
    hold_ephemeral = false, ---@type boolean
    refresh_opts = {}, ---@type msgarea.view.ShowOpts
    refresh_pending = false, ---@type boolean
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
  opts = opts or {}
  assert(opts.relative == "msgarea")

  local title = opts.title
  local is_ephemeral = title == nil
  if is_ephemeral and M.state.windows.ephemeral then
    if M.in_ephemeral() then
      ---@diagnostic disable-next-line: param-type-mismatch
      ui2.msg.show_msg("msgarea", nil, buf, false, false, nil)
      return
    end
    local eph_winid = M.state.windows.ephemeral.winid
    M.close_safely(eph_winid)
  end

  -- The key idea here is that every window is opened as a hidden float,
  -- where the cmdheight and which window is shown is handled in `M.show()`
  local win_config = internal.initial_win_config(buf, opts)
  local winid = nvim_open_win(buf, enter, win_config)
  if winid == WIN_ERROR then return WIN_ERROR end
  vim.wo[winid].winfixheight = true
  vim.wo[winid].winhl = WINHL_STR
  internal.win_set_autocmds(winid, is_ephemeral)

  local windata = { ---@type msgarea.view.WinData
    bufnr = buf,
    winid = winid,
    title = title,
    inner_height = win_config.height,
    border = win_config.border,
    border_height = internal.get_border_height(win_config.border),
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
    internal.win_set_autocmds(win, is_ephemeral)
  end

  win_config = internal.initial_win_config(buf, win_config)
  local windata = { ---@type msgarea.view.WinData
    bufnr = buf,
    winid = win,
    title = title,
    inner_height = win_config.height,
    border = win_config.border,
    border_height = internal.get_border_height(win_config.border),
  }
  M.state.windows[k] = windata

  nvim_win_set_config(win, win_config)
  M.show({ flush = true, silent = true, curwin = not is_ephemeral and win or nil })
end

local redraw_if_needed = function()
  if
    fn.mode() == "c"
    ---@diagnostic disable-next-line: undefined-field
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
  end)
end

---@param opts? msgarea.view.ShowOpts
M.show = function(opts)
  local state = M.state

  opts = vim.tbl_deep_extend("force", state.refresh_opts, opts or {})
  if not opts.flush then
    schedule_refresh(opts)
    return
  end

  -- NOTE: need to make sure these get cleared before
  -- the potential early return
  state.refresh_pending = false
  state.refresh_opts = {}

  for i = #state.windows, 1, -1 do
    if not api.nvim_win_is_valid(state.windows[i].winid) then
      table.remove(state.windows, i)
    end
  end

  if vim.tbl_isempty(state.windows) then
    if not opts.silent then util.warn("no active windows") end -- TODO: do i need silent?
    if fn.mode() ~= "c" then internal.set_cmdheight(M.original_cmdheight) end
    state.height = nil
    return
  end

  local min_tabs = opts.winbar_min_tabs or config.get().view.winbar_min_tabs
  local N_active = #state.windows
  local winbar_is_showing = N_active >= min_tabs
  local outer_height = opts.height or M.outer_height(winbar_is_showing)
  state.height = outer_height

  local style = opts.style or M.style()
  local eph = state.windows.ephemeral
  local new_cmdheight = opts.cmdheight
                     or (eph and eph.inner_height + eph.border_height + (M.cmp_menu_open() and 1 or 0))
                     or (style == "split" and fn.mode() ~= "c" and M.original_cmdheight)
                     or (style == "msgarea" and state.height)
  if new_cmdheight then internal.set_cmdheight(new_cmdheight) end

  if opts.curwin and internal.key_of(opts.curwin) then
    state.curwin = opts.curwin
  elseif not (state.curwin and api.nvim_win_is_valid(state.curwin)) then
    -- NOTE: this case occurs when focus needs to return to a window not in history...
    -- can increase buffer size or maybe think of a better idea than ring buffer
    state.curwin = state.windows[1] and state.windows[1].winid
  end

  -- all of the win_config logic is in this for loop
  for k, data in pairs(state.windows) do
    local win_cfg
    local winid = data.winid
    if k == "ephemeral" then
      win_cfg = internal.shared_win_cfg()
      win_cfg.hide = false
      local height = new_cmdheight - (M.cmp_menu_open() and 1 or 0) - data.border_height
      win_cfg.height = math.max(1, height)
      win_cfg.border = data.border
    else
      if style == "split" and winid == state.curwin then
        win_cfg = { hide = false, height = state.height, split = "below", win = -1 }
        vim.wo[winid].winfixheight = false
      else
        win_cfg = internal.shared_win_cfg()
        win_cfg.hide = winid ~= state.curwin
        win_cfg.height = state.height - data.border_height
        win_cfg.border = data.border
      end
    end
    -- NOTE: keeping a record of the "actual" height applied to window
    -- so that, on WinResized, can check if window height has been changed
    data.actual_height = win_cfg.height
    api.nvim_win_set_config(winid, win_cfg)
    vim.wo[winid].winbar = data.title and N_active >= min_tabs and WINBAR_STR or ""
  end

  redraw_if_needed()
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
  state.height = nil
  vim.o.cmdheight = M.original_cmdheight
end

---@param opts? msgarea.view.HideOpts
M.hide = function(opts)
  if opts and opts.cmdheight then
    -- TODO: check why internal.set_cmdheight() doesnt work
    -- without manually setting ui2.cmdheight
    -- after 'empty'->'confirm' bug is fixed upstream
    ui2.cmdheight = opts.cmdheight
    internal.set_cmdheight(opts.cmdheight)
  end

  local state = M.state
  if vim.tbl_isempty(state.windows) then return end

  state.refresh_pending = false
  state.refresh_opts = {}
  util.msg_clear()

  -- TODO: revisit this line after
  -- https://github.com/neovim/neovim/issues/42154 fixed
  local height = state.height or M.outer_height()
  local win_cfg = internal.shared_win_cfg()
  for _, data in pairs(state.windows) do
    win_cfg.hide = true
    win_cfg.height = height - data.border_height
    data.actual_height = win_cfg.height
    api.nvim_win_set_config(data.winid, win_cfg)
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

---@return integer
M.outer_height = function(winbar_is_showing)
  -- NOTE: Current idea is to take the maximum height across all active
  -- windows open in the msgarea and use that height for all windows
  -- to prevent "height bouncing" when switching between them.
  local h = M.original_cmdheight
  local state = M.state
  local N_active = #state.windows
  if N_active == 0 then return h end

  if winbar_is_showing == nil then
    winbar_is_showing = N_active >= config.get().view.winbar_min_tabs
  end
  local winbar_h = winbar_is_showing and 1 or 0
  for _, data in ipairs(state.windows) do
    local is_split = M.style() == "split" and data.winid == state.curwin
    local border_h = is_split and 0 or data.border_height
    local outer_h = data.inner_height + border_h + winbar_h
    if not data.resized then outer_h = math.min(outer_h, M.max_height()) end
    h = math.max(h, outer_h)
    -- local outer_h = (data.resize_height or data.inner_height) + data.border_height + winbar_h
    -- if not data.resize_height then outer_h = math.min(outer_h, M.max_height()) end
    -- h = math.max(h, outer_h)
  end

  return math.max(h, M.min_height())
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
  if new_cmdheight then internal.set_cmdheight(new_cmdheight) end
end

M.close_safely = function(winid)
  if winid and api.nvim_win_is_valid(winid) then api.nvim_win_close(winid, true) end
end


-- internal helpers -----------------------------------------------------------

internal.set_cmdheight = function(cmdheight)
  if cmdheight == vim.o.cmdheight then return end
  M.state.setting_cmdheight = true
  vim.o.cmdheight = cmdheight
  M.state.setting_cmdheight = false
end

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

internal.initial_win_config = function(bufnr, opts)
  opts.border = opts.border or "none"
  local border_height = internal.get_border_height(opts.border)

  local outer_height = opts.height
                    or (api.nvim_buf_line_count(bufnr) + border_height)
                    or (1 + border_height)
  if opts.title == nil then
    -- NOTE: max height of ephemeral window is determined by ui2 cmd setting
    outer_height = math.min(outer_height, M.max_height(util.cmd_height()))
  else
    outer_height = math.min(outer_height, M.max_height())
    outer_height = math.max(outer_height, M.min_height())
  end
  local inner_height = outer_height - border_height

  local win_config = vim.tbl_deep_extend("force", opts, internal.shared_win_cfg())
  win_config.border = opts.border
  win_config.height = inner_height
  win_config.hide = true
  win_config.title = nil
  win_config.title_pos = nil
  win_config.split = nil
  return win_config
end

internal.get_border_height = function(b)
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

internal.key_of = function(winid)
  local state = M.state
  for i, win in ipairs(state.windows) do
    if win.winid == winid then return i end
  end
  if (state.windows.ephemeral or {}).winid == winid then
    return "ephemeral"
  end
end

internal.augroup = function(winid)
  return api.nvim_create_augroup("msgarea.nvim-" .. tostring(winid), { clear = false })
end

internal.win_set_autocmds = function(winid, is_ephemeral)
  local on = function(event, opts, cb)
    api.nvim_create_autocmd(event, {
      group = internal.augroup(winid),
      nested = opts.nested,
      buf = opts.buf,
      pattern = opts.pattern and tostring(opts.pattern) or nil,
      callback = function(ev)
        if not (winid and api.nvim_win_is_valid(winid)) then return true end
        cb(ev, winid)
      end
    })
  end
  -- IMPORTANT: needs nested!! this was difficult to diagnose...
  -- but basically, beacuse ui2 depends on OptionSet autocmd to update state,
  -- when this show() is called in this callback, if nested is not true,
  -- the OptionSet autocmd won't fire, which means ui2 state won't update,
  -- which means the the ui2 cmd win rendering is all messed up.
  -- This way, I can flush changes immediately, which means cmdheight
  -- shrinks before an action is taken, so window heights look GOOD.
  on("WinClosed", { nested = true, pattern = winid }, internal.on_win_closed)
  on("WinResized", {}, internal.on_win_resize)
  if is_ephemeral then
    -- NOTE: defer this so that window doesn't immediately close
    -- when cursor moves DUE to ephemeral window opening
    vim.defer_fn(function()
      -- wrapped in pcall because group id can be deleted by the time defer is called
      pcall(on, "CursorMoved", {}, internal.on_cursormove)
    end, 50)
  end
end

internal.on_win_closed = function(_, winid)
  local id = internal.augroup(winid)
  vim.schedule(function() pcall(api.nvim_del_augroup_by_id, id) end)
  local state = M.state
  if state.closing then return end
  local k = internal.key_of(winid)
  if k == nil then return end
  if k == "ephemeral" then
    state.windows[k] = nil
  else
    assert(type(k) == "number")
    table.remove(state.windows, k)
  end
  local curwin = winid == internal.curwin and internal.get_prev_curwin() or nil
  -- FIXME: special case to prevent showing when closing ephemeral
  -- to enter pager. Need to think of a better solution
  if api.nvim_get_current_win() ~= ui2.wins.pager then
    M.show({ flush = true, silent = true, curwin = curwin })
  end
end

internal.on_win_resize = function()
  local needs_refresh = false
  for _, data in pairs(M.state.windows) do
    local winid = data.winid
    local win_was_resized =
      api.nvim_win_is_valid(winid) and api.nvim_win_get_height(winid) ~= data.actual_height
    if win_was_resized then
      -- NOTE: getwininfo() height excludes the winbar, unlike nvim_win_get_height
      data.inner_height = fn.getwininfo(winid)[1].height
      data.resized = true
      needs_refresh = true
    end
  end
  if needs_refresh then M.show({ silent = true }) end
end

internal.on_cursormove = function(_, winid)
  if
    api.nvim_get_current_win() == winid
    or fn.mode() == "c" -- NOTE: fn.mode() == "c" is needed for nvim-0.12
    or M.state.hold_ephemeral
  then
    return
  end
  vim.schedule(function() M.close_safely(winid) end)
end

internal.curwin = nil
internal.history_ring = { idx = 0, size = 50 }
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
---@field inner_height integer
---@field border_height integer
---@field actual_height? integer
---@field resized? boolean
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
