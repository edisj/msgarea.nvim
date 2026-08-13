local M = {}

local hi = function(hl, link)
  vim.api.nvim_set_hl(0, hl, { default = true, link = link })
end

local BASE_LINKS = {
  MsgAreaWinBar = "MsgArea",
  MsgAreaWinBarFill = "TabLine",
  MsgAreaWinBarSel = "TabLineSel",
  MsgAreaWinBarSep = "Comment",
  -- MsgAreaDialogSep = "MsgArea",
  MsgAreaCmpMenu = "MsgArea",
  MsgAreaCmpLabel = "MsgArea",
  MsgAreaCmpLabelDescription = "Comment",
}

M.setup = function()
  for hl, link in pairs(BASE_LINKS) do
    hi(hl, link)
  end
end

return M
