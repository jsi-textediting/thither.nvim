-- Persistent session tests with a live thither-server (--session through
-- local:). tests/run.sh points XDG_RUNTIME_DIR / XDG_STATE_HOME at temporary
-- directories, so the session daemon's socket, lock and log stay out of the
-- real ones.
local Client = require("thither.client")
local config = require("thither.config")
local vfs = require("thither.vfs")
local thither = require("thither")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: %s (%s ~= %s)", msg or "", vim.inspect(a), vim.inspect(b)), 2)
  end
end

local server = os.getenv("THITHER_SERVER") or "../thither/build/thither-server"
local SPEC = "local:" .. server
local NAME = "nv_" .. vim.fn.getpid()

local function run()
  print("Running test_session.lua...")
  assert(os.getenv("XDG_RUNTIME_DIR") and os.getenv("XDG_STATE_HOME"), "run through tests/run.sh (temporary XDG dirs)")
  config.setup({ hosts = { [SPEC] = { session = NAME } } })

  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(m, lvl) notes[#notes + 1] = { msg = m, level = lvl } end
  local function take()
    vim.wait(100, function() return false end)
    local n = notes
    notes = {}
    return n
  end

  local ok_all, err_all = pcall(function()
    local c1, err = Client.ensure(SPEC, 10000)
    assert(c1, "connect: " .. vim.inspect(err))
    local s1 = c1.server_info.session
    assert_eq(type(s1), "table", "hello has a session table")
    assert_eq(s1.name, NAME, "session name")
    assert_eq(c1.caps.session, true, "session cap")
    local pid1 = s1.daemon_pid
    assert_eq(#take(), 0, "first connect: no notice")

    local dir = vim.fn.tempname()
    assert(vfs.mkdir(c1, dir, true))
    local st, werr = vfs.write(c1, dir .. "/a.txt", "one\n", "-", nil, true)
    assert(st, "write: " .. vim.inspect(werr))

    -- kill the transport (the relay): the daemon survives
    c1.proc.handle:kill("sigkill")
    assert(vim.wait(5000, function() return c1.state == "closed" end, 10), "transport death noticed")

    local c2 = assert(Client.ensure(SPEC, 10000))
    assert(c2 ~= c1, "new client instance")
    assert_eq(c2.server_info.session.daemon_pid, pid1, "reconnect reaches the same daemon")
    assert_eq(#take(), 0, "same daemon: no notice")
    local st2 = assert(vfs.write(c2, dir .. "/a.txt", "two\n", st.etag))
    assert_eq(st2.size, 4, "write after reconnect")

    local info, ierr = thither.session_info(SPEC)
    assert(info, "session_info: " .. tostring(ierr))
    assert_eq(info.name, NAME, "info name")
    assert_eq(info.daemon_pid, pid1, "info pid")
    local text = thither.format_session_info(SPEC, info)
    assert_eq(text:find("daemon pid:  " .. pid1, 1, true) ~= nil, true, "formatted info")
    assert_eq(info.version_skew, nil, "no skew")

    local rok, rerr = thither.restart_session(SPEC)
    assert(rok, "restart: " .. tostring(rerr))
    assert_eq(Client.instances[SPEC], nil, "disconnected after restart")
    take()

    local c3 = assert(Client.ensure(SPEC, 10000))
    local pid2 = c3.server_info.session.daemon_pid
    assert(pid2 ~= pid1, "restart starts a new daemon")
    local n = take()
    assert_eq(#n, 1, "one notice after the restart")
    assert_eq(n[1].msg:find(string.format("restarted as requested (pid %s → %s)", pid1, pid2), 1, true) ~= nil,
      true, "restart notice: " .. n[1].msg)
    local data = assert(vfs.read_all(c3, dir .. "/a.txt"))
    assert_eq(data, "two\n", "files unaffected by the restart")
    assert(vfs.remove(c3, dir, true))
    c3:close()
  end)

  vim.notify = orig_notify
  for _, c in pairs(Client.instances) do c:close() end
  local k = vim.system({ server, "--session", NAME, "--kill" }):wait()
  if not ok_all then error(err_all, 0) end
  assert_eq(k.code, 0, "--kill: " .. (k.stderr or ""))
  print("  ✓ test_session passed!")
end

run()
