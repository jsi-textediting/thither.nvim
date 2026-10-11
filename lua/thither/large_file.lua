--- Large file subsystem for thither.nvim [PRIORITY FEATURE].
--- Uses lineindex, read_range, apply_edit, and server-side search to provide
--- lazy, windowed editing of multi-GB files in Neovim without memory exhaustion.
local config = require("thither.config")

local M = {}

M.buffers = {} -- bufnr -> state table

--- Formats byte counts into human-readable strings (e.g. 4.2 GiB).
---@param bytes integer
---@return string
local function format_bytes(bytes)
  if bytes < 1024 then return string.format("%d B", bytes) end
  if bytes < 1024 * 1024 then return string.format("%.1f KiB", bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MiB", bytes / (1024 * 1024)) end
  return string.format("%.2f GiB", bytes / (1024 * 1024 * 1024))
end

--- Formats integer with commas (e.g. 1,234,567).
---@param n integer
---@return string
local function format_int(n)
  local s = tostring(math.floor(n))
  local left, num, right = s:match("^([^%d]*%d)(%d*)(.-)$")
  return left .. (num:reverse():gsub("(%d%d%d)", "%1,"):reverse()) .. right
end

--- Recomputes prefix sums for chunk byte offsets and line offsets.
---@param state table
local function compute_prefix_sums(state)
  local chunks = state.chunks
  local n = #chunks
  local byte_offsets = { [1] = 0 }
  local line_offsets = { [1] = 1 }

  for i = 1, n do
    byte_offsets[i + 1] = byte_offsets[i] + chunks[i][1]
    line_offsets[i + 1] = line_offsets[i] + chunks[i][2]
  end

  state.chunk_byte_offsets = byte_offsets
  state.chunk_line_offsets = line_offsets

  local total_lf = line_offsets[n + 1] - 1
  if state.size == 0 then
    state.total_lines = 0
  elseif state.ends_with_nl then
    state.total_lines = total_lf
  else
    state.total_lines = total_lf + 1
  end
end

--- Binary search for the chunk containing target line (1-based).
---@param state table
---@param target_line integer
---@return integer chunk_index
function M.get_chunk_for_line(state, target_line)
  local line_offsets = state.chunk_line_offsets
  local n = #state.chunks
  if n <= 1 or target_line <= 1 then return 1 end
  if target_line >= line_offsets[n] then return n end

  local low, high = 1, n
  local ans = 1
  while low <= high do
    local mid = math.floor((low + high) / 2)
    if line_offsets[mid] <= target_line then
      ans = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end
  return ans
end

--- Binary search for the chunk containing target byte offset (0-based).
---@param state table
---@param target_off integer
---@return integer chunk_index
function M.get_chunk_for_offset(state, target_off)
  local byte_offsets = state.chunk_byte_offsets
  local n = #state.chunks
  if n <= 1 or target_off <= 0 then return 1 end
  if target_off >= byte_offsets[n] then return n end

  local low, high = 1, n
  local ans = 1
  while low <= high do
    local mid = math.floor((low + high) / 2)
    if byte_offsets[mid] <= target_off then
      ans = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end
  return ans
end

--- Binary search for the unique chunk containing target newline index (1-based).
---@param state table
---@param target_nl integer
---@return integer chunk_index
function M.get_chunk_for_newline(state, target_nl)
  local line_offsets = state.chunk_line_offsets
  local chunks = state.chunks
  local n = #chunks
  local low, high = 1, n
  local ans = n

  while low <= high do
    local mid = math.floor((low + high) / 2)
    local before = line_offsets[mid] - 1
    local total_in = before + chunks[mid][2]
    if target_nl <= before then
      high = mid - 1
    elseif target_nl > total_in then
      low = mid + 1
    else
      return mid
    end
  end
  return ans
end

--- Resolves exact byte offset for a 1-based target line.
--- Line 1 starts at byte 0; Line L (L > 1) starts immediately after (L - 1)-th newline.
---@param state table
---@param target_line integer
---@return integer byte_offset (0-based)
function M.line_to_byte_offset(state, target_line)
  if target_line <= 1 then return 0 end
  if target_line > state.total_lines then return state.size end

  local target_nl = target_line - 1
  local k = M.get_chunk_for_newline(state, target_nl)
  local before_nl = state.chunk_line_offsets[k] - 1
  local need_in_chunk = target_nl - before_nl
  local byte_start = state.chunk_byte_offsets[k]
  local chunk_len = state.chunks[k][1]

  local data, err = state.client:call_sync("read_range", {
    path = state.rpath,
    off = byte_start,
    len = chunk_len,
    etag = state.etag,
  })

  if not data or type(data) ~= "string" then
    return byte_start
  end

  local count = 0
  local pos = 1
  while pos <= #data do
    local nl = data:find("\n", pos, true)
    if not nl then break end
    count = count + 1
    if count == need_in_chunk then
      return byte_start + nl
    end
    pos = nl + 1
  end

  return byte_start + #data
end

--- Resolves byte range [start_byte, end_byte) for lines [start_line, end_line].
---@param state table
---@param start_line integer
---@param end_line integer
---@return integer start_byte, integer end_byte
function M.line_range_to_byte_range(state, start_line, end_line)
  local start_byte = M.line_to_byte_offset(state, start_line)
  local end_byte
  if end_line >= state.total_lines then
    end_byte = state.size
  else
    end_byte = M.line_to_byte_offset(state, end_line + 1)
  end
  return start_byte, end_byte
end

--- Updates the winbar for the large file buffer.
---@param state table
local function update_winbar(state)
  if not config.get("enable_winbar", state.spec) then return end
  local w = state.window
  local pct = state.total_lines > 0 and (w.start_line / state.total_lines * 100) or 0
  local winbar_text = string.format(
    " %%#Title#Thither Large:%%* %s | %s | Lines %s - %s of %s (%.1f%%%%) ",
    vim.fs.basename(state.rpath),
    format_bytes(state.size),
    format_int(w.start_line),
    format_int(w.end_line),
    format_int(state.total_lines),
    pct
  )
  pcall(function()
    vim.wo.winbar = winbar_text
  end)
end

--- Loads a viewport window of lines [start_line, end_line] into the buffer.
---@param state table
---@param start_line integer
---@param end_line integer
---@return boolean ok, table|nil err
function M.load_window(state, start_line, end_line)
  if state.total_lines == 0 then
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
    state.window = {
      start_line = 1,
      end_line = 1,
      start_byte = 0,
      end_byte = 0,
      orig_text = "",
    }
    vim.bo[state.bufnr].modified = false
    update_winbar(state)
    return true
  end

  start_line = math.max(1, math.min(start_line, state.total_lines))
  end_line = math.max(start_line, math.min(end_line, state.total_lines))

  local start_byte, end_byte = M.line_range_to_byte_range(state, start_line, end_line)
  local len = end_byte - start_byte

  local text = ""
  if len > 0 then
    local data, err = state.client:call_sync("read_range", {
      path = state.rpath,
      off = start_byte,
      len = len,
      etag = state.etag,
    })
    if not data then
      return false, err
    end
    text = data
  end

  -- Split text into lines
  local lines = {}
  if #text == 0 then
    lines = { "" }
  else
    local pos = 1
    local text_len = #text
    while pos <= text_len do
      local nl = text:find("\n", pos, true)
      if nl then
        local line = text:sub(pos, nl - 1)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        table.insert(lines, line)
        pos = nl + 1
      else
        local line = text:sub(pos)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        table.insert(lines, line)
        break
      end
    end
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)

  state.window = {
    start_line = start_line,
    end_line = end_line,
    start_byte = start_byte,
    end_byte = end_byte,
    orig_text = text,
  }

  vim.bo[state.bufnr].modified = false
  update_winbar(state)
  return true
