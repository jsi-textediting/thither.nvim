-- Comprehensive tests for the Large File Subsystem [PRIORITY FEATURE]
local Client = require("thither.client")
local large_file = require("thither.large_file")
local config = require("thither.config")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: %s (%s ~= %s)", msg or "", vim.inspect(a), vim.inspect(b)))
  end
end

local function run()
  print("Running test_large_file.lua...")
  config.setup({
    server_path = "./thither/build/thither-server",
    chunk_size = 4096, -- Small chunk size so test file spans many chunks
    window_size_lines = 100,
  })

  local client = Client.new("local:")
  local ready = false
  client:connect(function() ready = true end)
  vim.wait(2000, function() return ready end)

  -- 1. Create a synthetic large test file (5,000 lines across ~15 chunks)
  local tmp_file = vim.fn.tempname()
  local f = io.open(tmp_file, "w")
  for i = 1, 5000 do
    if i == 1234 then
      f:write("SPECIAL_MARKER_ALPHA at line 1234\n")
    elseif i == 4567 then
      f:write("SPECIAL_MARKER_BETA at line 4567\n")
    else
      f:write(string.format("This is line number %05d of the test file padding text\n", i))
    end
  end
  f:close()

  -- 2. Open file with large_file.open
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ok, err = large_file.open(bufnr, client, tmp_file, "local:")
  if not ok then error("large_file.open failed: " .. vim.inspect(err)) end

  local state = large_file.buffers[bufnr]
  assert_eq(type(state), "table", "state exists")
  assert_eq(state.total_lines, 5000, "total lines is 5000")
  assert_eq(#state.chunks > 10, true, "spans multiple chunks")

  -- 3. Verify chunk lookup and byte offsets
  local chunk_for_1 = large_file.get_chunk_for_line(state, 1)
  assert_eq(chunk_for_1, 1, "line 1 is in chunk 1")

  local chunk_for_end = large_file.get_chunk_for_line(state, 5000)
  assert_eq(chunk_for_end, #state.chunks, "line 5000 is in last chunk")

  -- Verify line to byte offset for line 10
  local off_1 = large_file.line_to_byte_offset(state, 1)
  assert_eq(off_1, 0, "line 1 starts at byte 0")

  -- Check initial window lines in buffer (window 1 .. 100)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert_eq(#lines, 100, "initial window has 100 lines")
  assert_eq(lines[1], "This is line number 00001 of the test file padding text", "first line content")

  -- 4. Test goto_line jumps viewport
  local goto_ok = large_file.goto_line(bufnr, 1234)
  assert_eq(goto_ok, true, "goto_line succeeded")
  assert_eq(state.window.start_line <= 1234, true, "start_line <= 1234")
  assert_eq(state.window.end_line >= 1234, true, "end_line >= 1234")

  local win_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local marker_found = false
  for _, l in ipairs(win_lines) do
    if l == "SPECIAL_MARKER_ALPHA at line 1234" then
      marker_found = true
      break
    end
  end
  assert_eq(marker_found, true, "viewport contains marker line 1234")

  -- 5. Test in-window edit and atomic save via apply_edit
  -- Edit line 1234 in the buffer
  local buf_line_idx = 1234 - state.window.start_line
  vim.api.nvim_buf_set_lines(bufnr, buf_line_idx, buf_line_idx + 1, false, { "MODIFIED_ALPHA_CONTENT" })
  assert_eq(vim.bo[bufnr].modified, true, "buffer is marked modified")

  local save_ok, save_err = large_file.save(bufnr)
  if not save_ok then error("large_file.save failed: " .. vim.inspect(save_err)) end
  assert_eq(vim.bo[bufnr].modified, false, "buffer modified cleared after save")

  -- Read file directly from disk to verify atomic replacement
  local rf = io.open(tmp_file, "r")
  local all_disk = rf:read("*all")
  rf:close()

  assert_eq(all_disk:find("MODIFIED_ALPHA_CONTENT", 1, true) ~= nil, true, "disk contains edited text")
  assert_eq(all_disk:find("SPECIAL_MARKER_ALPHA", 1, true), nil, "original marker replaced")
  assert_eq(all_disk:find("SPECIAL_MARKER_BETA at line 4567", 1, true) ~= nil, true, "other parts of file untouched")

  -- 6. Test server-side search across entire file
  local search_ok, search_err = large_file.search(bufnr, "SPECIAL_MARKER_BETA")
  assert_eq(search_ok, true, "server search succeeded")
  local qf = vim.fn.getqflist()
  assert_eq(#qf, 1, "found 1 search match")
  assert_eq(qf[1].lnum, 4567, "match line is 4567")

  -- 7. Test jumping to percentage
  local pct_ok = large_file.goto_percent(bufnr, 90) -- ~line 4500
  assert_eq(pct_ok, true, "goto_percent succeeded")
  assert_eq(state.window.start_line <= 4500 and state.window.end_line >= 4500, true, "window centered near 90%")

  -- 8. Test conflict detection on apply_edit
  -- Alter file on disk externally
  local f_ext = io.open(tmp_file, "a")
  f_ext:write("External appended line\n")
  f_ext:close()

  -- Modify buffer and try to save
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "Conflicting edit" })
  local conf_ok, conf_err = large_file.save(bufnr)
  assert_eq(conf_ok, false, "save fails due to conflict")
  assert_eq(conf_err.code, "conflict", "conflict error code returned")

  -- Cleanup
  os.remove(tmp_file)
  client:close()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  print("  ✓ test_large_file passed!")
end

run()
