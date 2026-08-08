local api = vim.api
local view = require("msgarea.view")
local config = require("msgarea.config")
local util = require("msgarea.util")

local M = { msg_expanded = false }
local internal = {
  bufs = { msgarea = nil, ephemeral = nil },
  winid = nil,
  ns = api.nvim_create_namespace("msgarea.messages"),
}
local WIN_ERROR = 0

-- local in_confirm = false -- TODO: confirm

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
    view.close_safely(internal.winid)
    util.msg_clear()
    view.hide({ cmdheight = view.original_cmdheight })
  end

  -- TODO: confirm styling?
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

---Monkey-patched require("vim._core.ui2.messages").show_msg(...)
M.show_msg = function(show_msg, tgt, kind, content, replace_last, ...)
  -- vim.notify(kind .. " -> " .. tgt)
  if tgt ~= "msgarea" then
    -- fallback to original show_msg for all other targets
    show_msg(tgt, kind, content, replace_last, ...)
    return
  end

  local title = kind and config.get().messages_title or nil
  if type(title) == "function" then title = title(kind) end
  local is_ephemeral = title == nil

  local bufnr
  if type(content) == "table" then
    bufnr = internal.content_to_buf(content, is_ephemeral, replace_last)
  else
    bufnr = content
  end

  local winid, height, min_tabs
  if is_ephemeral then
    if view.in_ephemeral() then
      local name = api.nvim_buf_get_name(bufnr)
      title = name == "" and "[Scratch!!]" or name
      height = math.min(api.nvim_buf_line_count(bufnr), vim.o.cmdheight) -- FIXME: how should this be decided?
      min_tabs = math.huge
    end
    winid = internal.create_ephemeral_win(bufnr, title)
  else
    winid = internal.try_reuse_win(bufnr, title)
  end
  if winid ~= WIN_ERROR then
    local opts = {
      silent = true,
      focused = winid,
      -- height = height,
      winbar_min_tabs = min_tabs,
    }
    view.show(opts)
  end
end


-- internal helpers -----------------------------------------------------------

internal.content_to_buf = function(content, is_ephemeral, replace_last)
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

  local bufnr = internal.try_reuse_buf(is_ephemeral and "ephemeral" or "msgarea")
  vim.bo[bufnr].modifiable = true
  -- TODO: need to look into semantics of replace last
  -- local start = replace_last and -1 or 0
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  api.nvim_buf_clear_namespace(bufnr, internal.ns, 0, -1)
  for _, extmark in ipairs(extmarks_to_apply) do
    api.nvim_buf_set_extmark(bufnr, internal.ns, extmark.row, extmark.start_col, {
      end_col = extmark.end_col,
      hl_group = extmark.hl_id,
    })
  end

  return bufnr
end

---@return integer
internal.try_reuse_buf = function(which)
  local bufnr = internal.bufs[which]
  if bufnr and api.nvim_buf_is_valid(bufnr) then return bufnr end

  bufnr = api.nvim_create_buf(false, true)
  vim.keymap.set("n", "q", function()
    api.nvim_win_close(api.nvim_get_current_win(), true)
  end, { buf = bufnr })

  local name = which == "ephemeral" and "msgarea://" .. bufnr .. "/ephemeral" or "[MsgArea]"
  api.nvim_buf_set_name(bufnr, name)
  api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr, scope = "local" })
  internal.bufs[which] = bufnr
  return bufnr
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
internal.try_reuse_win = function(buf, title)
  local height = api.nvim_buf_line_count(buf) + (title and 1 or 0)
  if internal.winid and api.nvim_win_is_valid(internal.winid) then
    for _, win_spec in ipairs(view.state.windows) do
      if win_spec.winid == internal.win then
        win_spec.height = height
        win_spec.title = title
        break
      end
    end
  else
    local win_cfg = { relative = "msgarea", style = "minimal", title = title, height = height }
    internal.winid = api.nvim_open_win(buf, false, win_cfg)
    _win_set_wo(internal.winid)
  end
  return internal.winid
end

---@param bufnr integer
---@param title? string
internal.create_ephemeral_win = function(bufnr, title)
  local height = api.nvim_buf_line_count(bufnr)
  local win_cfg = { relative = "msgarea", style = "minimal", title = title, height = height }
  local winid = api.nvim_open_win(bufnr, false, win_cfg)
  if winid == WIN_ERROR then
    return WIN_ERROR
  else
    _win_set_wo(winid)
    if title then
      local autocmd_opts = {
        once = true,
        group = api.nvim_create_augroup("msgarea.nvim-" .. tostring(winid), { clear = false }),
        pattern = tostring(view.state.windows.ephemeral.winid),
        callback = vim.schedule_wrap(function() view.close_safely(winid) end)
      }
      api.nvim_create_autocmd("WinClosed", autocmd_opts)
      return winid
    end
  end
end

return M
