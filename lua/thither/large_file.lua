--- Large file subsystem for thither.nvim [PRIORITY FEATURE].
--- Uses lineindex, read_range, apply_edit, and server-side search to provide
--- lazy, windowed editing of multi-GB files in Neovim without memory exhaustion.
local config = require("thither.config")
local text_util = require("thither.text")

local M = {}

M.buffers = {} -- bufnr -> state table

--- Server limit for one read_range request (protocol.md: len <= 8 MiB).
M.MAX_READ = 8 * 1024 * 1024

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

--- Returns a ready client for the state, reconnecting if the old connection died.
---@param state table
---@return table|nil client, table|nil err
local function client_of(state)
  if state.client and state.client:is_ready() then
    return state.client
  end
  local c, err = require("thither.client").ensure(state.spec)
  if not c then return nil, err end
  state.client = c
  return c
end

--- Synchronous request on the state's (possibly re-established) connection.
local function rpc(state, op, args)
  local c, err = client_of(state)
  if not c then return nil, err end
  return c:call_sync(op, args)
end

--- Reads [off, off+len) of the file, split into read_range requests of at
--- most M.MAX_READ bytes. Returns fewer bytes at end of file.
---@param state table
---@param off integer
---@param len integer
---@return string|nil data, table|nil err
function M.read_bytes(state, off, len)
  local parts = {}
  local got = 0
  while got < len do
    local n = math.min(M.MAX_READ, len - got)
    local data, err = rpc(state, "read_range", {
      path = state.rpath,
      off = off + got,
      len = n,
      etag = state.etag,
    })
    if type(data) ~= "string" then
      return nil, err or { code = "bad_response", msg = "read_range returned no data" }
    end
    parts[#parts + 1] = data
    got = got + #data
    if #data < n then break end -- end of file
  end
  return table.concat(parts)
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
---@return integer|nil byte_offset (0-based), table|nil err
function M.line_to_byte_offset(state, target_line)
  if target_line <= 1 then return 0 end
  if target_line > state.total_lines then return state.size end

  local target_nl = target_line - 1
  local k = M.get_chunk_for_newline(state, target_nl)
  local before_nl = state.chunk_line_offsets[k] - 1
  local need_in_chunk = target_nl - before_nl
  local byte_start = state.chunk_byte_offsets[k]
  local chunk_len = state.chunks[k][1]

  local data, err = M.read_bytes(state, byte_start, chunk_len)
  if not data then
    return nil, err
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

  return nil, { code = "bad_index", msg = "line index does not match the file (reopen it)" }
end

--- Resolves byte range [start_byte, end_byte) for lines [start_line, end_line].
---@param state table
---@param start_line integer
---@param end_line integer
---@return integer|nil start_byte, integer|table end_byte_or_err
function M.line_range_to_byte_range(state, start_line, end_line)
  local start_byte, err = M.line_to_byte_offset(state, start_line)
  if not start_byte then return nil, err end
  local end_byte
  if end_line >= state.total_lines then
    end_byte = state.size
  else
    end_byte, err = M.line_to_byte_offset(state, end_line + 1)
    if not end_byte then return nil, err end
  end
  return start_byte, end_byte
end

--- Updates the winbar of every window showing the large file buffer.
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
  for _, win in ipairs(vim.fn.win_findbuf(state.bufnr)) do
    pcall(vim.api.nvim_set_option_value, "winbar", winbar_text, { scope = "local", win = win })
  end
end

--- Sets the buffer to a window's text: no undo entry, Vim-like 'fileformat'
--- detection, 'endofline' from the file when the window reaches EOF.
local function show_window(state, text)
  local bufnr = state.bufnr
  local lines, ff, eol = text_util.split(text)
  local at_eof = state.window.end_byte >= state.size
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].fileformat = ff
  -- A window that does not reach EOF is always followed by more lines.
  vim.bo[bufnr].endofline = (not at_eof) or eol
  text_util.set_lines_no_undo(bufnr, lines)
  vim.bo[bufnr].modified = false
  update_winbar(state)
end

