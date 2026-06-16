local api = vim.api
local ui2 = require("vim._core.ui2")

local M = {
  original_cmdheight = vim.o.cmdheight,
  state = {
    active_windows = {},
    current_height = vim.o.cmdheight,
  }
}

local _focused_winid
local _focused_history_ring = {}
local _RING_SIZE = 20
local _ring_idx = 0
local function _set_focus_and_add_to_history_ring(winid)
  -- IMPORTANT: set _focused_winid even when winid is nil
  -- otherwise M.state.focused will have invalid winid
  _focused_winid = winid
  if not winid then return end
  _ring_idx = _ring_idx + 1
  _ring_idx = ((_ring_idx - 1) % _RING_SIZE) + 1 -- clamp _rind_idx to 1.._RING_SIZE
  _focused_history_ring[_ring_idx] = winid
end
M.state.ring = _focused_history_ring
setmetatable(M.state, {
  __index = function(t, k)
    if k == "focused" then
      return _focused_winid
    else
      return rawget(t, k)
    end
  end,
  __newindex = function(t, k, v)
    if k ~= "focused" then
      rawset(t, k, v)
      return
    end
    if v == _focused_history_ring[_ring_idx] then return end
    _set_focus_and_add_to_history_ring(v)
  end,
})

---@return integer? window-ID of last focused win in msgarea
M.get_last_focused = function()
  local i = _ring_idx
  -- idea here is to walk backwards from current position
  -- in history ring until we find a valid winid
  for _ = 1, _RING_SIZE do
    -- NOTE: add _RING_SIZE before mod to ensure nonnegative value
    -- e.g. if _rind_idx = 5 and _RING_SIZE = 20,
    -- then walking backwards 20 steps will walk into negative values,
    -- so we make 5 -> 25 first
    i = (i + _RING_SIZE - 2) % _RING_SIZE + 1 -- NOTE: add 1 for lua indexing
    local winid = _focused_history_ring[i]
    if
      winid ~= nil
      and api.nvim_win_is_valid(winid)
      and winid ~= _focused_winid
    then
      return winid
    end
  end
end

---compute max height based on vim.g.msgarea_max_height
---@return integer
M.max_height = function()
  local h = vim.g.msgarea_max_height or 12
  if h > 0 and h < 1 then
    h = math.floor(h * vim.o.lines)
  end
  return h
end

---compute min height based on vim.g.msgarea_min_height
---@return integer
M.min_height = function()
  local h = vim.g.msgarea_min_height or 3
  if h > 0 and h < 1 then
    h = math.floor(h * vim.o.lines)
  end
  return h
end

---Current idea is to take the maximum height across all active windows
---open in the msgarea and use that height for all windows to prevent
---"height bouncing" when switching between them.
---@return integer height clamped to vim.g.msgarea_min_height < h < vim.g.msgarea_max_height
M.height = function()
  local h = 0
  if #M.state.active_windows == 0 then return h end
  for _, win in ipairs(M.state.active_windows) do
    h = math.max(h, win.height + win.border_height)
  end
  return math.max(math.min(h, M.max_height()), M.min_height())
end

