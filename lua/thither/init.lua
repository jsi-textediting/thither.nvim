--- Public Lua API for thither.nvim.
local config = require("thither.config")
local Client = require("thither.client")
local buffer = require("thither.buffer")
local large_file = require("thither.large_file")
local vfs = require("thither.vfs")
local ui = require("thither.ui")

local M = {}

M.config = config
M.client = Client
M.vfs = vfs
M.large_file = large_file
M.ui = ui

--- Configures thither.nvim with user options.
---@param user_config? table
function M.setup(user_config)
  config.setup(user_config)
end

--- Connects to a remote host.
---@param spec string
---@param cb? fun(client: table, err?: table)
---@return table
function M.connect(spec, cb)
  return Client.get(spec, cb)
end

--- Opens a remote file or URI in a Neovim buffer.
---@param uri_or_path string
function M.open(uri_or_path)
  local spec, rpath = buffer.parse_uri(uri_or_path)
  if not spec or not rpath then
    vim.notify("Invalid thither path: " .. uri_or_path, vim.log.levels.ERROR)
    return
  end
  local uri = string.format("thither://%s%s", spec, rpath)
  vim.cmd("edit " .. vim.fn.fnameescape(uri))
end

M.edit = M.open

--- Forces opening a remote file in Large File Viewport Mode, regardless of size.
---@param uri_or_path string
function M.large_edit(uri_or_path)
  local spec, rpath = buffer.parse_uri(uri_or_path)
  if not spec or not rpath then
    vim.notify("Invalid thither path: " .. uri_or_path, vim.log.levels.ERROR)
    return
  end

  local client = Client.get(spec)
  if not client:is_ready() then
    local wait_ok = vim.wait(config.get("timeout_seconds", spec) * 1000, function()
      return client:is_ready() or client.state == "error" or client.state == "closed"
    end, 10)
    if not wait_ok or not client:is_ready() then
      vim.notify("Failed to connect to host: " .. spec, vim.log.levels.ERROR)
      return
    end
  end

  local uri = string.format("thither://%s%s", spec, rpath)
  local bufnr = vim.fn.bufnr(uri, true)
  vim.api.nvim_set_current_buf(bufnr)

  local ok, err = large_file.open(bufnr, client, rpath, spec)
  if not ok then
    vim.notify(string.format("Failed to open in large file mode: %s", (err and err.msg) or "Unknown error"), vim.log.levels.ERROR)
  end
end

--- Jumps to a line number in the current large file viewport buffer.
---@param line integer
---@param col? integer
function M.goto_line(line, col)
  local bufnr = vim.api.nvim_get_current_buf()
  large_file.goto_line(bufnr, line, col)
end

--- Jumps to a percentage in the current large file viewport buffer.
---@param pct number (0 - 100)
function M.goto_percent(pct)
  local bufnr = vim.api.nvim_get_current_buf()
  large_file.goto_percent(bufnr, pct)
end

--- Scrolls the viewport window forward.
function M.page_next()
  local bufnr = vim.api.nvim_get_current_buf()
  large_file.page_next(bufnr)
end

--- Scrolls the viewport window backward.
function M.page_prev()
  local bufnr = vim.api.nvim_get_current_buf()
  large_file.page_prev(bufnr)
end

--- Executes server-side search across a remote file.
---@param pattern string
---@param opts? table { regex?: boolean, case?: boolean, limit?: integer }
function M.search(pattern, opts)
  local bufnr = vim.api.nvim_get_current_buf()
  large_file.search(bufnr, pattern, opts)
end

--- Jumps to the next search match in the current large file viewport buffer.
function M.search_next()
  local bufnr = vim.api.nvim_get_current_buf()
  large_file.search_next(bufnr)
end

--- Jumps to the previous search match in the current large file viewport buffer.
function M.search_prev()
  local bufnr = vim.api.nvim_get_current_buf()
  large_file.search_prev(bufnr)
end

return M
