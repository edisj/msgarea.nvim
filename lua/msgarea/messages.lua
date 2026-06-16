local api = vim.api
local msgarea = require("msgarea")
local ui = require("vim._core.ui2")

local M = {}

local _buf
local ensure_buf = function()
  if _buf and api.nvim_buf_is_valid(_buf) then return _buf end

  _buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(_buf, "[MsgArea]")
  api.nvim_set_option_value("modifiable", false, { buf = _buf })
  vim.keymap.set("n", "q", function()
    local win = api.nvim_get_current_win()
    api.nvim_win_close(win, true)
  end, { buf = _buf })

  return _buf
end

local _win
local ensure_win = function()
  local buf = ensure_buf()
  local height = api.nvim_buf_line_count(buf)
  height = math.min(height, msgarea.max_height())

  if _win and api.nvim_win_is_valid(_win) then
    for _, win in ipairs(msgarea.state.active_windows) do
      if win.winid == _win then
        win.height = height
        break
      end
    end
  else
    _win = api.nvim_open_win(buf, false, {
      ---@diagnostic disable-next-line: assign-type-mismatch
      relative = "msgarea",
      style = "minimal",
      title = " Messages ",
      height = height,
    })
    api.nvim_set_option_value("winfixbuf", true, { win = _win })
  end

  return _win
end

M.show_msg = function(content)
  local _lines = {}
  local _extmarks_to_apply = {}

  local start_col = 0
  local i = 1
  for _, chunk in ipairs(content) do
    local text, hl_id = chunk[2], chunk[3]
    local lines_in_chunk = vim.split(text, "\n")

    local text_before_newline = lines_in_chunk[1]
    _lines[i] = (_lines[i] or "") .. text_before_newline
    if hl_id ~= 0 then
      _extmarks_to_apply[#_extmarks_to_apply + 1] = {
        row = i - 1,
        start_col = start_col,
        end_col = start_col + #text_before_newline,
        hl_id = hl_id
      }
    end

    start_col = start_col + #text_before_newline

    for j = 2, #lines_in_chunk do
      i = i + 1
      start_col = 0
      local line = lines_in_chunk[j]
      _lines[i] = (_lines[i] or "") .. line
      if hl_id ~= 0 then
        _extmarks_to_apply[#_extmarks_to_apply + 1] = {
          row = i - 1,
          start_col = start_col,
          end_col = start_col + #line,
          hl_id = hl_id
        }
      end
      start_col = start_col + #line
    end

  end

  local buf = ensure_buf()
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, _lines)
  vim.bo[buf].modifiable = false

  local ns = api.nvim_create_namespace("msgarea.messages")
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, extmark in ipairs(_extmarks_to_apply) do
    api.nvim_buf_set_extmark(buf, ns, extmark.row, extmark.start_col, {
      end_col = extmark.end_col,
      hl_group = extmark.hl_id,
    })
  end

  msgarea.state.focused = ensure_win()
  msgarea.show({ silent = true })
end

-- function M.msg_show(kind, content, replace_last, _, append, id, trigger)
M.msg_show = function(msg_show, kind, content, replace_last, _,  append, id, trigger)
  -- Match configured target mappings as Lua pattern to ID:
  local k, v, id_target = next(type(id) == "string" and ui.cfg.msg.targets or {})
  while k and not id_target do
    id_target = id:match(k) and v
    k, v = next(ui.cfg.msg.targets, k)
  end

  local in_pager = vim.bo[api.nvim_get_current_buf()].filetype == "pager"
  -- Set the entered search command in the cmdline (if available).
  local tgt = kind == "search_cmd" and "cmd"
    -- When the pager is open always route typed commands there. This better simulates
    -- the UI1 behavior after opening the cmdline below a previous multiline message,
    -- and seems useful enough even when the pager was entered manually.
    or (trigger == "typed_cmd" and in_pager and vim.fn.getcmdwintype() == "") and "pager"
    -- Otherwise route to configured target:
    or (trigger ~= "" and ui.cfg.msg.targets[trigger])
    or id_target
    or (kind ~= "" and ui.cfg.msg.targets[kind])
    or ui.cfg.msg.targets.default

  if tgt ~= "msgarea" then
    -- fallback to original msg_show for all other targets
    msg_show(kind, content, replace_last, _,  append, id, trigger)
  else
    M.show_msg(content)
  end
end

local _set_pos = ui.msg.set_pos
M.set_pos = function(tgt)
  if
    tgt == "pager"
    and _win ~= nil
    and api.nvim_win_is_valid(_win)
  then
    api.nvim_win_close(_win, true)
    -- NOTE: this is schedule to eliminate the "flickering" effect
    -- when closing msgarea messages window and opening pager in same redraw
    -- vim.schedule(function() _set_pos(tgt) end)
  -- else
  end
  _set_pos(tgt)
end
ui.msg.set_pos = function(tgt)
  if vim.g.msgarea_enabled then
    M.set_pos(tgt)
  else
    _set_pos(tgt)
  end
end

return M
