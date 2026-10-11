--- Client connection and request multiplexer for thither-server protocol v1.
local uv = vim.uv
local frame = require("thither.frame")
local transport = require("thither.transport")
local config = require("thither.config")

local Client = {}
Client.__index = Client

Client.PROTO_VERSION = 1
Client.CLIENT_VERSION = "thither.nvim-0.1.0"
Client.instances = {} -- spec -> Client

--- Gets or creates a Client instance for the given host spec.
---@param spec string
---@param cb? fun(client: table, err?: table)
---@return table
function Client.get(spec, cb)
  local client = Client.instances[spec]
  if client and client:is_alive() then
    if cb then
      if client.state == "ready" then
        vim.schedule(function() cb(client) end)
      else
        table.insert(client.ready_callbacks, cb)
      end
    end
    return client
  end

  client = Client.new(spec)
  Client.instances[spec] = client
  client:connect(cb)
  return client
end

--- Creates a new Client instance.
---@param spec string
---@return table
function Client.new(spec)
  local self = setmetatable({
    spec = spec,
    state = "idle", -- "idle" | "connecting" | "ready" | "closed" | "error"
    next_id = 1,
    pending = {},
    queue = {},
    reader = frame.reader(),
    ready_callbacks = {},
    event_listeners = {},
    server_info = nil,
    caps = {},
    stderr_tail = "",
    last_error = nil,
  }, Client)
  return self
end

function Client:is_alive()
  return self.state == "ready" or self.state == "connecting"
end

function Client:is_ready()
  return self.state == "ready"
end

--- Connects to the remote server.
---@param cb? fun(client: table, err?: table)
function Client:connect(cb)
  if cb then
    table.insert(self.ready_callbacks, cb)
  end

  if self.state == "connecting" or self.state == "ready" then
    return
  end

  self.state = "connecting"
  local on_exit = function(code, signal)
    self:_handle_exit(code, signal)
  end

  local ok, proc = pcall(transport.spawn, self.spec, on_exit)
  if not ok then
    self.state = "error"
    self.last_error = { code = "spawn_failed", msg = tostring(proc) }
    self:_notify_ready(self.last_error)
    return
  end

  self.proc = proc
  self:_start_reading()
  self:_send_hello()
end

function Client:_start_reading()
  self.proc.stdout:read_start(function(err, data)
    if err then
      self:_handle_io_error("stdout", err)
      return
    end
    if data then
      self.reader:feed(data)
      while true do
        local msg, err_code, err_detail = self.reader:next()
        if not msg then
          if err_code then
            self:_handle_protocol_error(err_code, err_detail)
          end
          break
        end
        self:_handle_message(msg)
      end
    end
  end)

  self.proc.stderr:read_start(function(err, data)
    if data then
      self.stderr_tail = (self.stderr_tail .. data):sub(-4096)
    end
  end)
end

function Client:_send(msg)
  if not self.proc or not self.proc.stdin or self.proc.stdin:is_closing() then
    return false
  end
  local encoded = frame.encode(msg)
  self.proc.stdin:write(encoded)
  return true
end

function Client:_send_hello()
  local hello = {
    ev = "hello",
    proto_version = Client.PROTO_VERSION,
    client_version = Client.CLIENT_VERSION,
    caps = vim.empty_dict(),
  }
  self:_send(hello)
end

function Client:_handle_message(msg)
  -- 1. Hello handshake reply
  if msg.ev == "hello" then
    if msg.err then
      self.state = "error"
      self.last_error = msg.err
      self:_notify_ready(msg.err)
      return
    end
    if msg.proto_version ~= Client.PROTO_VERSION then
      self.state = "error"
      self.last_error = {
        code = "version_mismatch",
        msg = string.format("Server protocol %s != client %s", tostring(msg.proto_version), Client.PROTO_VERSION),
      }
      self:_notify_ready(self.last_error)
      return
    end

    self.server_info = msg
    self.caps = {}
    if type(msg.caps) == "table" then
      for _, cap in ipairs(msg.caps) do
        self.caps[cap] = true
      end
    end
    self.state = "ready"
    self:_notify_ready(nil)
    self:_flush_queue()
    return
  end

  -- 2. Request response { id, ok } or { id, err }
  if msg.id ~= nil then
    local p = self.pending[msg.id]
    if p then
      self.pending[msg.id] = nil
      if p.cb then
        vim.schedule(function()
          p.cb(msg.ok, msg.err)
        end)
      end
    end
    return
  end

  -- 3. Server event notification { ev, ... }
  if msg.ev ~= nil then
    local listeners = self.event_listeners[msg.ev]
    if listeners then
      for _, fn in ipairs(listeners) do
        vim.schedule(function() fn(msg) end)
      end
    end
    return
  end
