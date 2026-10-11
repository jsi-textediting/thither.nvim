--- Remote filesystem operations for thither.nvim.
local M = {}

--- Retrieves stat table for a path.
---@param client table
---@param path string
---@param nofollow? boolean
---@return table|nil stat, table|nil err
function M.stat(client, path, nofollow)
  return client:call_sync("stat", { path = path, nofollow = nofollow })
end

--- Reads a slice of a file.
---@param client table
---@param path string
---@param offset integer
---@param len integer
---@param etag? string
---@return table|nil res, table|nil err
function M.read(client, path, offset, len, etag)
  return client:call_sync("read", {
    path = path,
    offset = offset or 0,
    len = len,
    etag = etag,
  })
end

--- Reads the entire content of a file (up to normal file threshold).
---@param client table
---@param path string
---@return string|nil data, string|nil etag, table|nil err
function M.read_all(client, path)
  local parts = {}
  local offset = 0
  local chunk_size = 256 * 1024 -- 256 KiB
  local etag = nil

  while true do
    local res, err = client:call_sync("read", {
      path = path,
      offset = offset,
      len = chunk_size,
      etag = etag,
    })
    if not res then
      return nil, nil, err
    end

    etag = res.etag
    table.insert(parts, res.data)
    offset = offset + #res.data

    if res.eof or #res.data == 0 then
      break
    end
  end

  return table.concat(parts), etag, nil
end

--- Writes a file atomically with optional conflict checking.
---@param client table
---@param path string
---@param data string
---@param if_match? string
---@param mode? integer
---@param create_dirs? boolean
---@return table|nil stat, table|nil err
function M.write(client, path, data, if_match, mode, create_dirs)
  return client:call_sync("write", {
    path = path,
    data = data,
    if_match = if_match,
    mode = mode,
    create_dirs = create_dirs == nil and true or create_dirs,
  })
end

--- Lists directory entries.
---@param client table
---@param path string
---@param offset? integer
---@param limit? integer
---@return table|nil res, table|nil err
function M.readdir(client, path, offset, limit)
  local entries = {}
  local cur_offset = offset or 0
  local batch_limit = limit or 5000

  while true do
    local res, err = client:call_sync("readdir", {
      path = path,
      offset = cur_offset,
      limit = batch_limit,
    })
    if not res then
      return nil, err
    end

    for _, entry in ipairs(res.entries or {}) do
      table.insert(entries, entry)
    end

    if not res.more or (limit and #entries >= limit) then
      return { entries = entries, total = res.total }, nil
    end
    cur_offset = res.offset + #(res.entries or {})
  end
end

--- Creates a directory.
---@param client table
---@param path string
---@param parents? boolean
---@return boolean ok, table|nil err
function M.mkdir(client, path, parents)
  return client:call_sync("mkdir", {
    path = path,
    parents = parents == nil and true or parents,
  })
end

--- Removes a file or directory.
---@param client table
---@param path string
---@param recursive? boolean
---@return boolean ok, table|nil err
function M.remove(client, path, recursive)
  return client:call_sync("remove", {
    path = path,
    recursive = recursive or false,
  })
end

--- Renames a file or directory.
---@param client table
---@param from string
---@param to string
---@param overwrite? boolean
---@return boolean ok, table|nil err
function M.rename(client, from, to, overwrite)
  return client:call_sync("rename", {
    from = from,
    to = to,
    overwrite = overwrite == nil and true or overwrite,
  })
end

--- Copies a file.
---@param client table
---@param from string
---@param to string
---@param overwrite? boolean
---@return table|nil stat, table|nil err
function M.copy(client, from, to, overwrite)
  return client:call_sync("copy", {
    from = from,
    to = to,
    overwrite = overwrite == nil and true or overwrite,
  })
end

--- Resolves symlinks and normalizes path on remote host.
---@param client table
---@param path string
---@return string|nil realpath, table|nil err
function M.realpath(client, path)
  return client:call_sync("realpath", { path = path })
end

return M
