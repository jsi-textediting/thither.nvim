--- Subprocess management and command line builder for thither transport.
local uv = vim.uv
local config = require("thither.config")

local transport = {}

--- Quotes an argument for a remote POSIX shell.
---@param s string
---@return string
local function shell_quote(s)
  if s:match("^~/(.*)$") then
    local rest = s:sub(3)
    return "~/" .. shell_quote(rest)
  end
  if s ~= "" and not s:find("[^%w_@%%+=:,./-]") then
    return s
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Returns the transport kind: "local", "wsl", or "ssh".
---@param spec string
---@return "local"|"wsl"|"ssh"
function transport.kind(spec)
  if spec:match("^local:") or spec == "local" then return "local" end
  if spec:match("^wsl:") or spec == "wsl" then return "wsl" end
  return "ssh"
end

--- Builds the executable command and arguments for a host specification.
---@param spec string
---@return string cmd, string[] args
function transport.build_cmd(spec)
  local kind = transport.kind(spec)
  local server = config.get("server_path", spec)
  local server_args = config.get("server_args", spec) or {}

  if kind == "local" then
    -- local: or local:/path/to/server
    local custom_bin = spec:match("^local:(.+)$")
    local cmd = (custom_bin and custom_bin ~= "") and custom_bin or server
    local args = { "--stdio" }
    for _, a in ipairs(server_args) do
      table.insert(args, a)
    end
    return cmd, args
  end

  if kind == "wsl" then
    local cmd = config.get("wsl_command", spec)
    local distro = spec:match("^wsl:(.+)$")
    local args = {}
    if distro and distro ~= "" then
      table.insert(args, "-d")
      table.insert(args, distro)
    end
    table.insert(args, "-e")
    table.insert(args, config.get("wsl_server_path", spec) or server)
    table.insert(args, "--stdio")
    for _, a in ipairs(server_args) do
      table.insert(args, a)
    end
    return cmd, args
  end

  -- SSH
  local ssh_cmd = config.get("ssh_command", spec) or { "ssh", "-T" }
  local cmd = ssh_cmd[1]
  local args = {}
  for i = 2, #ssh_cmd do
    table.insert(args, ssh_cmd[i])
  end

  local port = config.get("port", spec)
  local identity = config.get("identity", spec)
  local user = config.get("user", spec)

  -- Parse spec for user@host:port if present
  local host_target = spec
  local spec_user, spec_host, spec_port = spec:match("^([^@]+)@([^:]+):?(%d*)$")
  if spec_user and spec_host then
    user = user or spec_user
    host_target = spec_host
    if spec_port and spec_port ~= "" then
      port = port or tonumber(spec_port)
    end
  else
    local shost, sport = spec:match("^([^:]+):(%d+)$")
    if shost and sport then
      host_target = shost
      port = port or tonumber(sport)
    end
  end

  if identity then
    table.insert(args, "-i")
    table.insert(args, identity)
  end

  if port then
    table.insert(args, "-p")
    table.insert(args, tostring(port))
  end

  -- A target starting with "-" would be taken for an option by ssh
  assert(host_target:sub(1, 1) ~= "-", "Invalid remote host: " .. host_target)
  local target = user and (user .. "@" .. host_target) or host_target
  table.insert(args, target)

  -- Remote command line
  local remote_parts = { shell_quote(server), "--stdio" }
  for _, a in ipairs(server_args) do
    table.insert(remote_parts, shell_quote(a))
  end
  table.insert(args, table.concat(remote_parts, " "))

  return cmd, args
end

--- Spawns the transport subprocess and sets up stdio pipes.
---@param spec string
---@param on_exit fun(code: integer, signal: integer)
---@return table
function transport.spawn(spec, on_exit)
  local cmd, args = transport.build_cmd(spec)
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local handle, pid_or_err = uv.spawn(cmd, {
    args = args,
    stdio = { stdin, stdout, stderr },
  }, on_exit)

  if not handle then
    error(string.format("Failed to spawn transport for '%s' (%s): %s", spec, cmd, tostring(pid_or_err)))
  end

  return {
    handle = handle,
    pid = pid_or_err,
    stdin = stdin,
    stdout = stdout,
    stderr = stderr,
    cmd = cmd,
    args = args,
    spec = spec,
  }
end

return transport
