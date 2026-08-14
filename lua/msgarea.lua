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
---@param user_config msgarea.UserConfig
M.setup = function(user_config)
  require("msgarea.setup").setup(user_config)
end

---alias for `setup()`
M.config = M.setup

return M
