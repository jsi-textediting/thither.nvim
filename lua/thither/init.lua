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

  local client, cerr = Client.ensure(spec)
  if not client then
    vim.notify(string.format("Failed to connect to host %s: %s", spec, (cerr and cerr.msg) or "timeout"), vim.log.levels.ERROR)
    return
  end

  local uri = string.format("thither://%s%s", spec, rpath)
  local bufnr = vim.fn.bufnr(uri, true)
  if large_file.buffers[bufnr] then
    vim.api.nvim_set_current_buf(bufnr)
    return
  end
  local loaded = vim.api.nvim_buf_is_loaded(bufnr)
  if not loaded then
    -- BufReadCmd (fired when the buffer is loaded) opens it in large-file mode
    buffer.force_large[bufnr] = true
  end
  vim.api.nvim_set_current_buf(bufnr)
  buffer.force_large[bufnr] = nil

  if not large_file.buffers[bufnr] then
    if loaded and vim.bo[bufnr].modified then
      vim.notify("Buffer has unsaved changes; write or discard them first", vim.log.levels.ERROR)
      return
    end
    local ok, err = large_file.open(bufnr, client, rpath, spec)
    if not ok then
      vim.notify(string.format("Failed to open in large file mode: %s", (err and err.msg) or "Unknown error"), vim.log.levels.ERROR)
    end
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

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------

--- Host spec for session commands: the current thither buffer's host, else
--- the only connected host.
---@param bufnr? integer
---@return string|nil spec, string|nil err
function M.current_spec(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lf = large_file.buffers[bufnr]
  if lf and lf.spec then return lf.spec end
  local spec = vim.b[bufnr].thither_spec
  if spec then return spec end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:match("^thither://") then
    spec = buffer.parse_uri(name)
    if spec then return spec end
  end
  local live = {}
  for s, c in pairs(Client.instances) do
    if c:is_alive() then live[#live + 1] = s end
  end
  table.sort(live)
  if #live == 1 then return live[1] end
  if #live == 0 then return nil, "no thither host given and none connected" end
  return nil, "several hosts connected, name one: " .. table.concat(live, ", ")
end

--- Connects to `spec` and checks that it runs in session mode.
---@param spec string
---@return table|nil client, string|nil err
local function session_client(spec)
  local ok, sname = pcall(require("thither.transport").session_name, spec)
  if not ok then return nil, tostring(sname) end
  if not sname then
    return nil, string.format("host %s is not in session mode (set the `session` option for it)", spec)
  end
  local client, cerr = Client.ensure(spec)
  if not client then
    return nil, string.format("cannot connect to %s: %s", spec, (cerr and cerr.msg) or "error")
  end
  if not (client.caps.session and type(client.server_info.session) == "table") then
    return nil, string.format("host %s is not in session mode (thither-server %s has no session support)",
      spec, tostring(client.server_info.server_version))
  end
  return client
end

--- Returns the remote session's `session_info` for `spec`.
---@param spec string
---@return table|nil info, string|nil err
function M.session_info(spec)
  local client, err = session_client(spec)
  if not client then return nil, err end
  local info, ierr = client:call_sync("session_info", nil)
  if not info then
    return nil, string.format("session_info on %s failed: %s", spec, (ierr and ierr.msg) or "error")
  end
  return info
end

--- Formats a `session_info` reply for display.
---@param spec string
---@param info table
---@return string
function M.format_session_info(spec, info)
  local function v(x) return (x == nil or x == vim.NIL) and "-" or tostring(x) end
  local started = tonumber(info.started)
  local plugins = type(info.plugins) == "table" and table.concat(vim.tbl_map(tostring, info.plugins), ", ") or ""
  return table.concat({
    "thither session on " .. spec,
    "  name:        " .. v(info.name),
    "  daemon pid:  " .. v(info.daemon_pid),
    "  started:     " .. (started and os.date("%Y-%m-%d %H:%M:%S", started) or v(info.started)),
    "  version:     " .. v(info.version),
    "  skew:        " .. ((info.version_skew == nil or info.version_skew == vim.NIL) and "none"
      or ("installed is " .. tostring(info.version_skew))),
    "  connections: " .. v(info.connections),
    "  plugins:     " .. (plugins ~= "" and plugins or "none"),
  }, "\n")
end

--- Ends the remote session of `spec` (session_shutdown) and disconnects.
--- The next operation on the host starts a fresh daemon.
---@param spec string
---@return boolean ok, string|nil err
function M.restart_session(spec)
  local client, err = session_client(spec)
  if not client then return false, err end
  local name = client.server_info.session.name
  Client.session_restart_requested[spec] = true
  local ok, serr = client:call_sync("session_shutdown", { timeout_ms = 2000 })
  if not ok then
    Client.session_restart_requested[spec] = nil
    return false, string.format("session_shutdown on %s failed: %s", spec, (serr and serr.msg) or "error")
  end
  -- the daemon drains and closes every connection, then stops listening;
  -- wait for that so the next connection does not reach the old daemon
  vim.wait(5000, function() return client.exited end, 20)
  client:close()
  vim.notify(string.format("thither: session %s on %s ended; the next operation starts a new one", tostring(name), spec),
    vim.log.levels.INFO)
  return true
end

return M
