-- Unit tests for framing and MessagePack codec
local frame = require("thither.frame")
local msgpack = require("thither.msgpack")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: %s (%s ~= %s)", msg or "", vim.inspect(a), vim.inspect(b)))
  end
end

local function test_packing()
  local n = 0x12345678
  local packed = frame.pack_u32_le(n)
  assert_eq(#packed, 4, "packed length")
  local unpacked = frame.unpack_u32_le(packed, 1)
  assert_eq(unpacked, n, "unpack u32")

  -- Zero and Max
  assert_eq(frame.unpack_u32_le(frame.pack_u32_le(0)), 0, "unpack 0")
  assert_eq(frame.unpack_u32_le(frame.pack_u32_le(16777216)), 16777216, "unpack max frame")
end

local function test_reader()
  local r = frame.reader()
  local msg1 = { id = 1, op = "ping", args = msgpack.map({ text = "hello" }) }
  local msg2 = { id = 2, op = "info", args = msgpack.map({}) }

  local enc1 = frame.encode(msg1)
  local enc2 = frame.encode(msg2)
  local combined = enc1 .. enc2

  -- Feed in small 3-byte fragments to test incremental reader
  local received = {}
  for i = 1, #combined, 3 do
    r:feed(combined:sub(i, i + 2))
    while true do
      local val, err = r:next()
      if not val then
        if err then error("Reader error: " .. tostring(err)) end
        break
      end
      table.insert(received, val)
    end
  end

  assert_eq(#received, 2, "received count")
  assert_eq(received[1].id, 1, "msg1 id")
  assert_eq(received[1].op, "ping", "msg1 op")
  assert_eq(received[1].args.text, "hello", "msg1 arg text")

  assert_eq(received[2].id, 2, "msg2 id")
  assert_eq(received[2].op, "info", "msg2 op")
end

local function test_oversized_frame()
  local r = frame.reader(1024) -- 1 KiB cap
  -- Header says 2048 bytes
  local fake_header = frame.pack_u32_le(2048)
  r:feed(fake_header)
  local val, err_code, len = r:next()
  assert_eq(val, nil, "val is nil on error")
  assert_eq(err_code, "frame_too_large", "detects oversized frame")
  assert_eq(len, 2048, "oversized length reported")
end

local function run()
  print("Running test_frame.lua...")
  test_packing()
  test_reader()
  test_oversized_frame()
  print("  ✓ test_frame passed!")
end

run()
