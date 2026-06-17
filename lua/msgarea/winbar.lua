local msgarea = require("msgarea")

local M = {}

local function with_click(text, winid)
  return "%" .. winid .. "@v:lua.require'msgarea.winbar'.on_click" .. "@" .. text .. "%X"
end

local function with_hl(text, hl)
  return "%#" .. hl .. "#" .. text
end

M.render = function()
  local state = msgarea.state
  local winbar_str = table.concat(vim
    .iter(state.active_windows)
    :map(function(win)
      if not win.title then return end
      local hl = win.winid == state.focused and "TabLineSel" or "TabLine"
      local text = vim.trim(win.title)
      text = with_hl(" " .. text .. " ", hl)
      return with_click(text, win.winid)
    end)
    :totable())
  return winbar_str .. "%*"
end

-- args: minwid, clicks, button, modifiers
M.on_click = function(minwid, _, button, _)
  -- NOTE: using arg passed to click handler to get winid instead of
  -- vim.api.nvim_get_current_win() since that uses the cursor window,
  -- not the clicked window
  local winid = minwid
  if button == "l" then
    msgarea.state.focused = winid
    msgarea.show({ silent = true })
  elseif button == "r" then
    vim.api.nvim_win_close(winid, true)
  end
end

return M
