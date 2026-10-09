local api = vim.api
local view = require("msgarea.view")
local config = require("msgarea.config")
local util = require("msgarea.util")
local orig = require("msgarea.setup.runtime_patches").original

local M = {
  msg_expanded = false,
  ns = api.nvim_create_namespace("msgarea.messages"),
  state = {
    bufnr = nil, ---@type integer
    current_batch = {}, ---@type table<string, integer> kind -> bufnr
    overflow = {}, ---@type table<string, integer> kind -> bufnr
  },
}

local internal = {}

---Monkey-patched require("vim._core.ui2.messages").expand_msg(...)
M.expand_msg = function(src, tgt, focus)
  M.msg_expanded = src == "msg" and tgt == nil
  orig.expand_msg(src, tgt, focus)
end

---Monkey-patched require("vim._core.ui2.messages").set_pos(...)
M.set_pos = function(tgt, focus)
  if tgt == "pager" then
    view.ephemeral_close()
    view.hide({ cmdheight = view.original_cmdheight })
    util.msg_clear()
  end
  orig.set_pos(tgt, focus)
end

---Monkey-patched require("vim._core.ui2.messages").show_msg(...)
M.show_msg = function(tgt, kind, content, replace_last, append, id)
  if tgt ~= "msgarea" then
    orig.show_msg(tgt, kind, content, replace_last, append, id)
    return
  end

  local message_title = config.get().message_title
  local title = type(message_title) == "string" and message_title or message_title(kind)
  local win_kind = view.win_resolve_kind(nil, title)
  if win_kind == "ephemeral" and view.ephemeral_is_focused() then
    win_kind = "overflow"
  end
  local bufnr, set_wo
  if type(content) == "number" and api.nvim_buf_is_valid(content) then
    -- content is ready-to-go buffer so just show it as is
    bufnr = content
  else -- content is MsgContent[] text chunks so we create the buffer ourselves
    local force_append
    bufnr, force_append = internal.get_bufnr_for_kind(win_kind, kind)
    internal.buf_set_content(bufnr, content, append or force_append)
    set_wo = true
  end

  local win_cfg = {
    height = api.nvim_buf_line_count(bufnr),
    relative = "msgarea",
    style = "minimal",
    title = title,
    noautocmd = set_wo,
  }
  local winid = view._open_win(bufnr, false, win_cfg, win_kind, true)
  if set_wo then internal.win_set_options(winid) end
end


-- internal helpers -----------------------------------------------------------

internal.get_bufnr_for_kind = function(win_kind, msg_kind)
  local state = M.state
  local bufnr, append
  if win_kind == "overflow" then
    local overflow_bufnr = state.overflow[msg_kind]
    if overflow_bufnr and api.nvim_buf_is_valid(overflow_bufnr) then
      bufnr = overflow_bufnr
      append = true
    else
      bufnr = internal.create_buf(nil, msg_kind)
      state.overflow[msg_kind] = bufnr
      local autocmd_opts = {
        buffer = bufnr,
        once = true,
        callback = function() state.overflow[msg_kind] = nil end,
      }
      api.nvim_create_autocmd("BufWipeout", autocmd_opts)
    end
  elseif win_kind == "ephemeral" then
    if state.bufnr and api.nvim_buf_is_valid(state.bufnr) then
      bufnr = state.bufnr
    else
      bufnr = internal.create_buf("[MsgArea]")
      state.bufnr = bufnr
    end
  else
    local current_batch_bufnr = state.current_batch[msg_kind]
    if current_batch_bufnr and api.nvim_buf_is_valid(current_batch_bufnr) then
      bufnr = current_batch_bufnr
      append = true
    else
      bufnr = internal.create_buf(nil, msg_kind)
      state.current_batch[msg_kind] = bufnr
    end
    vim.schedule(function()
      if state.current_batch[msg_kind] then state.current_batch[msg_kind] = nil end
    end)
  end
  return bufnr, append
end

-- TODO: need to handle message-id semantics...
-- namely:
--   - a current message whose id matches incoming message should be replaced by incoming
--   - should i keep track of message ids across buffer lines like ui2?
--   - should bufname act as an id? (incoming replace old)
internal.buf_set_content = function(bufnr, content, append)
  local lines = {}
  local extmarks_to_apply = {}
  local start_col = 0
  local i = 1
  for _, chunk in ipairs(content) do
    local text, hl_id = chunk[2], chunk[3]

    local lines_in_chunk = vim.split(text, "\n")

    local text_before_newline = lines_in_chunk[1]
    lines[i] = (lines[i] or "") .. text_before_newline
    if hl_id ~= 0 then
      extmarks_to_apply[#extmarks_to_apply + 1] = {
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
      lines[i] = (lines[i] or "") .. line
      if hl_id ~= 0 then
        extmarks_to_apply[#extmarks_to_apply + 1] = {
          row = i - 1,
          start_col = start_col,
          end_col = start_col + #line,
          hl_id = hl_id
        }
      end
      start_col = start_col + #line
    end
  end

  local start = append and -1 or 0
  local row_offset = append and api.nvim_buf_line_count(bufnr) or 0
  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, start, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  if not append then api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1) end
  for _, extmark in ipairs(extmarks_to_apply) do
    local srow = extmark.row + row_offset
    api.nvim_buf_set_extmark(bufnr, M.ns, srow, extmark.start_col, {
      end_col = extmark.end_col,
      hl_group = extmark.hl_id,
    })
  end

  return bufnr
end

internal.create_buf = function(name, msg_kind)
  local bufnr = api.nvim_create_buf(false, true)
  vim.keymap.set("n", "q", function()
    api.nvim_win_close(api.nvim_get_current_win(), true)
  end, { buf = bufnr })
  api.nvim_set_option_value("bufhidden", name and "hide" or "wipe", { buf = bufnr, scope = "local" })
  name = name or internal.make_uri(bufnr, msg_kind)
  api.nvim_buf_set_name(bufnr, name)
  return bufnr
end

internal.make_uri = function(bufnr, msg_kind)
  return "msgarea://" .. bufnr .. "/" .. msg_kind
end

internal.win_set_options = function(win)
  -- i just copied most of the wo settings from ui2
  vim._with({ win = win, noautocmd = true }, function()
    api.nvim_set_option_value("wrap", true, { scope = "local" })
    api.nvim_set_option_value("winfixbuf", true, { scope = "local" })
    api.nvim_set_option_value("linebreak", false, { scope = "local" })
    api.nvim_set_option_value("smoothscroll", true, { scope = "local" })
    api.nvim_set_option_value("breakindent", false, { scope = "local" })
    api.nvim_set_option_value("foldenable", false, { scope = "local" })
    api.nvim_set_option_value("showbreak", "", { scope = "local" })
    api.nvim_set_option_value("spell", false, { scope = "local" })
    api.nvim_set_option_value("swapfile", false, { scope = "local" })
    api.nvim_set_option_value("modeline", false, { scope = "local" })
    api.nvim_set_option_value("modifiable", false, { scope = "local" })
    api.nvim_set_option_value("buftype", "nofile", { scope = "local" })
    return nil
  end)
end

return M
