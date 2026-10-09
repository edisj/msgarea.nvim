local api, fn = vim.api, vim.fn
local ui2 = require("vim._core.ui2")
local config = require("msgarea.config")
local util = require("msgarea.util")
local orig = require("msgarea.setup.runtime_patches").original

local internal = {}
local M = {
  original_cmdheight = vim.o.cmdheight, ---@type integer
  state = {
    windows = {
      ephemeral = nil ---@type msgarea.view.WinData
    },
    height = nil, ---@type integer
    hold_ephemeral = false, ---@type boolean
    hold_resize = false, ---@type boolean
    hold_swap = false, ---@type boolean
    overflow_stack = {}, ---@type integer[]
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
      if v == internal.curwin then return end
      internal.set_curwin_and_add_to_history_ring(v)
    else
      rawset(t, k, v)
    end
  end,
})

local WIN_ERROR = 0
local WINHL_STR = "WinBar:MsgAreaWinBar,WinBarNC:MsgAreaWinBar,FloatBorder:MsgArea,NormalFloat:MsgArea,Normal:MsgArea"
local WINBAR_STR = "%{%v:lua.require'msgarea.winbar'.render()%}"

M.open_win = function(buf, enter, opts)
  opts = opts or {}
  assert(opts.relative == "msgarea")
  local win_kind = M.win_resolve_kind(nil, opts.title)
  return M._open_win(buf, enter, opts, win_kind, false)
end

M.win_set_config = function(win, win_config)
  assert(win_config.relative == "msgarea")
  local win_kind = M.win_resolve_kind(win, win_config.title)
  M._win_set_config(win, win_config, win_kind)
end

M._open_win = function(buf, enter, opts, win_kind, reuse_win)
  if reuse_win then
    local data = M.buf_get_data(buf)
    if data then
      M._win_set_config(data.winid, opts, win_kind)
      if enter then api.nvim_set_current_win(data.winid) end
      return data.winid
    end
  end

  -- The key idea here is that every window is opened as a hidden float,
  -- where the cmdheight and which window is shown is handled in `M.show()`
  local win_config = internal.initial_win_config(buf, opts)
  local winid = orig.nvim_open_win(buf, enter, win_config)
  if winid == WIN_ERROR then return WIN_ERROR end

  if win_kind == "ephemeral" then
    M.state.hold_swap = true
    M.ephemeral_close()
    M.state.hold_swap = false
  end

  internal.state_append_data {
    bufnr = buf,
    winid = winid,
    title = opts.title,
    win_cfg = win_config,
    kind = win_kind,
  }

  util.cmd_clear()
  M.show({ silent = true, curwin = win_kind ~= "ephemeral" and winid or nil })
  return winid
end

