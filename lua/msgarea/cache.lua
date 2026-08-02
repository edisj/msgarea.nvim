local api = vim.api
local fn = vim.fn
local M = {}

M.excmds = {}
local function populate_excmds_cache()
  M.excmds = {}
  local ts = vim.treesitter

  local path = api.nvim_get_runtime_file("doc/index.txt", false)[1]
  local bufnr = fn.bufadd(path)
  local buf_was_already_loaded = api.nvim_buf_is_loaded(bufnr)
  if not buf_was_already_loaded then
    fn.bufload(bufnr)
  end

  local parser = ts.get_parser(bufnr, "vimdoc")
  local tree = assert(parser):parse()[1]
  local root = tree:root()
  local query = ts.query.parse("vimdoc", [[
    (h1 (tag text: (_) @tag) (#eq? @tag "ex-cmd-index")) @heading
    (block (line (column_heading))) @block
  ]])

  local ex_cmd_heading_end
  local target_block
  for id, node, _ in query:iter_captures(root, bufnr, 0, -1) do
    local name = query.captures[id]
    if name == "heading" then
      ex_cmd_heading_end = select(3, node:range())
    end
    if name == "block" and ex_cmd_heading_end and node:start() >= ex_cmd_heading_end then
      target_block = node
      break
    end
  end

  local text = ts.get_node_text(target_block, bufnr)
  local lines = vim.split(text, "\n")
  local pattern = "^|:([^|]+)|%s+:%S+%s+(.+)$"
  for i, line in ipairs(lines) do
    local cmd, description = line:match(pattern)
    if cmd then
      -- HACK: some descriptions in index.txt are wrapped to
      -- the next line. I want to append those bits to this line
      -- and this heuristic seems to work
      local next_line = lines[i + 1]
      if next_line and not vim.startswith(next_line, "|:") then
        description = description .. " " .. vim.trim(next_line)
      end
      M.excmds[cmd] = description
    end
  end

  -- clean up after ourselves
  if not buf_was_already_loaded then
    api.nvim_buf_delete(bufnr, { force = true })
  end
end

M.usercmds = {}
local function populate_usercmds_cache()
  M.usercmds = {}
  for cmd, cmd_spec in pairs(api.nvim_get_commands({})) do
    M.usercmds[cmd] =
      cmd_spec.desc ~= "" and cmd_spec.desc
      or cmd_spec.definition ~= "" and cmd_spec.definition
      or ""
  end
end

M.refresh = function()
  if vim.v.vim_did_enter == 0 then
    -- scheduled during startup has this adds ~80ms on my machine
    vim.schedule(function()
      populate_excmds_cache()
      -- defer to give time for any other plugins that register usercmds to load
      vim.defer_fn(populate_usercmds_cache, 1000)
    end)
  else
    populate_excmds_cache()
    populate_usercmds_cache()
  end
end

return M
