local api, fn = vim.api, vim.fn
local view = require("msgarea.view")
local config = require("msgarea.config")
local util = require("msgarea.util")

local M = {
  msg_expanded = false,
  ns = api.nvim_create_namespace("msgarea.messages"),
  state = {
    bufnr = nil, ---@type integer
    winid = nil, ---@type integer
    current_batch = {}, ---@type table<string, integer> kind -> bufnr
    overflow = {}, ---@type table<string, integer> kind -> bufnr
  },
}

local internal = {}

---Monkey-patched require("vim._core.ui2.messages").expand_msg(...)
M.expand_msg = function(expand_msg, src, tgt, focus)
  M.msg_expanded = src == "msg" and tgt == nil
  expand_msg(src, tgt, focus)
end

---Monkey-patched require("vim._core.ui2.messages").set_pos(...)
M.set_pos = function(set_pos, tgt, focus)
  if tgt == "pager" then
    view.close_safely(M.state.winid)
    view.hide({ cmdheight = view.original_cmdheight })
    util.msg_clear()
  end
  set_pos(tgt, focus)
end

---Monkey-patched require("vim._core.ui2.messages").show_msg(...)
M.show_msg = function(show_msg, tgt, kind, content, replace_last, append, id)
  if tgt ~= "msgarea" then
    -- fallback to original show_msg for all other targets
    show_msg(tgt, kind, content, replace_last, append, id)
    return
  end

  local title = kind and config.get().message_title or nil
  if type(title) == "function" then title = title(kind) end
  local is_ephemeral = title == nil

  local bufnr, winid, showopts
  if type(content) == "table" then
    -- content is MsgContent[] text chunks so we create the buffer ourselves
    bufnr = internal.content_to_buf(kind, content, replace_last, append, id, is_ephemeral)
  else
    -- content is ready-to-go buffer so just show it as is
    bufnr = content
  end

  winid, showopts = internal.get_winid(bufnr, title)
  view.show(showopts)
  return winid
end


-- internal helpers -----------------------------------------------------------

internal.content_to_buf = function(kind, content, _, append, _, is_ephemeral)
  local state = M.state
  local bufnr

  if is_ephemeral and view.in_ephemeral() then
    -- need to send this message to overflow
    local overflow_bufnr = state.overflow[kind]
    if overflow_bufnr and api.nvim_buf_is_valid(overflow_bufnr) then
      bufnr = overflow_bufnr
      append = true
    else
      bufnr = internal.create_buf(nil, kind)
      state.overflow[kind] = bufnr
      local autocmd_opts = {
        buffer = bufnr,
        once = true,
        callback = function() state.overflow[kind] = nil end,
      }
      api.nvim_create_autocmd("BufWipeout", autocmd_opts)
    end
  elseif is_ephemeral then
    if state.bufnr and api.nvim_buf_is_valid(state.bufnr) then
      bufnr = state.bufnr
    else
      bufnr = internal.create_buf("[MsgArea]")
      state.bufnr = bufnr
    end
  else
    local current_batch_bufnr = state.current_batch[kind]
    if current_batch_bufnr and api.nvim_buf_is_valid(current_batch_bufnr) then
      bufnr = current_batch_bufnr
      append = true
    else
      bufnr = internal.create_buf(nil, kind)
      state.current_batch[kind] = bufnr
    end
    vim.schedule(function()
      if state.current_batch[kind] then state.current_batch[kind] = nil end
    end)
  end

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

internal.get_winid = function(bufnr, title)
  local winid = nil
  local showopts = { silent = true }
  local line_count = api.nvim_buf_line_count(bufnr)

  local is_ephemeral = title == nil
  local is_overflow = is_ephemeral and view.in_ephemeral()
  if is_overflow then showopts.winbar_min_tabs = math.huge end

  -- check if bufnr is already in a msgarea window
  -- this happens is 3 scenarios:
  --   1) we're in a synchronous block appending a msg kind
  --   2) we're writing another overflow msg of the same kind
  --   3) sending a whole buffer as message again
  for _, data in ipairs(view.state.windows) do
    if bufnr == data.bufnr then
      if not data.resized then data.inner_height = line_count end
      showopts.curwin = data.winid
      return data.winid, showopts
    end
  end

  if is_overflow then
    title = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
    local autocmd_opts = {
      once = true,
      group = api.nvim_create_augroup("msgarea.nvim-overflow-" .. tostring(bufnr), { clear = false }),
      pattern = tostring(view.state.windows.ephemeral.winid),
      callback = vim.schedule_wrap(function() view.close_safely(winid) end)
    }
    api.nvim_create_autocmd("WinClosed", autocmd_opts)
  end

  local win_cfg = {
    relative = "msgarea",
    title = title,
    height = line_count,
    style = "minimal",
    -- NOTE: autocmds sometimes cause trouble when
    -- messages are opened during unsafe moments
    noautocmd = true,
  }
  winid = api.nvim_open_win(bufnr, false, win_cfg)
  internal.win_set_wo(winid)
  if is_overflow then showopts.curwin = winid end

  return winid, showopts
end

internal.create_buf = function(name, kind)
  local bufnr = api.nvim_create_buf(false, true)
  vim.keymap.set("n", "q", function()
    api.nvim_win_close(api.nvim_get_current_win(), true)
  end, { buf = bufnr })
  api.nvim_set_option_value("bufhidden", name and "hide" or "wipe", { buf = bufnr, scope = "local" })
  name = name or internal.make_uri(bufnr, kind)
  api.nvim_buf_set_name(bufnr, name)
  return bufnr
end

internal.make_uri = function(bufnr, kind)
  return "msgarea://" .. bufnr .. "/" .. kind
end

internal.win_set_wo = function(win)
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