M.open_win = function(nvim_open_win, buf, enter, opts)
  opts = opts or {}

  -- opts.border = opts.border or { "▔", "▔", "▔", "", "", "", "", "" }
  opts.border = opts.border or "none"
  local border_height = 0
  local b = opts.border
  if type(b) == "table" then
    if b[2] ~= "" then border_height = border_height + 1 end
    if b[6] ~= "" then border_height = border_height + 1 end
  elseif type(b) == "string" and b ~= "none" then
    border_height = border_height + 2
  end

  local height = opts.height or 0
  height = math.min(height, M.max_height())
  height = math.max(height, M.min_height())
  height = height - border_height
  local title = opts.title

  local cmd_win = ui2.wins.cmd
  opts = vim.tbl_deep_extend("force", opts, {
    hide = true,
    anchor = "SW",
    relative = "editor",
    row = vim.o.lines,
    col = 0,
    width = vim.o.columns,
    win = cmd_win,
    height = height,
    zindex = api.nvim_win_get_config(cmd_win).zindex + 1,
  })
  opts.split = nil
  opts.title = nil
  opts.title_pos = nil

  local winid = nvim_open_win(buf, enter, opts)
  M.state.active_windows[#M.state.active_windows + 1] = {
    bufnr = buf,
    winid = winid,
    title = title,
    height = height,
    border_height = border_height,
  }
  vim.wo[winid].winhl = "WinBar:MsgArea,NormalFloat:MsgArea," .. vim.wo[winid].winhl
  vim.wo[winid].winbar =
    title == nil and ""
    or "%{%v:lua.require'msgarea.winbar'.render()%}"

  local on = function(event, cb)
    api.nvim_create_autocmd(event, {
      pattern = tostring(winid),
      callback = function(...)
        if not (winid and api.nvim_win_is_valid(winid)) then return true end
        cb(...)
      end
    })
  end

  on("WinClosed", function()
    local idx
    for i, win in ipairs(M.state.active_windows) do
      if win.winid == winid then
        idx = i
        break
      end
    end
    if idx == nil then return end
    -- NOTE: this is very inefficient when closing multiple windows in a single call
    -- due to excessively shifting elements, but shouldn't matter with such small `n`.
    -- Maybe look into better removal strategy...
    table.remove(M.state.active_windows, idx)

    if winid == _focused_winid then
      -- if closing the currently focused window we want to
      -- focus the last focused from history ring buffer
      M.state.focused = M.get_last_focused()
      M.show({ silent = true })
    end

    -- api.nvim__redraw({ win = _focused_winid, winbar = true })
    vim.schedule(function()
      if #M.state.active_windows == 0 then
        vim.o.cmdheight = M.original_cmdheight
      else
        M.show({ silent = true })
      end
    end)
  end)

  on("WinResized", function(ev)
    -- vim.print(ev)
  end)

  -- the idea here is that I open every window with `hide=true` and then update
  -- state to focus this window. `show()` handles cmdheight and window show/hide logic
  M.state.focused = winid
  M.show({ silent = true })
  return winid
end

local function warn(msg)
  local chunks = {
    { "[WARN]", "DiagnosticWarn" },
    { " msgarea.nvim: " .. msg, nil },
  }
  api.nvim_echo(chunks, true, {})
end

M.show = function(opts)
  local state = M.state

  -- vim.cmd.mode() -- this is just to clear leftover text in cmdline
  vim.o.cmdheight = M.height()
  state.current_height = vim.o.cmdheight

  opts = opts or {}
  opts.silent = opts.silent or false
  -- TODO: maybe add opts.winid / opts.title to show with specific window focused

  if #state.active_windows == 0 then
    if not opts.silent then warn("no active windows") end return
  end

  -- NOTE: this case occurs when focus needs to return to a window not in history...
  -- can increase buffer size or maybe think of a better idea than ring buffer
  if state.focused == nil then
    state.focused = state.active_windows[1].winid
  end

  for _, win in ipairs(state.active_windows) do
    api.nvim_win_set_config(win.winid, { hide = win.winid ~= state.focused })
  end
end

M.hide = function()
  local active_windows = M.state.active_windows
  for _, win in ipairs(active_windows) do
    api.nvim_win_set_config(win.winid, { hide = true })
  end
  -- FIXME: return early if in cmdline because this is called in CmdlineEnter autocmd
  -- and I don't want cmdheight to close in this case...
  -- works for now but need to think of a better way to do this
  if vim.fn.mode() == "c" then return end
  vim.o.cmdheight = M.original_cmdheight
end

M.close_all = function()
  -- NOTE: interesting bug if you don't deepcopy this.
  -- Because elements are removed from active_windows in WinClosed
  -- autocmd, active_windows is shifted every time a window is closed,
  -- which means by the time ipairs gets to an index, the element may not
  -- exist anymore in that index
  local active_windows = vim.deepcopy(M.state.active_windows)
  for _, win in ipairs(active_windows) do
    api.nvim_win_close(win.winid, true)
  end
  vim.o.cmdheight = M.original_cmdheight
end

return M
