--- Buffer URI router and event handlers for thither:// protocol.
local Client = require("thither.client")
local vfs = require("thither.vfs")
local config = require("thither.config")
local large_file = require("thither.large_file")
local dir_browser = require("thither.dir_browser")
local text_util = require("thither.text")

local M = {}

--- Buffers that :ThitherLargeEdit wants opened in large-file mode on their
--- next BufReadCmd, whatever their size. bufnr -> true
M.force_large = {}

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

--- Connects (or reconnects) to `spec`, reporting failures.
---@return table|nil client
local function connect(spec)
  local client, err = Client.ensure(spec)
  if not client then
    vim.notify(
      string.format("Failed to connect to '%s': %s", spec, (err and err.msg) or "timeout"),
      vim.log.levels.ERROR
    )
  end
  return client
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

  local client = connect(spec)
  if not client then return end

  local force_large = M.force_large[bufnr]
  M.force_large[bufnr] = nil

  -- Query remote stat
  local st, err = vfs.stat(client, rpath)

  if not st and err and err.code == "ENOENT" then
    -- Missing file: allow editing as new file
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].endofline = false
    -- The remote host is POSIX: a new file gets LF line endings, not the
    -- first 'fileformats' entry of the local system ("dos" on Windows).
    vim.bo[bufnr].fileformat = "unix"
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
  if force_large or st.size >= threshold then
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

  local lines, ff, eol = text_util.split(data)
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].fileformat = ff
  vim.bo[bufnr].endofline = eol
  text_util.set_lines_no_undo(bufnr, lines)

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].modified = false

  vim.b[bufnr].thither_spec = spec
  vim.b[bufnr].thither_rpath = rpath
  vim.b[bufnr].thither_etag = etag

  -- Match filetype
  pcall(function()
    local ft = vim.filetype.match({ buf = bufnr, filename = rpath })
    if ft then vim.bo[bufnr].filetype = ft end
  end)
end

