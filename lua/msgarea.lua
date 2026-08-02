local M = {}

M.show = function(opts)
  require("msgarea.view").show(opts)
end

M.hide = function()
  require("msgarea.view").hide()
end

M.close_all = function()
  require("msgarea.view").close_all()
end

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
  require("msgarea.setup.highlights").setup(merged_config)
  require("msgarea.setup.runtime_patches").setup(merged_config)

  local cmdline = merged_config.cmdline
  if merged_config.enabled and cmdline.enabled then
    if cmdline.cmp_provider == "blink.cmp" then
      require("msgarea.integrations.blink").enable()
    -- TODO: native
    -- else
    --   require("msgarea.integrations.native").enable()
    end
  else
    require("msgarea.integrations.blink").disable()
  end

  local ui2_targets = require("vim._core.ui2").cfg.msg.targets
  for _, target in ipairs(merged_config.msgarea_targets) do
    ---@diagnostic disable-next-line: assign-type-mismatch
    ui2_targets[target] = merged_config.enabled and "msgarea" or nil
  end
end

---alias for `setup()`
---@param user_config Msgarea.UserConfig
M.config = function(user_config)
  M.setup(user_config)
end

return M