M._win_set_config = function(win, win_config, win_kind)
  if not internal.win_valid(win) then return end

  local title = win_config.title
  local bufnr = api.nvim_win_get_buf(win)
  win_config = internal.initial_win_config(bufnr, win_config)
  win_config.noautocmd = nil

  local cur_key = internal.win_get_key(win)
  if cur_key == nil then -- means this is a new window not already in state
    internal.state_append_data {
      bufnr = bufnr,
      winid = win,
      title = title,
      win_cfg = win_config,
      kind = win_kind,
    }
  else
    local is_ephemeral = cur_key == "ephemeral"
    local want_ephemeral = win_kind == "ephemeral"
    local needs_shuffle = is_ephemeral ~= want_ephemeral
    if needs_shuffle then internal.state_shuffle_win(win, want_ephemeral) end
    internal.state_update_data {
      winid = win,
      title = title,
      win_cfg = win_config,
      kind = win_kind,
    }
  end

  orig.nvim_win_set_config(win, win_config)
  M.show({ silent = true, curwin = win_kind ~= "ephemeral" and win or nil })
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

  local key_of_curwin = opts.curwin and internal.win_get_key(opts.curwin)
  if key_of_curwin and key_of_curwin ~= "ephemeral" then
    state.curwin = opts.curwin
  elseif type(internal.win_get_key(state.curwin)) ~= "number" then
    -- NOTE: this case occurs when focus needs to return to a window not in history...
    -- can increase buffer size or maybe think of a better idea than ring buffer
    state.curwin = state.windows[1] and state.windows[1].winid
  end

  local min_tabs = opts.winbar_min_tabs or config.get().view.winbar_min_tabs
  local N_active = #state.windows
  local winbar_is_showing = N_active >= min_tabs
  local outer_height = opts.height or internal.view_get_height(winbar_is_showing)
  state.height = outer_height

  local style = opts.style or M.style()
  local cmdline_height = internal.is_cmp_open() and 1 or 0
  local eph = state.windows.ephemeral
  local new_cmdheight = opts.cmdheight
                     or (eph and eph.inner_height + eph.border_height + cmdline_height)
                     or (style == "split" and fn.mode() ~= "c" and M.original_cmdheight)
                     or (style == "msgarea" and state.height)
  if new_cmdheight then
    if style == "split" and eph then
      local min_h = cmdline_height + 1
      local max_h = not eph.resized and internal.view_resolve_max_height(util.cmd_height()) or nil
      new_cmdheight = internal.clamp_height(new_cmdheight, min_h, max_h)
    end
    internal.set_cmdheight(new_cmdheight)
  end

  -- NOTE: ALL of the win_config logic is in this loop!
  for k, data in pairs(state.windows) do
    local win_cfg, is_split
    local winid = data.winid
    if k == "ephemeral" then
      win_cfg = internal.get_mandatory_win_cfg()
      win_cfg.hide = false
      local height = new_cmdheight - cmdline_height - data.border_height
      win_cfg.height = internal.clamp_height(height, 1)
      win_cfg.border = data.border
    else
      if style == "split" and winid == state.curwin then
        win_cfg = { hide = false, height = state.height, split = "below", win = -1 }
        is_split = true
        -- NOTE: this is kinda necessary... For very large view heights, when
        -- an ephemeral window in cmdline expands, if winfixheight is not false
        -- on the window in the split view, all sorts of E36 "No More Room"
        -- errors are thrown.
        vim.wo[winid].winfixheight = false
      else
        win_cfg = internal.get_mandatory_win_cfg()
        win_cfg.hide = winid ~= state.curwin
        win_cfg.height = state.height - data.border_height
        win_cfg.border = data.border
      end
    end
    -- explicitly handle E36 out of room errors
    local ok, err = pcall(api.nvim_win_set_config, winid, win_cfg)
    while not ok and is_split and err and err:match("^Vim:E36") and win_cfg.height > 1 do
      win_cfg.height = math.floor(win_cfg.height / 2)
      ok, err = pcall(api.nvim_win_set_config, winid, win_cfg)
    end
    -- NOTE: keeping a record of the "actual" height applied to window so that, on
    -- WinResized, can check if window height has been changed. Must be after
    -- set_cmdheight, because heights can change when splits resized too to overflow
    if ok then data.actual_height = win_cfg.height end
    vim.wo[winid].winbar = data.kind ~= "ephemeral" and data.title and N_active >= min_tabs and WINBAR_STR or ""
  end

  redraw_if_needed()
end

M.close_all = function()
  local state = M.state
  state.closing = true
  for _, data in pairs(M.get_state().windows) do
    M.win_close_safely(data.winid)
  end
  state.curwin = nil
  state.windows = {}
  state.overflow_stack = {}
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
    -- ui2.cmdheight = opts.cmdheight
    internal.set_cmdheight(opts.cmdheight)
  end

  local state = M.state
  if vim.tbl_isempty(state.windows) then return end

  state.refresh_pending = false
  state.refresh_opts = {}
  util.msg_clear()

  -- TODO: revisit this line after
  -- https://github.com/neovim/neovim/issues/42154 fixed
  local height = state.height or internal.view_get_height()
  local win_cfg = internal.get_mandatory_win_cfg()
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

---@param winid? integer
---@param title? string
---@return "ephemeral"|"persistent"|"overflow"
M.win_resolve_kind = function(winid, title)
  if title ~= nil then
    return "persistent"
  else
    local eph = M.state.windows.ephemeral
    if eph
      and eph.winid ~= winid
      and api.nvim_win_is_valid(eph.winid)
      and M.ephemeral_is_focused()
    then
      return "overflow"
    else
      return "ephemeral"
    end
  end
