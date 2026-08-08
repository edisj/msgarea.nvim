local M = {}

---Show or refresh the msgarea view.
M.show = function()
  require("msgarea.view").show()
end

---Hide, but do not close, all msgarea windows.
---Subsequent `require("msgarea").show()` will restore saved view state.
M.hide = function()
  require("msgarea.view").hide()
end

---Close all msgarea windows and reset state.
M.close_all = function()
  require("msgarea.view").close_all()
end

---Initialize the plugin.
---@param user_config Msgarea.UserConfig
M.setup = function(user_config)
  local ok, merged_config = require("msgarea.config").setup(user_config or {})
  if not ok then
    local e = require("msgarea.util").error
    e("Config has errors. Aborting setup...")
    for _, err in ipairs(merged_config) do
      vim.api.nvim_echo({{ "  - " .. err }}, true, {})
    end
    return
  end

  require("msgarea.setup.autocmds").setup(merged_config)
  require("msgarea.setup.runtime_patches").setup(merged_config)
  require("msgarea.setup.highlights").setup()

  local cmdline = merged_config.cmdline
  if merged_config.enable and cmdline.enable then
    local provider = cmdline.cmp_provider
    if provider == "blink.cmp" then
      require("msgarea.integrations.blink").enable()
    elseif provider == "native" or provider == "mini.cmdline" then
      require("msgarea.integrations.native").enable()
    end
  else
    pcall(function() require("msgarea.integrations.blink").disable() end)
  end

  local ui2_targets = require("vim._core.ui2").cfg.msg.targets
  for _, target in ipairs(merged_config.msgarea_targets) do
    ---@diagnostic disable-next-line: assign-type-mismatch
    ui2_targets[target] = merged_config.enable and "msgarea" or nil
  end
end

---alias for `setup()`
M.config = M.setup

return M
