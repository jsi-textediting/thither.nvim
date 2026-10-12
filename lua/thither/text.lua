--- Line splitting / joining with Vim-like 'fileformat' and 'endofline' handling.
local M = {}

local SEP = { unix = "\n", dos = "\r\n", mac = "\r" }

--- Splits raw file bytes into buffer lines.
--- The format is "dos" only when there is at least one newline and every "\n"
--- is preceded by "\r" (like Vim with 'fileformats' "unix,dos"); otherwise it
--- is "unix" and any "\r" bytes stay in the text. Only the "\r" of a "\r\n"
--- line ending is removed.
---@param data string
---@return string[] lines, "unix"|"dos" fileformat, boolean eol
function M.split(data)
  if data == "" then
    return { "" }, "unix", false
  end
  local n_lf = select(2, data:gsub("\n", ""))
  local n_crlf = select(2, data:gsub("\r\n", ""))
  local ff = (n_lf > 0 and n_lf == n_crlf) and "dos" or "unix"
  local eol = data:sub(-1) == "\n"

  local lines = {}
  local pos, len = 1, #data
  while pos <= len do
    local nl = data:find("\n", pos, true)
    if not nl then
      lines[#lines + 1] = data:sub(pos)
      break
    end
    local stop = nl - 1
    if ff == "dos" then stop = stop - 1 end
    lines[#lines + 1] = data:sub(pos, stop)
    pos = nl + 1
  end
  if #lines == 0 then lines[1] = "" end
  return lines, ff, eol
end

--- Line separator for a 'fileformat' value.
---@param ff string
---@return string
function M.sep(ff)
  return SEP[ff] or "\n"
end

--- Joins lines, optionally terminating the last one.
---@param lines string[]
---@param ff string
---@param add_eol boolean
---@return string
function M.join(lines, ff, add_eol)
  local sep = M.sep(ff)
  return table.concat(lines, sep) .. (add_eol and sep or "")
end

--- Whether a write of the buffer's last line should end with a line break:
--- 'endofline', or 'fixendofline' when 'binary' is off (Vim's rule).
---@param bufnr integer
---@return boolean
function M.want_eol(bufnr)
  local bo = vim.bo[bufnr]
  return bo.endofline or (bo.fixendofline and not bo.binary)
end

--- Replaces all lines of a buffer without creating an undo entry and clears
--- the undo history, so that `u` cannot bring back content that no longer
--- corresponds to the buffer's backing data.
---@param bufnr integer
---@param lines string[]
function M.set_lines_no_undo(bufnr, lines)
  local old_ul = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.bo[bufnr].modifiable = true
  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  vim.bo[bufnr].undolevels = old_ul
  if not ok then error(err, 0) end
end

return M
