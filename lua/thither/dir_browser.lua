--- Remote directory browser for thither.nvim.
local vfs = require("thither.vfs")

local M = {}

--- Opens and renders a remote directory in the specified buffer.
---@param bufnr integer
---@param client table
---@param rpath string
---@param spec string
---@return boolean ok, table|nil err
function M.open(bufnr, client, rpath, spec)
  -- Ensure trailing slash on directory path
  if not rpath:match("/$") then
    rpath = rpath .. "/"
  end

  local res, err = vfs.readdir(client, rpath)
  if not res then
    return false, err
  end

  local entries = res.entries or {}
  table.sort(entries, function(a, b)
    local a_dir = a.type == "dir"
    local b_dir = b.type == "dir"
    if a_dir ~= b_dir then
      return a_dir
    end
    return (a.name or "") < (b.name or "")
  end)

  local lines = {
    string.format("\" Thither Remote Directory: %s:%s", spec, rpath),
    "\" Press <CR> to open, - to go up, R to refresh, q to quit",
    "",
    "../",
  }

  local item_map = {
    [4] = { name = "..", is_dir = true },
  }

  for _, e in ipairs(entries) do
    local is_dir = e.type == "dir"
    local name = e.name .. (is_dir and "/" or "")
    local size_str = is_dir and "<DIR>" or string.format("%d B", e.size or 0)
    local line_text = string.format("%-40s  %10s", name, size_str)
    table.insert(lines, line_text)
    item_map[#lines] = {
      name = e.name,
      is_dir = is_dir,
    }
  end

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "thither_dir"

  -- Keymaps
  local opts = { buffer = bufnr, silent = true, nowait = true }

  local function open_current()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_idx = cursor[1]
    local item = item_map[line_idx]
    if not item then return end

    if item.name == ".." then
      -- Go up
      local parent = vim.fs.dirname(rpath:gsub("/$", "")) or "/"
      local target_uri = string.format("thither://%s%s/", spec, parent)
      vim.cmd("edit " .. vim.fn.fnameescape(target_uri))
    elseif item.is_dir then
      local target_uri = string.format("thither://%s%s%s/", spec, rpath, item.name)
      vim.cmd("edit " .. vim.fn.fnameescape(target_uri))
    else
      local target_uri = string.format("thither://%s%s%s", spec, rpath, item.name)
      vim.cmd("edit " .. vim.fn.fnameescape(target_uri))
    end
  end

  vim.keymap.set("n", "<CR>", open_current, opts)
  vim.keymap.set("n", "-", function()
    local parent = vim.fs.dirname(rpath:gsub("/$", "")) or "/"
    local target_uri = string.format("thither://%s%s/", spec, parent)
    vim.cmd("edit " .. vim.fn.fnameescape(target_uri))
  end, opts)
  vim.keymap.set("n", "R", function()
    M.open(bufnr, client, rpath, spec)
  end, opts)
  vim.keymap.set("n", "q", function()
    vim.cmd("bdelete! " .. bufnr)
  end, opts)

  return true
end

return M