end

--- Opens a large file in a buffer via lineindex and viewport windowing.
---@param bufnr integer
---@param client table
---@param rpath string
---@param spec string
---@return boolean ok, table|nil err
function M.open(bufnr, client, rpath, spec)
  local chunk_size = config.get("chunk_size", spec) or 65536
  local idx, err = client:call_sync("lineindex", { path = rpath, chunk_size = chunk_size })

  -- If chunk table is too large for one frame, retry with server's suggested min_chunk_size
  if not idx and err and err.code == "too_large" and err.min_chunk_size then
    chunk_size = err.min_chunk_size
    idx, err = client:call_sync("lineindex", { path = rpath, chunk_size = chunk_size })
  end

  if not idx then
    return false, err
  end

  local window_size = config.get("window_size_lines", spec) or 5000
  local state = {
    bufnr = bufnr,
    client = client,
    rpath = rpath,
    spec = spec,
    etag = idx.etag,
    size = idx.size,
    chunks = idx.chunks,
    ends_with_nl = idx.ends_with_nl,
    chunk_size = chunk_size,
    window_size = window_size,
  }

  compute_prefix_sums(state)
  M.buffers[bufnr] = state

  -- Set buffer options
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undolevels = 1000

  -- Load initial window
  local start_line = 1
  local end_line = math.min(window_size, state.total_lines)
  local ok, load_err = M.load_window(state, start_line, end_line)
  if not ok then
    return false, load_err
  end

  -- Setup keymaps and autocommands for this buffer
  M._setup_buffer_handlers(bufnr)

  return true
