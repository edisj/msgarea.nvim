local view = require("msgarea.view")
local config = require("msgarea.config")
local M = {}

local function with_click(text, winid)
  return "%" .. winid .. "@v:lua.require'msgarea.winbar'.on_click" .. "@" .. text .. "%X"
end

local function with_hl(text, hl)
  return "%#" .. hl .. "#" .. text
end

M.render = function()
  local state = view.state
  local sep = config.get().view.winbar_separator
  local winbar_str = table.concat(vim
    .iter(ipairs(state.windows))
    :map(function(_, win)
      if not win.title then return end
      local hl = win.winid == state.focused and "MsgAreaWinBarSel" or "MsgAreaWinBarFill"
      local text = with_hl(win.title, hl)
      return with_click(text, win.winid)
    end)
    :totable(), with_hl(sep, "MsgAreaWinBarSep"))
  local pos = config.get().view.winbar_pos
  return pos == "left"   and winbar_str .. "%*"
      or pos == "right"  and "%=" .. winbar_str .. "%*"
      or pos == "center" and "%=" .. winbar_str .. "%*%="
      or winbar_str
end

-- args: minwid, clicks, button, modifiers
M.on_click = function(minwid, _, button, _)
  -- NOTE: using arg passed to click handler to get winid instead of
  -- vim.api.nvim_get_current_win() since that uses the cursor window,
  -- not the clicked window
  local winid = minwid
  if button == "l" then
    view.show({ silent = true, focused = winid })
  elseif button == "r" then
    vim.api.nvim_win_close(winid, true)
  end
end

return M