end

---@param winid integer
---@return msgarea.view.WinData?
M.win_get_data = function(winid)
  local key = internal.win_get_key(winid)
  return M.state.windows[key]
end

---@param bufnr integer
---@return msgarea.view.WinData?
M.buf_get_data = function(bufnr)
  local eph = M.state.windows.ephemeral
  if eph and eph.bufnr == bufnr then return eph end
  for _, data in ipairs(M.state.windows) do
    if bufnr == data.bufnr then return data end
  end
end

---@param winid integer
M.win_close_safely = function(winid)
  if internal.win_valid(winid) then api.nvim_win_close(winid, true) end
end

---Whether an ephemeral window is currently focused.
---Currently treating in cmdline as in ephemeral
---@return boolean
M.ephemeral_is_focused = function()
  local eph = M.state.windows.ephemeral
  return eph and eph.winid == api.nvim_get_current_win() or fn.mode() == "c"
end

M.ephemeral_close = function(new_cmdheight)
  M.win_close_safely((M.state.windows.ephemeral or {}).winid)
  if new_cmdheight then internal.set_cmdheight(new_cmdheight) end
end


-- internal helpers -----------------------------------------------------------

internal.state_append_data = function(data)
  ---@type msgarea.view.WinData
  local windata = {
    bufnr = data.bufnr,
    winid = data.winid,
    title = data.title,
    inner_height = data.win_cfg.height,
    border = data.win_cfg.border,
    border_height = internal.get_border_height(data.win_cfg.border),
    kind = data.kind,
  }
  local key = windata.kind == "ephemeral" and "ephemeral" or #M.state.windows + 1
  M.state.windows[key] = windata
  vim.wo[windata.winid].winhl = WINHL_STR
  vim.wo[windata.winid].winfixheight = true
  internal.win_set_autocmds(windata.winid, windata.kind)
  if windata.kind == "overflow" then
    internal.overflow_stack_push_win(windata.winid)
    internal.ensure_title(windata)
  end
end

internal.state_update_data = function(new_data)
  local data = M.win_get_data(new_data.winid)
  if not data then return end

  if new_data.kind and new_data.kind ~= data.kind then
    data.kind = new_data.kind
    internal.win_set_autocmds(data.winid, data.kind)
    if data.kind == "overflow" then
      internal.overflow_stack_push_win(data.winid)
    else
      internal.overflow_stack_remove_win(data.winid)
    end
  end
  if new_data.win_cfg then
    data.title = new_data.title
    data.border = new_data.win_cfg.border
    data.border_height = internal.get_border_height(new_data.win_cfg.border)
    -- TODO: this doesnt seem right
    if not data.resized then data.inner_height = new_data.win_cfg.height end
  end
  if data.kind == "overflow" then internal.ensure_title(data) end
end

