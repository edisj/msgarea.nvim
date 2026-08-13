local api, fn = vim.api, vim.fn
local ui2 = require("vim._core.ui2")
local cache = require("msgarea.cache")
local view = require("msgarea.view")
local config = require("msgarea.config")
local util = require("msgarea.util")

local M = { selected = -1, total = 0 }
local state = {
  bufnr = nil,
  winid = nil,
  attached = false,
  cache = {},
  curr_matches = {},
  hide_pending = false,
  hide_timer = nil,
}

local NS_UI = api.nvim_create_namespace("msgarea.integrations.native")
local NS_SHOW = api.nvim_create_namespace("msgarea.integrations.native-cmp-show")
local NS_SELECT = api.nvim_create_namespace("msgarea.integrations.native-cmp-select")
local HIDE_DELAY_MS = 10
local BORDER = { "", "", "", " ", "", "", "", " " }

local get_lines_and_matches = function(items)
  local key = fn.getcmdline():gsub("^%s+", "")
  local cached = state.cache[key]
  if cached then return cached.lines, cached.matches, cached.label_col_width end

  local pat = fn.getcmdcomplpat()
  local lines, matches, label_col_width = {}, {}, 0
  for i, item in ipairs(items) do
    local word = item[1]
    lines[i] = word
    matches[i] = fn.matchfuzzypos({ word }, pat)[2][1]
    if #word > label_col_width then label_col_width = #word end
  end
  state.cache[key] = { lines = lines, matches = matches, label_col_width = label_col_width }
  return lines, matches, label_col_width
end

local win_valid = function()
  return state.winid and api.nvim_win_is_valid(state.winid)
end

local try_update_height = util.throttled(function(height)
  if not win_valid() then return end
  local win_cfg = { relative = "msgarea", height = height, border = BORDER }
  api.nvim_win_set_config(state.winid, win_cfg)
end)

local get_height = function(n_items)
  local dynamic = config.get().cmdline.dynamic_height
  return dynamic and math.min(n_items, vim.o.pumheight) or vim.o.pumheight
end

M.popupmenu_show = function(items, selected)
  state.hide_pending = false

  local lines, matches, label_col_width = get_lines_and_matches(items)
  state.curr_matches = matches
  api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)

  M.selected, M.total = selected, #lines

  if not (win_valid()) then
    local win_cfg = {
      border = BORDER,
      style = "minimal",
      relative = "msgarea",
      height = get_height(#lines),
      focusable = false
    }
    state.winid = api.nvim_open_win(state.bufnr, false, win_cfg)
    vim.wo[state.winid].winhl = vim.wo[state.winid].winhl .. ",Search:,IncSearch:,CurSearch:"
  else
    try_update_height(get_height(#lines))
  end

  api.nvim_buf_clear_namespace(state.bufnr, NS_SHOW, 0, -1)
  local set_extmark = function(lnum, col, extmark_opts)
    api.nvim_buf_set_extmark(state.bufnr, NS_SHOW, lnum-1, col, extmark_opts)
  end

  local include_desc = config.get().cmdline.descriptions and fn.getcmdcompltype() == "command"
  for i, word in ipairs(lines) do
    if include_desc then
      local desc = cache.excmds[word] or cache.usercmds[word] or ""
      local opts = {
        virt_text = {{ desc, "MsgAreaCmpLabelDescription" }},
        virt_text_win_col = label_col_width + 4,
        hl_mode = "combine",
      }
      set_extmark(i, 0, opts)
    end
    if matches[i] then
      for _, scol in ipairs(matches[i]) do
        local opts = {
          end_col = scol + 1,
          hl_group = i-1 == selected and "PmenuMatchSel" or "PmenuMatch",
          hl_mode = "combine",
          priority = 1,
        }
        set_extmark(i, scol, opts)
      end
    end
  end
end

M.popupmenu_select = function(selected)
  M.selected = selected
  api.nvim_buf_clear_namespace(state.bufnr, NS_SELECT, 0, -1)
  if selected == -1 then return end

  local set_extmark = function(scol, ecol, opts)
    opts.end_col = ecol
    api.nvim_buf_set_extmark(state.bufnr, NS_SELECT, selected, scol, opts)
  end

  -- NOTE: without explicitly setting priority, this will cover other highlights
  set_extmark(0, 0, { hl_group = "PmenuSel", end_row = selected+1, hl_eol = true, priority = 0 })

  local lnum = selected + 1
  local matches = state.curr_matches
  if matches and matches[lnum] then
    for _, scol in ipairs(matches[lnum]) do
      -- NOTE: priority needs to be > than PmenuMatch
      set_extmark(scol, scol+1, { hl_group = "PmenuMatchSel", priority = 2 })
    end
  end

  api.nvim_win_set_cursor(state.winid, { lnum, 0 })
end

M.popupmenu_hide = function()
  state.hide_pending = true
  if (state.hide_timer and not state.hide_timer:is_closing()) then
    state.hide_timer:close()
  end
  -- NOTE: every vim.fn.wildtrigger() seems to emit
  -- popupmenu_hide -> popupmenu_show, but they seem NOT to be
  -- synchronous so a simple vim.schedule(check if should hide) doesn't
  -- work. That's why I'm using a timer instead
  state.hide_timer = vim.defer_fn(vim.schedule_wrap(function()
    if not (state.hide_pending and win_valid() and fn.mode() == "c") then
      return
    end
    M.selected, M.total = -1, 0
    state.hide_pending = false
    api.nvim_win_close(state.winid, true)
    if config.get().cmdline.dynamic_height or fn.getcmdline() == "" then
      vim.o.cmdheight = 1
    end
  end), HIDE_DELAY_MS)
end

local attach = vim.schedule_wrap(function()
  if fn.mode() ~= "c" then return end
  if not (state.bufnr and api.nvim_buf_is_valid(state.bufnr)) then
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_option_value("filetype", "native-cmp-menu", { scope = "local", buf = buf })
    api.nvim_buf_set_name(buf, "msgarea://" .. buf .. "/native-cmp-menu")
    state.bufnr = buf
  end
  state.attached = true
  vim.ui_attach(NS_UI, { ext_popupmenu = true }, function(event, ...)
    local handler = M[event]
    if handler then handler(...) end
  end)
end)

local detach = vim.schedule_wrap(function()
  if ui2.cmd.prompt or not state.attached then return end
  view.close_safely(state.winid)
  state.winid, state.attached, state.cache, state.curr_matches = nil, false, {}, {}
  -- need to schedule this
  -- see https://github.com/neovim/neovim/discussions/32094#discussioncomment-11878489
  vim.ui_detach(NS_UI)
end)

local id
local setup_autocmds = function()
  id = api.nvim_create_augroup("msgarea-nativecmp-autocmds", { clear = true })
  local on = function(event, pattern, desc, cb)
    api.nvim_create_autocmd(event, {
      group = id,
      pattern = pattern,
      desc = "(msgarea.nvim) " .. desc,
      callback = cb,
    })
  end
  on("CmdlineEnter", { ":", "/", "\\?" }, "attach ext-popupmenu", attach)
  on("CmdlineLeave", "*", "detach ext-popupmenu", detach)
end

M.enable = function()
  setup_autocmds()
  if config.get().cmdline.descriptions then cache.refresh() end
end

M.disable = function()
  detach()
  pcall(api.nvim_del_augroup_by_id, id)
end

return M