--- Handler for FileReadCmd thither://* (":[N]read thither://..."): inserts the
--- remote file below line '[ of the current buffer, which keeps its options
--- and variables. Like netrw, ":0read" inserts below line 1 because Vim sets
--- '[ to 1 for both.
---@param uri string
function M.on_file_read(uri)
  local spec, rpath = M.parse_uri(uri)
  if not spec or not rpath then
    vim.notify("Invalid thither URI: " .. uri, vim.log.levels.ERROR)
    return
  end
  local client = connect(spec)
  if not client then return end

  local st, err = vfs.stat(client, rpath)
  if not st then
    vim.notify(string.format("Failed to read '%s:%s': %s", spec, rpath, err and err.msg or "unknown error"), vim.log.levels.ERROR)
    return
  end
  if st.type == "dir" then
    vim.notify(string.format("'%s:%s' is a directory", spec, rpath), vim.log.levels.ERROR)
    return
  end
  local threshold = config.get("large_file_threshold", spec) or (10 * 1024 * 1024)
  if st.size >= threshold then
    vim.notify(string.format("'%s:%s' is too large for :read (%d bytes)", spec, rpath, st.size), vim.log.levels.ERROR)
    return
  end

  local data, _, rerr = vfs.read_all(client, rpath)
  if not data then
    vim.notify(string.format("Failed to read '%s': %s", rpath, (rerr and rerr.msg) or "unknown error"), vim.log.levels.ERROR)
    return
  end
  if data == "" then return end

  local lines = text_util.split(data)
  local after = vim.fn.line("'[")
  local count = vim.api.nvim_buf_line_count(0)
  after = math.max(0, math.min(after, count))
  vim.api.nvim_buf_set_lines(0, after, after, false, lines)
  pcall(vim.api.nvim_buf_set_mark, 0, "[", after + 1, 0, {})
  pcall(vim.api.nvim_buf_set_mark, 0, "]", after + #lines, 0, {})
end

--- True when two URIs name the same remote file.
local function same_target(spec_a, rpath_a, spec_b, rpath_b)
  return spec_a ~= nil and spec_a == spec_b and rpath_a == rpath_b
end

--- Handler for BufWriteCmd / FileWriteCmd thither://*.
--- Writes to the name the command was given (`target`, <amatch>) and, for
--- FileWriteCmd, only the lines '[ .. '] of the buffer.
---@param bufnr integer
---@param target string
---@param event? string "BufWriteCmd" | "FileWriteCmd"
function M.on_write(bufnr, target, event)
  local tspec, trpath = M.parse_uri(target or "")
  if not tspec or not trpath then
    vim.notify("Invalid thither URI: " .. tostring(target), vim.log.levels.ERROR)
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local first, last = 1, line_count
  if event == "FileWriteCmd" then
    first, last = vim.fn.line("'["), vim.fn.line("']")
  end
  local whole = first == 1 and last == line_count
  local bang = vim.v.cmdbang == 1

  -- Is the target the buffer's own name? (":w", ":saveas new" renames the buffer first)
  local bspec, brpath = M.parse_uri(vim.api.nvim_buf_get_name(bufnr))
  local own = same_target(tspec, trpath, bspec, brpath)

  -- 1. Large file buffers
  local lstate = large_file.buffers[bufnr]
  if lstate then
    if not whole then
      vim.notify("Partial writes are not supported in large-file buffers", vim.log.levels.ERROR)
      return
    end
    if own and same_target(tspec, trpath, lstate.spec, lstate.rpath) then
      large_file.save(bufnr)
    else
      large_file.save_as(bufnr, tspec, trpath, { overwrite = bang, switch = own })
    end
    return
  end

  -- 2. Normal file write
  if own and not whole and not bang then
    vim.notify("E140: Use ! to write partial buffer", vim.log.levels.ERROR)
    return
  end

  local client = connect(tspec)
  if not client then return end

  -- The file this buffer was read from (if any) and its etag.
  local tracked = same_target(tspec, trpath, vim.b[bufnr].thither_spec, vim.b[bufnr].thither_rpath)
  local if_match
  if bang then
    -- ":w!" writes even when the file changed on the host since it was read
    if_match = nil
  elseif tracked then
    -- etag of the version we read; "-" for a file that did not exist
    if_match = vim.b[bufnr].thither_etag or "-"
  else
    if_match = "-" -- like Vim: do not overwrite an existing file without !
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local ff = vim.bo[bufnr].fileformat
  local data
  if last < line_count then
    data = text_util.join(lines, ff, true)
  elseif whole and #lines == 1 and lines[1] == "" and not vim.bo[bufnr].endofline then
    data = "" -- empty buffer, empty file
  else
    data = text_util.join(lines, ff, text_util.want_eol(bufnr))
  end

  local res, err = vfs.write(client, trpath, data, if_match, nil, true)
  if not res then
    if err and err.code == "conflict" and if_match == "-" then
      vim.notify(string.format("E13: File exists (add ! to override): %s:%s", tspec, trpath), vim.log.levels.ERROR)
    elseif err and err.code == "conflict" then
      vim.notify(
        string.format("Conflict! File on host changed (current etag: %s); :w! to overwrite, :e! to reload.", tostring(err.etag)),
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

  if own then
    vim.b[bufnr].thither_spec = tspec
    vim.b[bufnr].thither_rpath = trpath
    vim.b[bufnr].thither_etag = res.etag
    if whole then
      vim.bo[bufnr].buftype = "acwrite"
      vim.bo[bufnr].modified = false
    end
  elseif tracked then
    -- partial or renamed write over the tracked file: remember its new etag
    vim.b[bufnr].thither_etag = res.etag
  end
  vim.notify(string.format("Written %s:%s (%d lines, etag: %s)", tspec, trpath, #lines, res.etag), vim.log.levels.INFO)
end

--- Backwards compatible entry point: writes the whole buffer to its own name.
---@param bufnr integer
function M.on_buf_write(bufnr)
  M.on_write(bufnr, vim.api.nvim_buf_get_name(bufnr), "BufWriteCmd")
end

return M
