--- Statusline, winbar, and notification UI helpers for thither.nvim.
local large_file = require("thither.large_file")

local M = {}

--- Returns a formatted status string for the current or given buffer.
--- Suitable for use in custom statuslines or lualine components.
---@param bufnr? integer
---@return string
function M.status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Large file buffer
  local lf_state = large_file.buffers[bufnr]
  if lf_state then
    local w = lf_state.window
    local pct = lf_state.total_lines > 0 and (w.start_line / lf_state.total_lines * 100) or 0
    return string.format(
      "[Thither Large: %s | %s | %d-%d/%d (%.0f%%)]",
      vim.fs.basename(lf_state.rpath),
      lf_state.spec,
      w.start_line,
      w.end_line,
      lf_state.total_lines,
      pct
    )
  end

  -- Normal thither remote buffer
  local spec = vim.b[bufnr].thither_spec
  local rpath = vim.b[bufnr].thither_rpath
  if spec and rpath then
    return string.format("[Thither: %s:%s]", spec, vim.fs.basename(rpath))
  end

  return ""
end

return M
