-- Autocommands and User Commands for thither.nvim
if vim.g.loaded_thither then
  return
end
vim.g.loaded_thither = 1

local thither = require("thither")
local buffer = require("thither.buffer")

-- Register URL autocommands for thither://*
local augroup = vim.api.nvim_create_augroup("thither_autocmds", { clear = true })

vim.api.nvim_create_autocmd({ "BufReadCmd", "FileReadCmd" }, {
  group = augroup,
  pattern = "thither://*",
  callback = function(ev)
    buffer.on_buf_read(ev.buf, ev.match)
  end,
})

vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd" }, {
  group = augroup,
  pattern = "thither://*",
  callback = function(ev)
    buffer.on_buf_write(ev.buf)
  end,
})

-- Global Commands
vim.api.nvim_create_user_command("ThitherEdit", function(opts)
  thither.open(opts.args)
end, {
  nargs = 1,
  complete = "file",
  desc = "Open a file via thither remote editing (thither://host/path or host:/path)",
})

vim.api.nvim_create_user_command("ThitherOpen", function(opts)
  thither.open(opts.args)
end, {
  nargs = 1,
  complete = "file",
  desc = "Alias for :ThitherEdit",
})

vim.api.nvim_create_user_command("ThitherLargeEdit", function(opts)
  thither.large_edit(opts.args)
end, {
  nargs = 1,
  complete = "file",
  desc = "Force open a file in Large File Viewport Mode (thither://host/path)",
})

vim.api.nvim_create_user_command("ThitherGoto", function(opts)
  local arg = vim.trim(opts.args)
  local pct = arg:match("^(%d+%.?%d*)%%$")
  if pct then
    thither.goto_percent(tonumber(pct))
  else
    local line = tonumber(arg)
    if line then
      thither.goto_line(line)
    else
      vim.notify("Usage: :ThitherGoto <line_number> or <percent>%", vim.log.levels.ERROR)
    end
  end
end, {
  nargs = 1,
  desc = "Jump to line or percentage in large file viewport (e.g. :ThitherGoto 100000 or :ThitherGoto 50%)",
})

vim.api.nvim_create_user_command("ThitherPageNext", function()
  thither.page_next()
end, {
  desc = "Scroll large file viewport forward",
})

vim.api.nvim_create_user_command("ThitherPagePrev", function()
  thither.page_prev()
end, {
  desc = "Scroll large file viewport backward",
})

vim.api.nvim_create_user_command("ThitherSearch", function(opts)
  thither.search(opts.args, { regex = false })
end, {
  nargs = "+",
  desc = "Execute high-speed server-side literal search across remote file",
})

vim.api.nvim_create_user_command("ThitherSearchRegex", function(opts)
  thither.search(opts.args, { regex = true })
end, {
  nargs = "+",
  desc = "Execute high-speed server-side PCRE2 regex search across remote file",
})

vim.api.nvim_create_user_command("ThitherSearchNext", function()
  thither.search_next()
end, {
  desc = "Jump to next search match in large file viewport",
})

vim.api.nvim_create_user_command("ThitherSearchPrev", function()
  thither.search_prev()
end, {
  desc = "Jump to previous search match in large file viewport",
})

vim.api.nvim_create_user_command("ThitherConnect", function(opts)
  local spec = opts.args
  local client = thither.connect(spec, function(c, err)
    if err then
      vim.notify(string.format("Failed to connect to %s: %s", spec, err.msg or "error"), vim.log.levels.ERROR)
    else
      vim.notify(string.format("Connected to %s (server v%s, arch %s)", spec, c.server_info.server_version, c.server_info.arch), vim.log.levels.INFO)
    end
  end)
end, {
  nargs = 1,
  desc = "Pre-connect to a thither remote host",
})

vim.api.nvim_create_user_command("ThitherDisconnect", function(opts)
  local spec = opts.args ~= "" and opts.args or nil
  if spec then
    local c = thither.client.instances[spec]
    if c then c:close(); vim.notify("Disconnected from " .. spec) end
  else
    for _, c in pairs(thither.client.instances) do c:close() end
    vim.notify("Disconnected from all remote hosts")
  end
end, {
  nargs = "?",
  desc = "Disconnect from a thither remote host",
})

vim.api.nvim_create_user_command("ThitherStatus", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local stat = thither.ui.status(bufnr)
  if stat ~= "" then
    vim.notify(stat, vim.log.levels.INFO)
  else
    vim.notify("Current buffer is not a thither remote buffer.", vim.log.levels.INFO)
  end
end, {
  desc = "Display remote status information for current buffer",
})

-- Quickfix navigation synchronization for large files
vim.api.nvim_create_autocmd("QuickfixCmdPost", {
  group = augroup,
  pattern = { "c*", "cfirst", "cnext", "cprev", "cc", "clast", "cr" },
  callback = function()
    local qf = vim.fn.getqflist({ idx = 0 })
    if qf.idx > 0 then
      local items = vim.fn.getqflist()
      local item = items[qf.idx]
      if item and item.bufnr and thither.large_file.buffers[item.bufnr] then
        thither.large_file.goto_line(item.bufnr, item.lnum, item.col)
      end
    end
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = augroup,
  pattern = "qf",
  callback = function(ev)
    vim.keymap.set("n", "<CR>", function()
      local line = vim.fn.line(".")
      local items = vim.fn.getqflist()
      local item = items[line]
      if item and item.bufnr and thither.large_file.buffers[item.bufnr] then
        vim.cmd("wincmd p")
        thither.large_file.goto_line(item.bufnr, item.lnum, item.col)
      else
        vim.cmd("execute 'cc' " .. line)
      end
    end, { buffer = ev.buf, silent = true, desc = "Thither quickfix viewport jump" })
  end,
})
