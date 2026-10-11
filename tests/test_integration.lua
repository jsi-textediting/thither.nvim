-- End-to-end integration tests for Neovim commands and thither:// URI autocmds
local config = require("thither.config")
local thither = require("thither")
local large_file = require("thither.large_file")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: %s (%s ~= %s)", msg or "", vim.inspect(a), vim.inspect(b)))
  end
end

local function run()
  print("Running test_integration.lua...")
  config.setup({
    server_path = "./thither/build/thither-server",
    chunk_size = 4096,
    window_size_lines = 50,
  })

  -- Load plugin autocmds and user commands
  vim.cmd("runtime plugin/thither.lua")

  -- 1. Test normal remote file edit through URI scheme: thither://local:...
  local tmp_file = vim.fn.tempname()
  local f = io.open(tmp_file, "w")
  f:write("Line 1 from integration test\nLine 2\nLine 3\n")
  f:close()

  local uri = "thither://local:" .. tmp_file
  vim.cmd("edit " .. uri)

  local buf1 = vim.api.nvim_get_current_buf()
  local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
  assert_eq(#lines1, 3, "loaded 3 lines via BufReadCmd")
  assert_eq(lines1[1], "Line 1 from integration test", "first line content")

  -- Edit buffer and save via :w
  vim.api.nvim_buf_set_lines(buf1, 1, 2, false, { "Line 2 MODIFIED IN NVIM" })
  vim.cmd("write")

  local rf = io.open(tmp_file, "r")
  local disk_text = rf:read("*all")
  rf:close()
  assert_eq(disk_text, "Line 1 from integration test\nLine 2 MODIFIED IN NVIM\nLine 3\n", "disk written via BufWriteCmd")

  -- 2. Test large file viewport mode through :ThitherLargeEdit
  local large_tmp = vim.fn.tempname()
  local lf = io.open(large_tmp, "w")
  for i = 1, 1000 do
    if i == 500 then
      lf:write("INTEGRATION_TARGET_MARKER\n")
    else
      lf:write(string.format("Data row %d\n", i))
    end
  end
  lf:close()

  vim.cmd("ThitherLargeEdit local:" .. large_tmp)
  local lbuf = vim.api.nvim_get_current_buf()
  assert_eq(type(large_file.buffers[lbuf]), "table", "buffer is managed by large_file")
  assert_eq(large_file.buffers[lbuf].total_lines, 1000, "total lines is 1000")

  -- Jump to line 500 using :ThitherGoto
  vim.cmd("ThitherGoto 500")
  local cur_lines = vim.api.nvim_buf_get_lines(lbuf, 0, -1, false)
  local found_target = false
  for _, l in ipairs(cur_lines) do
    if l == "INTEGRATION_TARGET_MARKER" then found_target = true break end
  end
  assert_eq(found_target, true, "marker found after :ThitherGoto 500")

  -- Search using :ThitherSearch
  vim.cmd("ThitherSearch INTEGRATION_TARGET_MARKER")
  local qf = vim.fn.getqflist()
  assert_eq(#qf, 1, "found 1 search match via user command")
  assert_eq(qf[1].lnum, 500, "match line is 500")

  -- Close quickfix and switch back to large buffer
  vim.cmd("cclose")
  vim.api.nvim_set_current_buf(lbuf)

  -- Jump away to line 1
  vim.cmd("ThitherGoto 1")
  local state = large_file.buffers[lbuf]
  assert_eq(state.window.end_line < 500, true, "viewport moved away from 500")

  -- Use :ThitherSearchNext to jump back to match
  vim.cmd("ThitherSearchNext")
  assert_eq(state.window.start_line <= 500 and state.window.end_line >= 500, true, "ThitherSearchNext synced viewport to match at line 500")

  -- Close quickfix and switch back to large buffer
  vim.cmd("cclose")
  vim.api.nvim_set_current_buf(lbuf)

  -- Edit and save large file
  vim.api.nvim_buf_set_lines(lbuf, 0, 1, false, { "REPLACED_TOP_ROW" })
  vim.cmd("write")
  assert_eq(vim.bo[lbuf].modified, false, "modified flag cleared after :w")

  -- 3. Test directory browser
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, "p")
  local dummy_child = tmp_dir .. "/child.txt"
  local cf = io.open(dummy_child, "w"); cf:write("hello"); cf:close()

  vim.cmd("edit thither://local:" .. tmp_dir .. "/")
  local dir_buf = vim.api.nvim_get_current_buf()
  assert_eq(vim.bo[dir_buf].filetype, "thither_dir", "directory browser filetype set")
  local dir_lines = vim.api.nvim_buf_get_lines(dir_buf, 0, -1, false)
  local found_child = false
  for _, l in ipairs(dir_lines) do
    if l:find("child.txt", 1, true) then found_child = true break end
  end
  assert_eq(found_child, true, "child.txt displayed in directory browser")

  -- Cleanup
  os.remove(tmp_file)
  os.remove(large_tmp)
  os.remove(dummy_child)
  vim.fn.delete(tmp_dir, "d")

  print("  ✓ test_integration passed!")
end

run()
