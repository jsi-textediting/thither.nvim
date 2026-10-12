-- Client and protocol handshake tests with live thither-server
local Client = require("thither.client")
local config = require("thither.config")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: %s (%s ~= %s)", msg or "", vim.inspect(a), vim.inspect(b)))
  end
end

local function run()
  print("Running test_client.lua...")
  config.setup({
    server_path = os.getenv("THITHER_SERVER") or "../thither/build/thither-server",
  })

  local client = Client.new("local:")
  local ready = false
  client:connect(function(c, err)
    if err then error("Connect failed: " .. vim.inspect(err)) end
    ready = true
  end)

  local ok = vim.wait(2000, function() return ready end)
  if not ok then error("Timed out waiting for client connection") end

  assert_eq(client.state, "ready", "client state is ready")
  assert_eq(client.server_info.proto_version, 1, "protocol version is 1")
  assert_eq(client.caps.large_file, true, "server has large_file capability")
  assert_eq(client.caps.search, true, "server has search capability")
  assert_eq(client.caps.fs, true, "server has fs capability")

  -- Test sync ping
  local pong, perr = client:call_sync("ping", { data = "hello world" })
  if perr then error("Ping error: " .. vim.inspect(perr)) end
  assert_eq(pong, "hello world", "ping roundtrip")

  -- Test async call
  local info_res, info_err = nil, nil
  local info_done = false
  client:call("info", nil, function(r, e)
    info_res = r
    info_err = e
    info_done = true
  end)
  vim.wait(1000, function() return info_done end)
  if info_err then error("Info error: " .. vim.inspect(info_err)) end
  assert_eq(info_res.proto_version, 1, "info proto version")

  -- Test unknown op
  local bad_res, bad_err = client:call_sync("nonexistent_op", nil)
  assert_eq(bad_res, nil, "unknown op result is nil")
  assert_eq(bad_err.code, "unknown_op", "unknown op error code")

  client:close()
  assert_eq(client.state, "closed", "client state is closed")
  print("  ✓ test_client passed!")
end

run()
