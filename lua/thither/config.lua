--- User configuration and defaults for thither.nvim.
local M = {}

M.defaults = {
  -- Remote server binary and options
  server_path = "thither-server",
  server_args = {},

  -- SSH command and defaults
  ssh_command = { "ssh", "-T" },
  port = nil,
  identity = nil,
  user = nil,

  -- WSL options
  wsl_command = "wsl.exe",
  wsl_server_path = nil,

  -- Large file subsystem options [PRIORITY]
  large_file_threshold = 10 * 1024 * 1024, -- 10 MB: files >= threshold use lineindex & viewport
  chunk_size = 65536,                      -- 64 KiB chunks for lineindex
  window_size_lines = 5000,                -- Number of lines loaded in viewport window
  preload_margin = 100,                    -- Lines from top/bottom to suggest sliding
  enable_winbar = true,                    -- Show large file status in winbar

  -- Timeout for sync requests (seconds)
  timeout_seconds = 30,

  -- Per-host configuration overrides: [host_label] = { ... }
  hosts = {},
}

M.values = vim.deepcopy(M.defaults)

--- Updates config with user overrides.
---@param user_config? table
function M.setup(user_config)
  if user_config then
    M.values = vim.tbl_deep_extend("force", M.values, user_config)
  end
end

--- Retrieves an option value, checking per-host override first.
---@param key string
---@param host? string
---@return any
function M.get(key, host)
  if host and M.values.hosts and M.values.hosts[host] and M.values.hosts[host][key] ~= nil then
    return M.values.hosts[host][key]
  end
  return M.values[key]
end

return M