end

--- Saves changes made in the current viewport window atomically via apply_edit.
---@param bufnr integer
---@return boolean ok, table|nil err
function M.save(bufnr)
  local state = M.buffers[bufnr]
  if not state then
    return false, { code = "not_found", msg = "No large file state for buffer" }
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  if state.ends_with_nl or state.window.orig_text:sub(-1) == "\n" then
    text = text .. "\n"
  end

  if text == state.window.orig_text then
    vim.bo[bufnr].modified = false
    vim.notify("No changes to save.", vim.log.levels.INFO)
    return true
  end

  -- Construct apply_edit script
  local script = {}
  local inserts = { text }

  -- Kept range before window
  if state.window.start_byte > 0 then
    table.insert(script, {
      keep = true,
      off = 0,
      len = state.window.start_byte,
    })
  end

  -- Inserted window content
  table.insert(script, { ins = 1 })

  -- Kept range after window
  if state.window.end_byte < state.size then
    table.insert(script, {
      keep = true,
      off = state.window.end_byte,
      len = state.size - state.window.end_byte,
    })
  end

  local res, err = state.client:call_sync("apply_edit", {
    path = state.rpath,
    etag = state.etag,
    script = script,
    inserts = inserts,
    chunk_size = state.chunk_size,
  })

  if not res then
    if err and err.code == "conflict" then
      vim.notify(
        string.format("Conflict! Remote file changed on host (etag: %s).", tostring(err.etag)),
        vim.log.levels.ERROR
      )
    else
      vim.notify(
        string.format("Failed to save remote file: %s", (err and err.msg) or "Unknown error"),
        vim.log.levels.ERROR
      )
    end
    return false, err
  end

  -- Update state with new file info from apply_edit
  state.etag = res.etag
  state.size = res.size
  state.chunks = res.chunks
  state.ends_with_nl = res.ends_with_nl
  compute_prefix_sums(state)
  state.window.end_line = state.window.start_line + math.max(1, #lines) - 1
  state.window.end_byte = state.window.start_byte + #text
  state.window.orig_text = text
  vim.bo[bufnr].modified = false

  update_winbar(state)
  vim.notify(
    string.format("Saved %s (new size: %s, etag: %s)", state.rpath, format_bytes(state.size), state.etag),
    vim.log.levels.INFO
  )
  return true
end

--- Jumps viewport window to target line, centering around it.
---@param bufnr integer
---@param target_line integer
---@param target_col? integer
---@return boolean
function M.goto_line(bufnr, target_line, target_col)
  local state = M.buffers[bufnr]
  if not state then return false end

  if vim.bo[bufnr].modified then
    local choice = vim.fn.confirm("Buffer has unsaved changes. Save before jumping?", "&Yes\n&No\n&Cancel", 1)
    if choice == 1 then
      local ok = M.save(bufnr)
      if not ok then return false end
    elseif choice == 3 then
      return false
    end
  end

  target_line = math.max(1, math.min(target_line, state.total_lines))
  local half = math.floor(state.window_size / 2)
  local new_start = math.max(1, target_line - half)
  local new_end = math.min(state.total_lines, new_start + state.window_size - 1)
  if new_end == state.total_lines then
    new_start = math.max(1, new_end - state.window_size + 1)
  end

  local ok, err = M.load_window(state, new_start, new_end)
  if not ok then
    vim.notify(string.format("Failed to load viewport: %s", err and err.msg or ""), vim.log.levels.ERROR)
    return false
  end

  local buf_line = target_line - state.window.start_line + 1
  local buf_col = (target_col or 1) - 1
  pcall(vim.api.nvim_win_set_cursor, 0, { buf_line, buf_col })
  return true
end

--- Jumps viewport window to percentage of total file.
---@param bufnr integer
---@param pct number (0 - 100)
---@return boolean
function M.goto_percent(bufnr, pct)
  local state = M.buffers[bufnr]
  if not state or state.total_lines == 0 then return false end
  local target_line = math.max(1, math.floor(state.total_lines * pct / 100))
  return M.goto_line(bufnr, target_line)
end

--- Pages forward by one viewport window.
---@param bufnr integer
function M.page_next(bufnr)
  local state = M.buffers[bufnr]
  if not state then return end
  local step = math.floor(state.window_size * 0.75)
  M.goto_line(bufnr, state.window.start_line + step)
end

--- Pages backward by one viewport window.
---@param bufnr integer
function M.page_prev(bufnr)
  local state = M.buffers[bufnr]
  if not state then return end
  local step = math.floor(state.window_size * 0.75)
  M.goto_line(bufnr, math.max(1, state.window.start_line - step))
end

--- Executes server-side search across the entire multi-GB file and streams into Quickfix.
---@param bufnr integer
---@param pattern string
---@param opts? table { regex?: boolean, case?: boolean, limit?: integer }
---@return boolean ok, table|nil err
function M.search(bufnr, pattern, opts)
  local state = M.buffers[bufnr]
  if not state then
    return false, { code = "not_found", msg = "No large file state for buffer" }
  end

  opts = opts or {}
  local res, err = state.client:call_sync("search", {
    path = state.rpath,
    pattern = pattern,
    opts = {
      regex = opts.regex or false,
      case = opts.case == nil and true or opts.case,
      limit = opts.limit or 1000,
    },
    etag = state.etag,
  })

  if not res then
    vim.notify(string.format("Search error: %s", (err and err.msg) or "Unknown error"), vim.log.levels.ERROR)
    return false, err
  end

  if #res == 0 then
    vim.notify(string.format("No matches found for '%s'", pattern), vim.log.levels.WARN)
    return true
  end

  local qf_items = {}
  for _, m in ipairs(res) do
    table.insert(qf_items, {
      bufnr = bufnr,
      lnum = m.line,
      col = m.col,
      text = string.format("[Thither] match '%s' (line %s, col %s, off %s)", pattern, format_int(m.line), tostring(m.col), tostring(m.off)),
    })
  end

  state.search_matches = res
  state.search_idx = 1

  vim.fn.setqflist(qf_items, "r")
  vim.notify(string.format("Found %d matches for '%s'. Opening quickfix list.", #res, pattern), vim.log.levels.INFO)
  vim.cmd("copen")

  return true
end

--- Jumps to the next search match in the large file buffer.
---@param bufnr integer
---@return boolean
function M.search_next(bufnr)
  local state = M.buffers[bufnr]
  if not state or not state.search_matches or #state.search_matches == 0 then
    vim.notify("No active search matches.", vim.log.levels.WARN)
    return false
  end

  state.search_idx = (state.search_idx % #state.search_matches) + 1
  local m = state.search_matches[state.search_idx]
  return M.goto_line(bufnr, m.line, m.col)
end

--- Jumps to the previous search match in the large file buffer.
---@param bufnr integer
---@return boolean
function M.search_prev(bufnr)
  local state = M.buffers[bufnr]
  if not state or not state.search_matches or #state.search_matches == 0 then
    vim.notify("No active search matches.", vim.log.levels.WARN)
    return false
  end

  state.search_idx = state.search_idx - 1
  if state.search_idx < 1 then
    state.search_idx = #state.search_matches
  end
  local m = state.search_matches[state.search_idx]
  return M.goto_line(bufnr, m.line, m.col)
end

--- Registers buffer-local commands and mappings for large file interaction.
---@param bufnr integer
function M._setup_buffer_handlers(bufnr)
  local opts = { buffer = bufnr, silent = true }

  -- Navigation keybindings inside large file viewport buffer
  vim.keymap.set("n", "]p", function() M.page_next(bufnr) end, vim.tbl_extend("force", opts, { desc = "Thither next page" }))
  vim.keymap.set("n", "[p", function() M.page_prev(bufnr) end, vim.tbl_extend("force", opts, { desc = "Thither prev page" }))

  -- Window refresh on CursorMoved if entering margin
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    once = true,
    callback = function()
      M.buffers[bufnr] = nil
    end,
  })
end

return M
