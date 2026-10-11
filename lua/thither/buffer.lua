--- Buffer URI router and event handlers for thither:// protocol.
local Client = require("thither.client")
local vfs = require("thither.vfs")
local config = require("thither.config")
local large_file = require("thither.large_file")
local dir_browser = require("thither.dir_browser")

local M = {}

--- Parses a thither URI or path into (spec, remote_path).
--- Examples:
---   "thither://devbox/home/u/test.txt" -> "devbox", "/home/u/test.txt"
---   "thither://local:/tmp/test.txt"    -> "local:", "/tmp/test.txt"
---   "devbox:/var/log/syslog"           -> "devbox", "/var/log/syslog"
---@param uri string
---@return string|nil spec, string|nil rpath
function M.parse_uri(uri)
  -- 1. thither:// scheme
  local scheme_match = uri:match("^thither://(.+)$")
  if scheme_match then
    -- Handle local: special transport inside uri
    local local_path = scheme_match:match("^local:(/.*)$")
    if local_path then
      return "local:", local_path
    end

    local spec, rpath = scheme_match:match("^([^/]+)(/.*)$")
    if spec and rpath then
      return spec, rpath
    end
    -- No path part -> root /
    local host_only = scheme_match:match("^([^/]+)/?$")
    if host_only then
      return host_only, "/"
    end
  end

  -- 2. host:/path format
  local host, path = uri:match("^([^:/]+):(/.*)$")
  if host and path then
    return host, path
  end

  -- 3. local:/path format
  local loc_path = uri:match("^local:(/.*)$")
  if loc_path then
    return "local:", loc_path
  end

  return nil, nil
end

--- Handler for BufReadCmd thither://*
---@param bufnr integer
---@param uri string
function M.on_buf_read(bufnr, uri)
  local spec, rpath = M.parse_uri(uri)
  if not spec or not rpath then
    vim.notify("Invalid thither URI: " .. uri, vim.log.levels.ERROR)
    return
  end

  local client = Client.get(spec)
  if not client:is_ready() then
    local wait_ok = vim.wait(config.get("timeout_seconds", spec) * 1000, function()
      return client:is_ready() or client.state == "error" or client.state == "closed"
    end, 10)
    if not wait_ok or not client:is_ready() then
      vim.notify(
        string.format("Failed to connect to '%s': %s", spec, (client.last_error and client.last_error.msg) or "timeout"),
        vim.log.levels.ERROR
      )
      return
    end
  end

  -- Query remote stat
  local st, err = vfs.stat(client, rpath)

  if not st and err and err.code == "ENOENT" then
    -- Missing file: allow editing as new file
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].modified = false
    vim.b[bufnr].thither_spec = spec
    vim.b[bufnr].thither_rpath = rpath
    vim.b[bufnr].thither_etag = nil
    vim.notify(string.format("[New Remote File] %s:%s", spec, rpath), vim.log.levels.INFO)
    return
  elseif not st then
    vim.notify(string.format("Failed to stat '%s:%s': %s", spec, rpath, err and err.msg or "unknown error"), vim.log.levels.ERROR)
    return
  end

  -- Directory handling
  if st.type == "dir" then
    dir_browser.open(bufnr, client, rpath, spec)
    return
  end

  -- Large file detection [PRIORITY]
  local threshold = config.get("large_file_threshold", spec) or (10 * 1024 * 1024)
  if st.size >= threshold then
    local ok, lerr = large_file.open(bufnr, client, rpath, spec)
    if not ok then
      vim.notify(
        string.format("Failed to open large file '%s': %s", rpath, (lerr and lerr.msg) or "unknown error"),
        vim.log.levels.ERROR
      )
    end
    return
  end

  -- Normal file reading (< threshold)
  local data, etag, rerr = vfs.read_all(client, rpath)
  if not data then
    vim.notify(string.format("Failed to read '%s': %s", rpath, (rerr and rerr.msg) or "unknown error"), vim.log.levels.ERROR)
    return
  end

  local lines = {}
  if #data == 0 then
    lines = { "" }
  else
    local pos = 1
    local data_len = #data
    while pos <= data_len do
      local nl = data:find("\n", pos, true)
      if nl then
        local line = data:sub(pos, nl - 1)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        table.insert(lines, line)
        pos = nl + 1
      else
        local line = data:sub(pos)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        table.insert(lines, line)
        break
      end
    end
  end

  local old_undo = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].undolevels = old_undo

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].modified = false
  if data:find("\r\n", 1, true) then
    vim.bo[bufnr].fileformat = "dos"
  else
    vim.bo[bufnr].fileformat = "unix"
  end

  vim.b[bufnr].thither_spec = spec
  vim.b[bufnr].thither_rpath = rpath
  vim.b[bufnr].thither_etag = etag

  -- Match filetype
  pcall(function()
    local ft = vim.filetype.match({ buf = bufnr, filename = rpath })
    if ft then vim.bo[bufnr].filetype = ft end
  end)
end

--- Handler for BufWriteCmd thither://*
---@param bufnr integer
function M.on_buf_write(bufnr)
  -- 1. Check if handled by large file subsystem
  if large_file.buffers[bufnr] then
    large_file.save(bufnr)
    return
  end

  -- 2. Normal file write
  local spec = vim.b[bufnr].thither_spec
  local rpath = vim.b[bufnr].thither_rpath
  local etag = vim.b[bufnr].thither_etag

  if not spec or not rpath then
    vim.notify("Buffer is missing thither remote metadata", vim.log.levels.ERROR)
    return
  end

  local client = Client.get(spec)
  if not client:is_ready() then
    vim.notify("Client is not ready to write", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local sep = vim.bo[bufnr].fileformat == "dos" and "\r\n" or "\n"
  local eol = (vim.bo[bufnr].endofline ~= false) and sep or ""
  local data = table.concat(lines, sep) .. eol

  local res, err = vfs.write(client, rpath, data, etag, nil, true)
  if not res then
    if err and err.code == "conflict" then
      vim.notify(
        string.format("Conflict! File on host changed (current etag: %s).", tostring(err.etag)),
        vim.log.levels.ERROR
      )
    else
      vim.notify(
        string.format("Failed to save remote file: %s", (err and err.msg) or "Unknown error"),
        vim.log.levels.ERROR
      )
    end
    return
  end

  vim.b[bufnr].thither_etag = res.etag
  vim.bo[bufnr].modified = false
  vim.notify(string.format("Saved %s:%s (etag: %s)", spec, rpath, res.etag), vim.log.levels.INFO)
end

return M
