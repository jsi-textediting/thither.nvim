-- VFS filesystem operation tests with thither-server
local Client = require("thither.client")
local vfs = require("thither.vfs")
local config = require("thither.config")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: %s (%s ~= %s)", msg or "", vim.inspect(a), vim.inspect(b)))
  end
end

local function run()
  print("Running test_vfs.lua...")
  config.setup({ server_path = os.getenv("THITHER_SERVER") or "../thither/build/thither-server" })
  local client = Client.new("local:")
  local ready = false
  client:connect(function() ready = true end)
  vim.wait(2000, function() return ready end)

  local tmp_dir = vim.fn.tempname()
  local ok, merr = vfs.mkdir(client, tmp_dir, true)
  if not ok then error("mkdir failed: " .. vim.inspect(merr)) end

  local test_file = tmp_dir .. "/test.txt"

  -- 1. Write file
  local content1 = "First version\nLine 2\n"
  local st1, werr1 = vfs.write(client, test_file, content1, "-", nil, true)
  if not st1 then error("write failed: " .. vim.inspect(werr1)) end
  assert_eq(type(st1.etag), "string", "etag is string")
  assert_eq(st1.size, #content1, "file size matches")

  -- 2. Stat file
  local st2, serr = vfs.stat(client, test_file)
  if not st2 then error("stat failed: " .. vim.inspect(serr)) end
  assert_eq(st2.etag, st1.etag, "etag matches stat")
  assert_eq(st2.type, "file", "is regular file")

  -- 3. Read file
  local read_data, read_etag, rerr = vfs.read_all(client, test_file)
  if not read_data then error("read failed: " .. vim.inspect(rerr)) end
  assert_eq(read_data, content1, "read content matches")
  assert_eq(read_etag, st1.etag, "read etag matches")

  -- 4. Overwrite with matching etag
  local content2 = "Second version updated\n"
  local st3, werr2 = vfs.write(client, test_file, content2, st1.etag, nil, true)
  if not st3 then error("overwrite failed: " .. vim.inspect(werr2)) end
  assert_eq(st3.etag ~= st1.etag, true, "etag updated")

  -- 5. Conflict detection with stale etag
  local st4, werr3 = vfs.write(client, test_file, "Conflict content", st1.etag, nil, true)
  assert_eq(st4, nil, "write with stale etag fails")
  assert_eq(werr3.code, "conflict", "error code is conflict")
  assert_eq(werr3.etag, st3.etag, "error reports current etag")

  -- 6. Directory listing
  local dir_res, rderr = vfs.readdir(client, tmp_dir)
  if not dir_res then error("readdir failed: " .. vim.inspect(rderr)) end
  assert_eq(#dir_res.entries, 1, "1 file in dir")
  assert_eq(dir_res.entries[1].name, "test.txt", "file name in dir")

  -- 7. Remove and clean up
  local rem_ok, reom_err = vfs.remove(client, tmp_dir, true)
  if not rem_ok then error("remove failed: " .. vim.inspect(reom_err)) end

  local st_gone, st_err = vfs.stat(client, test_file)
  assert_eq(st_gone, nil, "file is gone")
  assert_eq(st_err.code, "ENOENT", "returns ENOENT")

  client:close()
  print("  ✓ test_vfs passed!")
end

run()
