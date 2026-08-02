local M = {}

local set_hls = function(hls)
  for hl, link in pairs(hls) do
    vim.api.nvim_set_hl(0, hl, { default = true, link = link })
  end
end

local BASE_LINKS = {
  MsgAreaWinBar = "MsgArea",
  MsgAreaWinBarFill = "TabLine",
  MsgAreaWinBarSel = "TabLineSel",
  MsgAreaWinBarSep = "Comment",
  MsgAreaDialogSep = "MsgArea",
}

-- TODO: native
-- local NATIVE_CMP_LINKS = {
--   MsgAreaCmpMenu = "Pmenu",
--   MsgAreaCmpLabel = "Pmenu",
--   MsgAreaCmpLabelDescription = "PmenuExtra",
-- }

local BLINK_CMP_LINKS = {
  MsgAreaCmpMenu = "MsgArea",
  MsgAreaCmpLabel = "MsgArea",
  MsgAreaCmpLabelDescription = "MsgArea",
}

M.setup = function(config)
  set_hls(BASE_LINKS)
  if config.cmdline.cmp_provider == "blink.cmp" then
    set_hls(BLINK_CMP_LINKS)
  -- TODO: native
  -- else
  --   set_hls(NATIVE_CMP_LINKS)
  end
end

return M