--- Loads a viewport window of lines [start_line, end_line] into the buffer.
--- The window is also capped at `window_max_bytes`; a single line longer than
--- that is loaded whole up to `max_line_bytes`.
---@param state table
---@param start_line integer
---@param end_line integer
---@return boolean ok, table|nil err
function M.load_window(state, start_line, end_line)
  if state.total_lines == 0 then
    state.window = {
      start_line = 1,
      end_line = 1,
      start_byte = 0,
      end_byte = 0,
      orig_text = "",
    }
    show_window(state, "")
    return true
  end

  start_line = math.max(1, math.min(start_line, state.total_lines))
  end_line = math.max(start_line, math.min(end_line, state.total_lines))

  local start_byte, end_byte = M.line_range_to_byte_range(state, start_line, end_line)
  if not start_byte then return false, end_byte end

  local max_bytes = config.get("window_max_bytes", state.spec) or (4 * 1024 * 1024)
  local max_line = config.get("max_line_bytes", state.spec) or (64 * 1024 * 1024)

  local text, err
  if end_byte - start_byte > max_bytes then
    -- Too many bytes for one window: keep only the complete lines that fit.
    text, err = M.read_bytes(state, start_byte, max_bytes)
    if not text then return false, err end
    local last_nl
    local pos = 1
    while true do
      local nl = text:find("\n", pos, true)
      if not nl then break end
      last_nl = nl
      pos = nl + 1
    end
    if last_nl then
      text = text:sub(1, last_nl)
      local _, n = text:gsub("\n", "")
      end_line = start_line + n - 1
      end_byte = start_byte + #text
    else
      -- One line longer than the window cap: load just that line.
      end_line = start_line
      if start_line >= state.total_lines then
        end_byte = state.size
      else
        end_byte, err = M.line_to_byte_offset(state, start_line + 1)
        if not end_byte then return false, err end
      end
      if end_byte - start_byte > max_line then
        return false, {
          code = "too_large",
          msg = string.format("line %d is %s long (max_line_bytes is %s)", start_line,
            format_bytes(end_byte - start_byte), format_bytes(max_line)),
        }
      end
      text, err = M.read_bytes(state, start_byte, end_byte - start_byte)
      if not text then return false, err end
    end
  elseif end_byte > start_byte then
    text, err = M.read_bytes(state, start_byte, end_byte - start_byte)
    if not text then return false, err end
  else
    text = ""
  end

  if #text ~= end_byte - start_byte then
    return false, { code = "stale", msg = "file is shorter than its line index (reopen it)" }
  end

  state.window = {
    start_line = start_line,
    end_line = end_line,
    start_byte = start_byte,
    end_byte = end_byte,
    orig_text = text,
  }
  show_window(state, text)
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

  -- Set buffer options
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].swapfile = false

  -- Load initial window
  local ok, load_err = M.load_window(state, 1, math.min(window_size, state.total_lines))
  if not ok then
    return false, load_err
  end
  M.buffers[bufnr] = state

  -- Setup keymaps and autocommands for this buffer
  M._setup_buffer_handlers(bufnr)

  return true
end

