local api = vim.api
local ui = require("vim._core.ui2")
local view = require("msgarea.view")
local config = require("msgarea.config")
local M = { msg_expanded = false }
local internal = { buf = nil, win = nil }

local WIN_ERROR = 0

-- local in_confirm = false -- TODO: confirm

---Monkey-patched require("vim._core.ui2.messages").msg_show(...)
M.msg_show = function(msg_show, kind, content, replace_last, history, append, id, trigger)
  -- if kind == "confirm" then in_confirm = true end -- TODO: confirm

  -- Match configured target mappings as Lua pattern to ID:
  local k, v, id_target = next(type(id) == "string" and ui.cfg.msg.targets or {})
  while k and not id_target do
    id_target = id:match(k) and v
    k, v = next(ui.cfg.msg.targets, k)
  end

  local in_pager = api.nvim_get_current_win() == ui.wins.pager
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

  vim.notify("Kind: " .. kind .. " tgt: " .. tgt)

  if tgt == "msgarea" then
    internal.show_message(kind, content, replace_last)
  else -- fallback to original msg_show for all other targets
    msg_show(kind, content, replace_last, history, append, id, trigger)
  end
end

---Monkey-patched require("vim._core.ui2.messages").expand_msg(...)
M.expand_msg = function(expand_msg, src, tgt)
  if src == "msg" and tgt == nil then
    M.msg_expanded = true
  end
  expand_msg(src, tgt)
end

---Monkey-patched require("vim._core.ui2.messages").set_pos(...)
M.set_pos = function(set_pos, tgt)
  if tgt == "pager" then
    pcall(api.nvim_win_close, internal.win, true)
    ui.msg.msg:clear()
    view.hide({ cmdheight = view.original_cmdheight })
  end

  -- TODO: confirm
  -- if tgt == "dialog" and in_confirm then
  --   in_confirm = false
  --   vim.schedule(function()
  --     local win = ui.wins.dialog
  --     if not vim.w[win].msgarea_dialog_sep then
  --       vim.w[win].msgarea_dialog_sep = true
  --       local winhl = vim.wo[win].winhl
  --       winhl = "FloatBorder:MsgAreaDialogSep,FloatTitle:MsgAreaDialogSep," .. winhl
  --       vim.wo[win].winhl = winhl
  --       local title = "─ Confirm "
  --       local top = { "─", "MsgAreaDialogSep" }
  --       local border = border = { "", top, "", "", "", "", "", "" }
  --       api.nvim_win_set_config(win, { title = title, border = border })
  --       api.nvim__redraw({ flush = true, win = win })
  --     end
  --   end)
  -- end

  set_pos(tgt)
end


-- internal helpers -----------------------------------------------------------

---Analagous to require("vim._core.ui2.messages").show_msg()
---@param kind string
---@param content MsgContent
---@param replace_last boolean
internal.show_message = function(kind, content, replace_last)
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

  local title = config.get().messages_title
  if type(title) == "function" then title = title(kind) end
  local is_ephemeral = title == nil
  local buf = is_ephemeral and internal.create_ephemeral_buf() or internal.ensure_msgarea_buf()

  local min_tabs, height
  if is_ephemeral and view.in_ephemeral() then
    title = api.nvim_buf_get_name(buf)
    height = math.min(#lines, vim.o.cmdheight) -- FIXME: how should this be decided?
    min_tabs = 999
  end

  vim.bo[buf].modifiable = true
  local start = replace_last and -1 or 0
  api.nvim_buf_set_lines(buf, start, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ns = api.nvim_create_namespace("msgarea.messages")
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, extmark in ipairs(extmarks_to_apply) do
    api.nvim_buf_set_extmark(buf, ns, extmark.row, extmark.start_col, {
      end_col = extmark.end_col,
      hl_group = extmark.hl_id,
    })
  end

  local winid
  if is_ephemeral then
    winid = internal.create_ephemeral_win(buf, title)
  else
    winid = internal.ensure_msgarea_win(buf, title)
  end
  if winid ~= WIN_ERROR then
    view.show({ silent = true, focused = winid, winbar_min_tabs = min_tabs, height = height })
  end
end

---@return integer
local _create_buf = function()
  local buf = api.nvim_create_buf(false, true)
  vim.keymap.set("n", "q", function()
    api.nvim_win_close(api.nvim_get_current_win(), true)
  end, { buf = buf })
  return buf
end

---@return integer
internal.ensure_msgarea_buf = function()
  if internal.buf and api.nvim_buf_is_valid(internal.buf) then return internal.buf end
  internal.buf = _create_buf()
  api.nvim_buf_set_name(internal.buf, "[MsgArea]")
  api.nvim_set_option_value("bufhidden", "hide", { buf = internal.buf, scope = "local" })
  return internal.buf
end

---@return integer
internal.create_ephemeral_buf = function()
  local buf = _create_buf()
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf, scope = "local" })
  api.nvim_buf_set_name(buf, "msgarea://" .. buf .. "/ephemeral")
  return buf
end

local _win_set_wo = function(win)
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
  end)
end

---@param buf integer
---@param title string
---@return integer
internal.ensure_msgarea_win = function(buf, title)
  local height = api.nvim_buf_line_count(buf) + (title and 1 or 0)
  if internal.win and api.nvim_win_is_valid(internal.win) then
    for _, win_spec in ipairs(view.state.windows) do
      if win_spec.winid == internal.win then
        win_spec.height = height
        win_spec.title = title
        break
      end
    end
  else
    local win_cfg = { relative = "msgarea", style = "minimal", title = title, height = height }
    internal.win = api.nvim_open_win(buf, false, win_cfg)
    _win_set_wo(internal.win)
  end
  return internal.win
end

---@param buf integer
---@param title? string
internal.create_ephemeral_win = function(buf, title)
  local height = api.nvim_buf_line_count(buf)
  local win_cfg = { relative = "msgarea", style = "minimal", title = title, height = height }
  local winid = api.nvim_open_win(buf, false, win_cfg)
  if winid == WIN_ERROR then
    return WIN_ERROR
  else
    _win_set_wo(winid)
    if title then
      local autocmd_opts = {
        once = true,
        group = api.nvim_create_augroup("msgarea.nvim-" .. tostring(winid), { clear = false }),
        pattern = tostring(view.state.windows.ephemeral.winid),
        callback = function()
          vim.schedule(function() pcall(api.nvim_win_close,winid, true) end)
        end
      }
      api.nvim_create_autocmd("WinClosed", autocmd_opts)
      return winid
    end
  end
end

return M
