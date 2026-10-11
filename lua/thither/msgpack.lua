--- MessagePack encoder/decoder for thither.nvim using Neovim's vim.mpack.
local M = {}

--- Marks an empty table as a dictionary/map so vim.mpack encodes it as 0x80 (fixmap)
--- instead of 0x90 (fixarray).
---@param tbl table|nil
---@return table
function M.map(tbl)
  if not tbl or next(tbl) == nil then
    return vim.empty_dict()
  end
  return tbl
end

--- Encodes a Lua value into MessagePack binary string.
---@param value any
---@return string
function M.encode(value)
  return vim.mpack.encode(value)
end

--- Decodes a MessagePack binary string.
---@param str string
---@return any
function M.decode(str)
  return vim.mpack.decode(str)
end

--- Decodes a MessagePack binary string, ensuring exact decode.
---@param str string
---@return any
function M.decode_exact(str)
  return vim.mpack.decode(str)
end

return M