internal.state_shuffle_win = function(winid, to_ephemeral)
  local state = M.state
  local cur_key = internal.win_get_key(winid)
  if to_ephemeral then
    assert(type(cur_key) == "number")
    state.hold_swap = true
    M.ephemeral_close()
    state.hold_swap = false
    state.windows.ephemeral = table.remove(state.windows, cur_key)
  else
    assert(cur_key == "ephemeral")
    state.windows[#state.windows + 1] = state.windows.ephemeral
    state.windows.ephemeral = nil
  end
end

internal.ensure_title = function(data)
  if not (data and data.kind == "overflow" and data.title == nil) then
    return
  end
  local name = fn.fnamemodify(api.nvim_buf_get_name(data.bufnr), ":t")
  data.title = (" %s "):format(name)
end

internal.overflow_stack_push_win = function(winid)
  -- NOTE: remove existing stack entry with same winid
  -- not sure about this... but it seems like a thing i want to do
  internal.overflow_stack_remove_win(winid)
  table.insert(M.state.overflow_stack, winid)
end

internal.overflow_stack_pop_win = function()
  local stack = M.state.overflow_stack
  local curwin = api.nvim_get_current_win()
  -- NOTE: explain why trying remove_win first
  local winid = internal.overflow_stack_remove_win(curwin)
  return winid or table.remove(stack)
end

internal.overflow_stack_remove_win = function(winid)
  local stack = M.state.overflow_stack
  for i = #stack, 1, -1 do
    if stack[i] == winid then return table.remove(stack, i) end
  end
end

internal.set_cmdheight = function(cmdheight)
  ui2.cmdheight = cmdheight
  if cmdheight == vim.o.cmdheight then return end
  M.state.setting_cmdheight = true
  vim.o.cmdheight = cmdheight
  M.state.setting_cmdheight = false
end

internal.is_cmp_open = function()
  local eph = M.state.windows.ephemeral
  if not (eph and api.nvim_buf_is_valid(eph.bufnr)) then return false end
  local ft = api.nvim_get_option_value("filetype", { buf = eph.bufnr })
  return eph and (ft == "blink-cmp-menu" or ft == "native-cmp-menu")
end

---@return integer
internal.view_get_height = function(winbar_is_showing)
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
    local max_h = not data.resized and internal.view_resolve_max_height() or nil
    -- NOTE: need to check for data.title here
    -- because an overflow ephemeral won't have a title when moved to view
    local outer_h = data.inner_height + border_h + (data.title and winbar_h or 0)
    outer_h = internal.clamp_height(outer_h, nil, max_h)
    h = math.max(h, outer_h)
  end

  return internal.clamp_height(h, internal.view_resolve_min_height())
end

---Compute max height based on `config.view.max_height`.
---@return integer
internal.view_resolve_max_height = function(max)
  max = max or config.get().view.max_height
  if max > 0 and max < 1 then
    max = math.floor(max * vim.o.lines)
  end
  return max
end

---Compute min height based on `config.view.min_height`.
---@return integer
internal.view_resolve_min_height = function(min)
  min = min or config.get().view.min_height
  if min > 0 and min < 1 then
    min = math.floor(min * vim.o.lines)
  end
  return min
end

internal.clamp_height = function(h, min, max)
  if max then h = math.min(h, max) end
  if min then h = math.max(h, min) end
  return h
end

internal.get_mandatory_win_cfg = function()
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

  local min = internal.view_resolve_min_height()
  local max = internal.view_resolve_max_height(opts.title == nil and util.cmd_height() or nil)
  local outer_height = opts.height
                    or (api.nvim_buf_line_count(bufnr) + border_height)
                    or (1 + border_height)
  outer_height = internal.clamp_height(outer_height, min, max)
  local inner_height = outer_height - border_height

  local win_config = vim.tbl_deep_extend("force", opts, internal.get_mandatory_win_cfg())
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

internal.win_get_key = function(winid)
  local state = M.state
  for i, win in ipairs(state.windows) do
    if win.winid == winid then return i end
  end
  if state.windows.ephemeral and state.windows.ephemeral.winid == winid then
    return "ephemeral"
  end
  return nil
end

internal.win_valid = function(winid)
  return winid and api.nvim_win_is_valid(winid)
end

internal.win_get_augroup_name = function(winid)
  return ("msgarea.nvim-%s"):format(winid)
end

internal.win_get_augroup_id = function(winid)
  local name = internal.win_get_augroup_name(winid)
  return api.nvim_create_augroup(name, { clear = true })
end

internal.win_del_augroup = function(winid)
  local name = internal.win_get_augroup_name(winid)
  pcall(api.nvim_del_augroup_by_name, name)
end

internal.win_set_autocmds = function(winid, win_kind)
  local id = internal.win_get_augroup_id(winid)
  local on = function(event, opts, cb)
    -- IMPORTANT: needs nested!! this was difficult to diagnose...
    -- but basically, beacuse ui2 depends on OptionSet autocmd to update state,
    -- when this show() is called in this callback, if nested is not true,
    -- the OptionSet autocmd won't fire, which means ui2 state won't update,
    -- which means the the ui2 cmd win rendering is all messed up.
    -- This way, I can flush changes immediately, which means cmdheight
    -- shrinks before an action is taken, so window heights look GOOD.
    api.nvim_create_autocmd(event, {
      group = id,
      nested = true,
      pattern = opts.pattern and tostring(opts.pattern) or nil,
      callback = function(ev)
        if not internal.win_valid(winid) then return true end
        cb(ev, winid)
      end
    })
  end
  on("WinClosed", { pattern = winid }, internal.on_win_closed)
  on("WinResized", {}, internal.on_win_resize)
  if win_kind ~= "persistent" then
    -- NOTE: defer this so that window doesn't immediately close
    -- when cursor moves DUE to ephemeral window opening
    vim.defer_fn(function()
      local data = M.win_get_data(winid)
      if not internal.win_valid(winid) or not data or data.kind == "persistent" then return end
      -- wrapped in pcall because group id can be deleted by the time defer is called
      pcall(on, "CursorMoved", {}, internal.on_cursor_moved)
    end, 50)
  end
end

internal.on_win_closed = function(_, winid)
  vim.schedule(function() internal.win_del_augroup(winid) end)
  local state = M.state
  -- TODO: should hold_swap be placed somewhere else?
  -- maybe in the k == "ephemeral" block?
  if state.closing or state.hold_swap then return end
  internal.overflow_stack_remove_win(winid)
  local k = internal.win_get_key(winid)
  if k == nil then return end
  if k == "ephemeral" then
    local overflow_winid = fn.mode() ~= "c" and internal.overflow_stack_pop_win()
    local overflow_key = overflow_winid and internal.win_get_key(overflow_winid)
    local overflow_data = overflow_key
      and type(overflow_key) == "number"
      and table.remove(state.windows, overflow_key)
    if overflow_data then
      state.windows[k] = overflow_data
      internal.state_update_data { winid = overflow_winid, kind = "ephemeral" }
    else
      state.windows[k] = nil
    end
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
  if M.state.hold_resize then return end
  local needs_refresh = false
  for _, data in pairs(M.state.windows) do
    local winid = data.winid
    local height = api.nvim_win_get_height(winid)
    local win_was_resized =
      api.nvim_win_is_valid(winid) and height ~= data.actual_height
    if win_was_resized then
      local winbar_h = api.nvim_get_option_value("winbar", { win = winid, scope = "local" }) == "" and 0 or 1
      local inner_height = height - winbar_h
      -- HACK: the idea here is that I want to clamp ephemeral height when it's resized
      -- by things like Neogit, BUT I don't want to clamp it when you resize the window
      -- your mouse by holding the statusline. This seems to be a way you can distinguish the two.
      local resized_with_mouse_drag = height + data.border_height == vim.o.cmdheight
      if data.kind == "ephemeral" and not resized_with_mouse_drag then
        local max_eph_height = internal.view_resolve_max_height(util.cmd_height()) - data.border_height
        inner_height = internal.clamp_height(inner_height, nil, max_eph_height)
      end
      data.inner_height = inner_height
      data.resized = true
      needs_refresh = true
    end
  end
  if needs_refresh then M.show({ flush = true, silent = true }) end
end

internal.on_cursor_moved = function(_, winid)
  local curwin = api.nvim_get_current_win()
  if
    curwin == winid
    or fn.mode() == "c"
    or M.state.hold_ephemeral
  then
    return
  end
   vim.schedule(function() M.win_close_safely(winid) end)
 end

-- NOTE: this is a different (currently unused) version of cursormoved where
-- the overflow windows are NOT closed as long as focus is on ephemeral OR overflow.
-- Not sure which I like better yet... I can see a potential future usecase where
-- you deliberately use the "overflow while in ephemeral" behavior to open
-- sub-menus while in an ephemeral menu, so I need some time to think about this
-- and find a valid, real-world usecase. No harm in keeping this here for now...
internal.__on_cursor_moved = function(_, winid)
  local curwin = api.nvim_get_current_win()
  if
    curwin == winid
    or M.ephemeral_is_focused()
    or M.state.hold_ephemeral
  then
    return
  end
  local windata = M.win_get_data(winid)
  if windata and windata.kind == "overflow" and internal.win_get_key(curwin) ~= nil then
    return
  end
   vim.schedule(function() M.win_close_safely(winid) end)
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

---@alias msgarea.view.StateKey "ephemeral" | integer

---@alias msgarea.view.WinKind "persistent" | "ephemeral" | "overflow"

---@class (exact) msgarea.view.WinData
---@field bufnr integer
---@field winid integer
---@field title? string
---@field inner_height integer
---@field border_height integer
---@field kind msgarea.view.WinKind
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
