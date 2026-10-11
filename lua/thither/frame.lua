--- Framing for thither-server protocol: u32 little-endian length | msgpack.
local bit = bit
local msgpack = require("thither.msgpack")

local frame = {}

frame.MAX_FRAME = 16 * 1024 * 1024 -- 16 MiB

--- Encodes a 32-bit integer as little-endian bytes.
---@param n integer
---@return string
function frame.pack_u32_le(n)
  return string.char(
    bit.band(n, 0xFF),
    bit.band(bit.rshift(n, 8), 0xFF),
    bit.band(bit.rshift(n, 16), 0xFF),
    bit.band(bit.rshift(n, 24), 0xFF)
  )
end

--- Decodes a 32-bit little-endian integer from string at position `pos`.
---@param str string
---@param pos? integer
---@return integer|nil
function frame.unpack_u32_le(str, pos)
  pos = pos or 1
  if #str < pos + 3 then return nil end
  local b1, b2, b3, b4 = string.byte(str, pos, pos + 3)
  if not (b1 and b2 and b3 and b4) then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

--- Encodes a MessagePack value into a framed packet.
---@param value any
---@return string
function frame.encode(value)
  local payload = msgpack.encode(value)
  if #payload > frame.MAX_FRAME then
    error("frame too large: " .. #payload .. " bytes", 0)
  end
  return frame.pack_u32_le(#payload) .. payload
end

---@class thither.frame.Reader
local Reader = {}
Reader.__index = Reader

--- Creates an incremental frame Reader.
---@param max_frame? integer
---@return thither.frame.Reader
function frame.reader(max_frame)
  return setmetatable({
    max = max_frame or frame.MAX_FRAME,
    buf = "",
    pos = 1,
    parts = {},
    nparts = 0,
    plen = 0,
    need = nil,
  }, Reader)
end

--- Feeds raw bytes received from the wire into the Reader.
---@param data string
function Reader:feed(data)
  if not data or #data == 0 then return end
  self.nparts = self.nparts + 1
  self.parts[self.nparts] = data
  self.plen = self.plen + #data
end

local function flatten(self)
  if self.nparts == 0 then return end
  local rest = self.pos > #self.buf and "" or self.buf:sub(self.pos)
  self.parts[0] = rest
  self.buf = table.concat(self.parts, "", rest == "" and 1 or 0, self.nparts)
  self.parts, self.nparts, self.plen, self.pos = {}, 0, 0, 1
end

--- Number of unconsumed buffered bytes.
---@return integer
function Reader:buffered()
  return #self.buf - self.pos + 1 + self.plen
end

--- Returns the next decoded MessagePack value, or:
---   nil                       when more bytes are needed
---   nil, "frame_too_large", n when payload length exceeds max limit
---   nil, "bad_frame", err     when payload is invalid MessagePack
function Reader:next()
  if not self.need then
    if self:buffered() < 4 then return nil end
    flatten(self)
    local len = frame.unpack_u32_le(self.buf, self.pos)
    if not len then return nil end
    if len > self.max then
      return nil, "frame_too_large", len
    end
    self.pos = self.pos + 4
    self.need = len
  end

  if self:buffered() < self.need then return nil end
  flatten(self)
  local payload = self.buf:sub(self.pos, self.pos + self.need - 1)
  self.pos = self.pos + self.need
  self.need = nil

  local ok, value = pcall(msgpack.decode_exact, payload)
  if not ok then
    return nil, "bad_frame", tostring(value)
  end
  if value == nil then
    return nil, "bad_frame", "frame holds nil"
  end
  return value
end

--- Clears and returns any remaining unconsumed bytes.
---@return string
function Reader:unread_bytes()
  flatten(self)
  local res = self.buf:sub(self.pos)
  self.buf = ""
  self.pos = 1
  return res
end

return frame