end

function Client:_notify_ready(err)
  local cbs = self.ready_callbacks
  self.ready_callbacks = {}
  for _, cb in ipairs(cbs) do
    vim.schedule(function() cb(self, err) end)
  end
end

function Client:_flush_queue()
  local q = self.queue
  self.queue = {}
  for _, item in ipairs(q) do
    self:call(item.op, item.args, item.cb)
  end
end

function Client:_handle_exit(code, signal)
  self.state = "closed"
  local err = { code = "closed", msg = string.format("Server exited with code %s (signal %s)", tostring(code), tostring(signal)) }
  for id, p in pairs(self.pending) do
    self.pending[id] = nil
    if p.cb then
      vim.schedule(function() p.cb(nil, err) end)
    end
  end
  self:_notify_ready(err)
end

function Client:_handle_io_error(stream, err)
  self.state = "error"
  self.last_error = { code = "io_error", msg = string.format("%s error: %s", stream, tostring(err)) }
end

function Client:_handle_protocol_error(code, detail)
  self.state = "error"
  self.last_error = { code = code, msg = tostring(detail) }
end

--- Sends an asynchronous request to the server.
---@param op string
---@param args table|nil
---@param cb fun(ok: any, err?: table)
function Client:call(op, args, cb)
  if self.state == "closed" or self.state == "error" then
    if cb then
      vim.schedule(function()
        cb(nil, self.last_error or { code = "not_connected", msg = "Client is disconnected" })
      end)
    end
    return
  end

  if self.state == "connecting" then
    table.insert(self.queue, { op = op, args = args, cb = cb })
    return
  end

  local id = self.next_id
  self.next_id = self.next_id + 1

  -- args must always be a map in thither protocol
  local req_args = (args and next(args) ~= nil) and args or vim.empty_dict()
  local msg = { id = id, op = op, args = req_args }

  self.pending[id] = { cb = cb, op = op }
  self:_send(msg)
end

--- Sends a synchronous request, blocking Neovim until response or timeout.
---@param op string
---@param args table|nil
---@param timeout_ms? integer
---@return any ok, table|nil err
function Client:call_sync(op, args, timeout_ms)
  local res, err, done = nil, nil, false
  self:call(op, args, function(r, e)
    res = r
    err = e
    done = true
  end)

  local timeout = timeout_ms or (config.get("timeout_seconds", self.spec) * 1000)
  local wait_ok = vim.wait(timeout, function() return done end, 5)
  if not wait_ok then
    return nil, { code = "timeout", msg = string.format("Request '%s' timed out after %d ms", op, timeout) }
  end
  return res, err
end

--- Cancels an in-flight request.
---@param id integer
function Client:cancel(id)
  if self.pending[id] then
    self.pending[id] = nil
    self:_send({ cancel = id })
  end
end

--- Sends a ping.
---@param data? any
---@param cb? fun(ok: any, err?: table)
function Client:ping(data, cb)
  self:call("ping", { data = data or "pong" }, cb or function() end)
end

--- Registers an event listener for server push events.
---@param ev string
---@param fn fun(msg: table)
function Client:on(ev, fn)
  if not self.event_listeners[ev] then
    self.event_listeners[ev] = {}
  end
  table.insert(self.event_listeners[ev], fn)
end

--- Closes the client connection and child process.
function Client:close()
  self.state = "closed"
  if self.proc then
    if self.proc.stdin and not self.proc.stdin:is_closing() then self.proc.stdin:close() end
    if self.proc.stdout and not self.proc.stdout:is_closing() then self.proc.stdout:close() end
    if self.proc.stderr and not self.proc.stderr:is_closing() then self.proc.stderr:close() end
    if self.proc.handle and not self.proc.handle:is_closing() then self.proc.handle:close() end
  end
  Client.instances[self.spec] = nil
end

return Client