--- Builds the text of the current window and the apply_edit script that
--- replaces the window's original bytes with it.
---@return string text, table script, table inserts
local function build_edit(state, bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local w = state.window
  local text
  if w.end_byte < state.size then
    -- More lines follow the window: its last line always keeps its line break.
    text = text_util.join(lines, vim.bo[bufnr].fileformat, true)
  elseif #lines == 1 and lines[1] == "" and not vim.bo[bufnr].endofline then
    text = ""
  else
    text = text_util.join(lines, vim.bo[bufnr].fileformat, text_util.want_eol(bufnr))
  end

  local script = {}
  if w.start_byte > 0 then
    table.insert(script, { keep = true, off = 0, len = w.start_byte })
  end
  table.insert(script, { ins = 1 })
  if w.end_byte < state.size then
    table.insert(script, { keep = true, off = w.end_byte, len = state.size - w.end_byte })
  end
  return text, script, { text }, lines
end

local function notify_save_error(err)
  if err and err.code == "conflict" then
    vim.notify(
      string.format("Conflict! Remote file changed on host (etag: %s).", tostring(err.etag)),
      vim.log.levels.ERROR
    )
  elseif err and err.code == "EEXIST" then
    vim.notify("E13: File exists (add ! to override)", vim.log.levels.ERROR)
  else
    vim.notify(
      string.format("Failed to save remote file: %s", (err and err.msg) or "Unknown error"),
      vim.log.levels.ERROR
    )
  end
end

--- Adopts an apply_edit result as the buffer's new backing file.
local function adopt_result(state, res, text, lines)
  state.etag = res.etag
  state.size = res.size
  state.chunks = res.chunks
  state.ends_with_nl = res.ends_with_nl
  compute_prefix_sums(state)
  state.window.end_line = state.window.start_line + math.max(1, #lines) - 1
  state.window.end_byte = state.window.start_byte + #text
  state.window.orig_text = text
  if state.total_lines == 0 then
    state.window.end_line = 1
  end
  vim.bo[state.bufnr].modified = false
  update_winbar(state)
end

--- Saves changes made in the current viewport window atomically via apply_edit.
---@param bufnr integer
---@return boolean ok, table|nil err
function M.save(bufnr)
  local state = M.buffers[bufnr]
  if not state then
    return false, { code = "not_found", msg = "No large file state for buffer" }
  end

  local text, script, inserts, lines = build_edit(state, bufnr)
  if text == state.window.orig_text or not vim.bo[bufnr].modified then
    vim.bo[bufnr].modified = false
    vim.notify("No changes to save.", vim.log.levels.INFO)
    return true
  end

  local res, err = rpc(state, "apply_edit", {
    path = state.rpath,
    etag = state.etag,
    script = script,
    inserts = inserts,
    chunk_size = state.chunk_size,
  })

  if not res then
    notify_save_error(err)
    return false, err
  end

  adopt_result(state, res, text, lines)
  vim.notify(
    string.format("Saved %s (new size: %s, etag: %s)", state.rpath, format_bytes(state.size), state.etag),
    vim.log.levels.INFO
  )
  return true
end

--- Writes the whole edited file (original plus the window's edits) to another
--- path on the same host via apply_edit `dest` ("save as").
---@param bufnr integer
---@param spec string target host spec
---@param dest string target remote path
---@param opts? table { overwrite?: boolean, switch?: boolean } switch: the buffer now edits `dest`
---@return boolean ok, table|nil err
function M.save_as(bufnr, spec, dest, opts)
  opts = opts or {}
  local state = M.buffers[bufnr]
  if not state then
    return false, { code = "not_found", msg = "No large file state for buffer" }
  end
  local function refuse(msg)
    vim.notify(msg, vim.log.levels.ERROR)
    return false, { code = "unsupported", msg = msg }
  end
  if spec ~= state.spec then
    return refuse("Large-file buffers can only be written to another path on the same host")
  end
  local client, cerr = client_of(state)
  if not client then
    notify_save_error(cerr)
    return false, cerr
  end
  if not client.caps.apply_edit_dest then
    return refuse("Server lacks the apply_edit_dest capability; cannot write a large file to another name")
  end

  local text, script, inserts, lines = build_edit(state, bufnr)
  local res, err = client:call_sync("apply_edit", {
    path = state.rpath,
    etag = state.etag,
    script = script,
    inserts = inserts,
    chunk_size = state.chunk_size,
    dest = dest,
    dest_if_match = (not opts.overwrite) and "-" or nil,
  })
  if not res then
    notify_save_error(err)
    return false, err
  end

  if opts.switch then
    state.rpath = dest
    adopt_result(state, res, text, lines)
  end
  vim.notify(string.format("Written %s:%s (%s)", spec, dest, format_bytes(res.size)), vim.log.levels.INFO)
  return true
end

--- Returns a window id showing `bufnr`, preferring the current window.
local function win_for(bufnr)
  if vim.api.nvim_win_get_buf(0) == bufnr then
    return vim.api.nvim_get_current_win()
  end
  local wins = vim.fn.win_findbuf(bufnr)
  return wins[1]
end

local function set_cursor(state, target_line, target_col)
  local win = win_for(state.bufnr)
  if not win then return end
  local buf_line = target_line - state.window.start_line + 1
  local buf_col = math.max(0, (target_col or 1) - 1)
  pcall(vim.api.nvim_win_set_cursor, win, { buf_line, buf_col })
end

--- Asks to save pending changes before the window is replaced.
---@return boolean proceed
local function confirm_leave(bufnr)
  if not vim.bo[bufnr].modified then return true end
  local choice = vim.fn.confirm("Buffer has unsaved changes. Save before jumping?", "&Yes\n&No\n&Cancel", 1)
  if choice == 1 then
    return (M.save(bufnr))
  end
  return choice == 2
end

--- Loads the window [start_line, start_line + window_size) and reports errors.
local function load_from(state, start_line)
  local ok, err = M.load_window(state, start_line, start_line + state.window_size - 1)
  if not ok then
    vim.notify(string.format("Failed to load viewport: %s", err and err.msg or ""), vim.log.levels.ERROR)
  end
  return ok
end

--- Jumps viewport window to target line, centering around it.
---@param bufnr integer
---@param target_line integer
---@param target_col? integer
---@return boolean
function M.goto_line(bufnr, target_line, target_col)
  local state = M.buffers[bufnr]
  if not state then return false end

  target_line = math.max(1, math.min(target_line, math.max(1, state.total_lines)))
  local w = state.window
  -- Already visible: just move the cursor (no reload, unsaved edits are kept).
  if target_line >= w.start_line and target_line <= w.end_line then
    set_cursor(state, target_line, target_col)
    return true
  end

  if not confirm_leave(bufnr) then return false end

  local half = math.floor(state.window_size / 2)
  local new_start = math.max(1, target_line - half)
  local new_end = math.min(state.total_lines, new_start + state.window_size - 1)
  if new_end == state.total_lines then
    new_start = math.max(1, new_end - state.window_size + 1)
  end

  local ok, err = M.load_window(state, new_start, new_end)
  if ok and target_line > state.window.end_line then
    -- The byte cap shortened the window before the target: start at it.
    ok, err = M.load_window(state, target_line, target_line + state.window_size - 1)
  end
  if not ok then
    vim.notify(string.format("Failed to load viewport: %s", err and err.msg or ""), vim.log.levels.ERROR)
    return false
  end

  set_cursor(state, target_line, target_col)
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

--- Pages forward: the new window starts a quarter window before the end of
--- the current one (so some context stays visible).
---@param bufnr integer
function M.page_next(bufnr)
  local state = M.buffers[bufnr]
  if not state then return end
  local w = state.window
  if w.end_line >= state.total_lines then return end
  if not confirm_leave(bufnr) then return end
  local overlap = math.floor((w.end_line - w.start_line + 1) / 4)
  local new_start = math.max(w.start_line + 1, w.end_line + 1 - overlap)
  if load_from(state, new_start) then
    set_cursor(state, state.window.start_line)
  end
end

--- Pages backward by about three quarters of a window.
---@param bufnr integer
function M.page_prev(bufnr)
  local state = M.buffers[bufnr]
  if not state then return end
  local w = state.window
  if w.start_line <= 1 then return end
  if not confirm_leave(bufnr) then return end
  local step = math.floor(state.window_size * 0.75)
  local new_start = math.max(1, w.start_line - step)
  if load_from(state, new_start) then
    set_cursor(state, math.min(w.start_line, state.window.end_line))
  end
end

--- Key identifying the current quickfix entry.
local function qf_key()
  local info = vim.fn.getqflist({ id = 0, idx = 0 })
  return string.format("%d:%d", info.id or 0, info.idx or 0)
end

--- Called on BufEnter/CursorMoved of a large buffer: when the current
--- quickfix entry changed and refers to an absolute line of this buffer
--- (search results), move the viewport there. This makes :cnext, :cc, <CR>
--- in the quickfix window, etc. land on the right line.
---@param bufnr integer
function M.sync_quickfix(bufnr)
  local state = M.buffers[bufnr]
  if not state or state.syncing then return end
  local key = qf_key()
  if key == state.qf_key then return end
  state.qf_key = key
  local info = vim.fn.getqflist({ id = 0, idx = 0, items = 0 })
  local item = info.items and info.items[info.idx]
  local ud = item and item.user_data
  if type(ud) ~= "table" or ud.thither_large ~= bufnr or item.bufnr ~= bufnr then return end
  state.syncing = true
  pcall(M.goto_line, bufnr, ud.line, ud.col)
  state.syncing = false
end

--- Runs sync_quickfix once the current command has finished. A quickfix
--- command (:cnext, :cc, <CR> in the quickfix window) fires BufEnter before
--- it puts the cursor on the entry's (clamped) line, so syncing right away
--- would be undone by that cursor move.
---@param bufnr integer
function M.schedule_sync(bufnr)
  local state = M.buffers[bufnr]
  if not state or state.sync_pending then return end
  state.sync_pending = true
  vim.schedule(function()
    local s = M.buffers[bufnr]
    if not s then return end
    s.sync_pending = false
    if vim.api.nvim_get_current_buf() == bufnr then
      M.sync_quickfix(bufnr)
    end
  end)
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
  local res, err = rpc(state, "search", {
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
      user_data = { thither_large = bufnr, line = m.line, col = m.col, off = m.off },
    })
  end

  state.search_matches = res
  vim.fn.setqflist(qf_items, "r")
  -- Like :vimgrep, go to the first match; later quickfix moves are followed
  -- by sync_quickfix.
  state.search_idx = 1
  state.qf_key = qf_key()
  M.goto_line(bufnr, res[1].line, res[1].col)
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

  local group = vim.api.nvim_create_augroup("thither_large_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.schedule_sync(bufnr)
    end,
  })
  -- ":cnext" whose target is past the window leaves the cursor where it was
  -- when it already is on the window's last line: no CursorMoved. Check
  -- after every Ex command line instead.
  if not M._cmdline_autocmd then
    M._cmdline_autocmd = vim.api.nvim_create_autocmd("CmdlineLeave", {
      group = vim.api.nvim_create_augroup("thither_large_cmdline", { clear = true }),
      pattern = ":",
      callback = function()
        vim.schedule(function()
          local b = vim.api.nvim_get_current_buf()
          if M.buffers[b] then M.schedule_sync(b) end
        end)
      end,
    })
  end
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      M.buffers[bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M
