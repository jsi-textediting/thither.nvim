--- Client connection and request multiplexer for thither-server protocol v1.
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

--- Returns a ready Client for `spec`, (re)connecting and blocking until the
--- handshake finished. A client whose connection died is replaced by a new one.
---@param spec string
---@param timeout_ms? integer
---@return table|nil client, table|nil err
function Client.ensure(spec, timeout_ms)
  local client = Client.get(spec)
  if not client:is_ready() then
    local timeout = timeout_ms or (config.get("timeout_seconds", spec) * 1000)
    vim.wait(timeout, function()
      return client.state ~= "connecting"
    end, 10)
    if not client:is_ready() then
      return nil, client.last_error or { code = "timeout", msg = "Timed out connecting to " .. spec }
    end
  end
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
    exited = false,
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
      while self.state == "connecting" or self.state == "ready" do
        local msg, err_code, err_detail = self.reader:next()
        if not msg then
          if err_code then
            self:_handle_protocol_error(err_code, err_detail)
          end
          break
        end
        if type(msg) ~= "table" then
          -- every payload is a map; anything else means a broken stream
          self:_handle_protocol_error("bad_frame", "server sent a non-map payload")
          break
        end
        self:_handle_message(msg)
      end
    end
  end)

  self.proc.stderr:read_start(function(_, data)
    if data then
      self.stderr_tail = (self.stderr_tail .. data):sub(-4096)
    end
  end)
end

---@return boolean sent, table|nil err
function Client:_send(msg)
  if not self.proc or not self.proc.stdin or self.proc.stdin:is_closing() then
    return false
  end
  local ok, encoded = pcall(frame.encode, msg)
  if not ok then
    return false, { code = "too_large", msg = tostring(encoded) }
  end
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
      self:_fail_pending(msg.err)
      self:_notify_ready(msg.err)
      return
    end
    if msg.proto_version ~= Client.PROTO_VERSION then
      self.state = "error"
      self.last_error = {
        code = "version_mismatch",
        msg = string.format("Server protocol %s != client %s", tostring(msg.proto_version), Client.PROTO_VERSION),
      }
      self:_fail_pending(self.last_error)
      self:_notify_ready(self.last_error)
      self:_teardown()
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
  if msg.id ~= nil and msg.ev == nil then
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

  -- 4. Error frame without id ({err={code="bad_frame"|"frame_too_large"|...}}).
  -- It cannot be matched to a request, so every in-flight request is failed
  -- instead of being left to time out.
  if type(msg.err) == "table" then
    local err = { code = msg.err.code or "bad_frame", msg = tostring(msg.err.msg or msg.err.code) }
    self.last_error = err
    self:_fail_pending(err)
    if self.state == "connecting" then
      self.state = "error"
      self:_notify_ready(err)
      self:_teardown()
    end
  end
end

--- Fails all in-flight and queued requests with `err`.
---@param err table
function Client:_fail_pending(err)
  local pending = self.pending
  self.pending = {}
  for _, p in pairs(pending) do
    if p.cb then
      vim.schedule(function() p.cb(nil, err) end)
    end
  end
  local q = self.queue
  self.queue = {}
  for _, item in ipairs(q) do
    if item.cb then
      vim.schedule(function() item.cb(nil, err) end)
    end
  end
end

--- Closes the pipes and the process handle (idempotent).
function Client:_teardown()
  local proc = self.proc
  if not proc then return end
  for _, h in ipairs({ proc.stdin, proc.stdout, proc.stderr }) do
    if h and not h:is_closing() then
      h:close()
    end
  end
  if proc.handle and not proc.handle:is_closing() then
    if not self.exited then pcall(proc.handle.kill, proc.handle, "sigterm") end
    proc.handle:close()
  end
end

--- Appends the tail of the server's stderr to an error message.
---@param msg string
---@return string
function Client:_with_stderr(msg)
  local tail = vim.trim(self.stderr_tail or "")
  if tail ~= "" then
    return msg .. ": " .. tail:sub(-1000)
  end
  return msg
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
  self.exited = true
  -- The exit callback can run before the last stdout/stderr bytes were
  -- delivered (e.g. a version_mismatch hello followed by exit 2); let the
  -- loop drain them before failing requests and closing the pipes.
  vim.schedule(function()
    if self.state == "connecting" or self.state == "ready" then
      self.state = "closed"
      self.last_error = {
        code = "closed",
        msg = self:_with_stderr(string.format("Server exited with code %s (signal %s)", tostring(code), tostring(signal))),
      }
    end
    local err = self.last_error or { code = "closed", msg = "Server exited" }
    self:_fail_pending(err)
    self:_notify_ready(err)
    self:_teardown()
  end)
end

function Client:_handle_io_error(stream, err)
  self.state = "error"
  self.last_error = { code = "io_error", msg = self:_with_stderr(string.format("%s error: %s", stream, tostring(err))) }
  self:_fail_pending(self.last_error)
  self:_notify_ready(self.last_error)
  self:_teardown()
end

function Client:_handle_protocol_error(code, detail)
  -- A framing error cannot be resynchronised: drop the connection.
  self.state = "error"
  self.last_error = { code = code, msg = tostring(detail) }
  self:_fail_pending(self.last_error)
  self:_notify_ready(self.last_error)
  self:_teardown()
end

--- Sends an asynchronous request to the server.
---@param op string
---@param args table|nil
---@param cb fun(ok: any, err?: table)
---@return integer|nil id
function Client:call(op, args, cb)
  if self.state == "closed" or self.state == "error" or self.state == "idle" then
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
  local sent, send_err = self:_send(msg)
  if not sent then
    self.pending[id] = nil
    if cb then
      local err = send_err or self.last_error or { code = "not_connected", msg = "Client is disconnected" }
      vim.schedule(function() cb(nil, err) end)
    end
    return
  end
  return id
end

--- Sends a synchronous request, blocking Neovim until response or timeout.
---@param op string
---@param args table|nil
---@param timeout_ms? integer
---@return any ok, table|nil err
function Client:call_sync(op, args, timeout_ms)
  local res, err, done = nil, nil, false
  local id = self:call(op, args, function(r, e)
    res = r
    err = e
    done = true
  end)

  local timeout = timeout_ms or (config.get("timeout_seconds", self.spec) * 1000)
  local wait_ok = vim.wait(timeout, function() return done end, 5)
  if not wait_ok then
    if id then self:cancel(id) end
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
  self.last_error = { code = "closed", msg = "Connection closed by client" }
  self:_fail_pending(self.last_error)
  self:_notify_ready(self.last_error)
  self:_teardown()
  if Client.instances[self.spec] == self then
    Client.instances[self.spec] = nil
  end
end

return Client
