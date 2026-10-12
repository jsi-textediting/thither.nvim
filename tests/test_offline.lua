-- Tests that need no thither-server: an in-memory fake server answers the
-- protocol ops (stat, read, write, lineindex, read_range, apply_edit, search)
-- with the semantics documented in thither/docs/protocol.md.
local Client = require("thither.client")
local config = require("thither.config")
local text = require("thither.text")
local buffer = require("thither.buffer")
local large_file = require("thither.large_file")
local dir_browser = require("thither.dir_browser")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: %s (%s ~= %s)", msg or "", vim.inspect(a), vim.inspect(b)), 2)
  end
end

---------------------------------------------------------------------------
-- Fake server
---------------------------------------------------------------------------
local fs = {}          -- path -> { data = string, etag = string }
local etag_n = 0
local read_limit = 8 * 1024 * 1024
local calls = {}       -- op -> list of args

local function set_file(path, data)
  etag_n = etag_n + 1
  fs[path] = { data = data, etag = "e" .. etag_n }
  return fs[path]
end

local function index_of(data, chunk_size)
  local chunks = {}
  local pos = 1
  while pos <= #data do
    local piece = data:sub(pos, pos + chunk_size - 1)
    local _, lf = piece:gsub("\n", "")
    chunks[#chunks + 1] = { #piece, lf }
    pos = pos + #piece
  end
  return chunks
end

local function idx_result(f, chunk_size)
  return {
    etag = f.etag,
    size = #f.data,
    chunks = index_of(f.data, chunk_size or 65536),
    ends_with_nl = f.data:sub(-1) == "\n",
  }
end

local function E(code, extra)
  local e = { code = code, msg = code }
  for k, v in pairs(extra or {}) do e[k] = v end
  return nil, e
end

local ops = {}
function ops.stat(a)
  local f = fs[a.path]
  if not f then return E("ENOENT") end
  return { type = "file", size = #f.data, etag = f.etag }
end
function ops.read(a)
  local f = fs[a.path]
  if not f then return E("ENOENT") end
  if a.etag and a.etag ~= f.etag then return E("stale") end
  local data = f.data:sub(a.offset + 1, a.offset + a.len)
  return { data = data, etag = f.etag, eof = a.offset + #data >= #f.data }
end
function ops.write(a)
  local f = fs[a.path]
  if a.if_match == "-" and f then return E("conflict", { etag = f.etag }) end
  if a.if_match and a.if_match ~= "-" and (not f or f.etag ~= a.if_match) then
    return E("conflict", { etag = f and f.etag or "-" })
  end
  local nf = set_file(a.path, a.data)
  return { type = "file", size = #nf.data, etag = nf.etag }
end
function ops.lineindex(a)
  local f = fs[a.path]
  if not f then return E("ENOENT") end
  return idx_result(f, a.chunk_size)
end
function ops.read_range(a)
  local f = fs[a.path]
  if not f then return E("ENOENT") end
  if a.len > read_limit then return E("too_large") end
  if a.etag and a.etag ~= f.etag then return E("stale") end
  return f.data:sub(a.off + 1, a.off + a.len)
end
function ops.apply_edit(a)
  local f = fs[a.path]
  if not f then return E("ENOENT") end
  if a.etag ~= f.etag then return E("conflict", { etag = f.etag }) end
  local out = {}
  for _, item in ipairs(a.script) do
    if item.keep then
      if item.off + item.len > #f.data then return E("bad_request") end
      out[#out + 1] = f.data:sub(item.off + 1, item.off + item.len)
    else
      out[#out + 1] = a.inserts[item.ins]
    end
  end
  local target = a.dest or a.path
  if a.dest and a.dest_if_match == "-" and fs[a.dest] then return E("EEXIST") end
  local nf = set_file(target, table.concat(out))
  return idx_result(nf, a.chunk_size)
end
function ops.search(a)
  local f = fs[a.path]
  local res = {}
  local init = 1
  while true do
    local s, e = f.data:find(a.pattern, init, true)
    if not s then break end
    local before = f.data:sub(1, s - 1)
    local _, nl = before:gsub("\n", "")
    local line_start = (before:match(".*\n()") or 1)
    res[#res + 1] = { off = s - 1, line = nl + 1, col = s - line_start + 1, len = e - s + 1 }
    init = e + 1
  end
  return res
end

local function new_fake(spec)
  return {
    spec = spec,
    state = "ready",
    caps = { apply_edit_dest = true },
    is_ready = function(self) return self.state == "ready" end,
    is_alive = function(self) return self.state == "ready" end,
    call_sync = function(self, op, args)
      if self.state ~= "ready" then return nil, { code = "closed", msg = "closed" } end
      calls[op] = calls[op] or {}
      table.insert(calls[op], args)
      return ops[op](args)
    end,
    close = function(self) self.state = "closed" end,
  }
end

local SPEC = "fake"
local fake = new_fake(SPEC)
Client.instances[SPEC] = fake

local function uri(path) return "thither://" .. SPEC .. path end

local function lines_of(b) return vim.api.nvim_buf_get_lines(b, 0, -1, false) end

local function edit(path)
  vim.cmd("enew!")
  vim.cmd("edit " .. vim.fn.fnameescape(uri(path)))
  return vim.api.nvim_get_current_buf()
end

---------------------------------------------------------------------------
config.setup({ large_file_threshold = 1024 * 1024, window_size_lines = 100, chunk_size = 4096 })
vim.cmd("runtime plugin/thither.lua")
vim.o.hidden = true
vim.o.confirm = false

local passed = 0
local function test(name, fn)
  calls = {}
  fn()
  passed = passed + 1
  print("  ok " .. name)
end

print("Running test_offline.lua...")

---------------------------------------------------------------------------
test("text.split / join", function()
  local l, ff, eol = text.split("a\r\nb\r\n")
  assert_eq(ff, "dos", "all CRLF -> dos"); assert_eq(eol, true, "eol")
  assert_eq(#l, 2, "2 lines"); assert_eq(l[2], "b", "CR removed")
  l, ff = text.split("a\r\nb\n")
  assert_eq(ff, "unix", "mixed -> unix"); assert_eq(l[1], "a\r", "CR kept in unix")
  l, ff, eol = text.split("x\ny")
  assert_eq(eol, false, "no eol"); assert_eq(l[2], "y", "last line")
  l, ff, eol = text.split("")
  assert_eq(#l, 1, "empty"); assert_eq(eol, false, "empty eol")
  l = text.split("tail\r")
  assert_eq(l[1], "tail\r", "lone trailing CR kept")
  assert_eq(text.join({ "a", "b" }, "dos", true), "a\r\nb\r\n", "join dos")
end)

test("CRLF normal file round-trips byte-identically", function()
  set_file("/crlf.txt", "one\r\ntwo\r\n")
  local b = edit("/crlf.txt")
  assert_eq(vim.bo[b].fileformat, "dos", "ff dos")
  assert_eq(lines_of(b)[1], "one", "no CR in buffer")
  vim.cmd("write")
  assert_eq(fs["/crlf.txt"].data, "one\r\ntwo\r\n", "unchanged bytes")
  vim.api.nvim_buf_set_lines(b, 1, 2, false, { "TWO" })
  vim.cmd("write")
  assert_eq(fs["/crlf.txt"].data, "one\r\nTWO\r\n", "edit keeps CRLF")
  assert_eq(vim.bo[b].modified, false, "not modified after write")
end)

test("mixed line endings stay mixed", function()
  set_file("/mixed.txt", "a\r\nb\nc\n")
  local b = edit("/mixed.txt")
  assert_eq(vim.bo[b].fileformat, "unix", "mixed -> unix")
  vim.cmd("write")
  assert_eq(fs["/mixed.txt"].data, "a\r\nb\nc\n", "mixed preserved")
end)

test("missing final newline: endofline/fixendofline honored", function()
  set_file("/noeol.txt", "x\ny")
  local b = edit("/noeol.txt")
  assert_eq(vim.bo[b].endofline, false, "eol off")
  vim.bo[b].fixendofline = false
  vim.cmd("write")
  assert_eq(fs["/noeol.txt"].data, "x\ny", "nofixeol keeps missing EOL")
  vim.bo[b].fixendofline = true
  vim.cmd("write")
  assert_eq(fs["/noeol.txt"].data, "x\ny\n", "fixeol adds EOL like Vim")

  set_file("/empty.txt", "")
  b = edit("/empty.txt")
  vim.cmd("write")
  assert_eq(fs["/empty.txt"].data, "", "empty file stays empty")
end)

test(":read inserts below '[ without touching the buffer", function()
  set_file("/ins.txt", "I1\r\nI2\r\n")
  vim.cmd("enew!")
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a", "b", "c" })
  vim.cmd("2read " .. uri("/ins.txt"))
  assert_eq(table.concat(lines_of(b), ","), "a,b,I1,I2,c", "inserted after line 2")
  assert_eq(vim.bo[b].buftype, "", "buftype untouched")
  assert_eq(vim.b[b].thither_spec, nil, "no thither vars")
  vim.cmd("enew!")
end)

test(":w other name / range / ! semantics", function()
  set_file("/orig.txt", "1\n2\n3\n")
  local b = edit("/orig.txt")
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "ONE" })
  vim.cmd("write " .. uri("/copy.txt"))
  assert_eq(fs["/copy.txt"].data, "ONE\n2\n3\n", "copy written")
  assert_eq(fs["/orig.txt"].data, "1\n2\n3\n", "original untouched")
  assert_eq(vim.bo[b].modified, true, "still modified")

  local before = fs["/copy.txt"].etag
  pcall(vim.cmd, "write " .. uri("/copy.txt"))
  assert_eq(fs["/copy.txt"].etag, before, "no overwrite without !")
  vim.cmd("write! " .. uri("/copy.txt"))
  assert_eq(fs["/copy.txt"].etag ~= before, true, "overwritten with !")

  vim.cmd("2,3write " .. uri("/part.txt"))
  assert_eq(fs["/part.txt"].data, "2\n3\n", "range write")

  -- changed on the host: :w refuses, :w! overwrites
  set_file("/orig.txt", "changed behind our back\n")
  pcall(vim.cmd, "write")
  assert_eq(fs["/orig.txt"].data, "changed behind our back\n", ":w refuses on conflict")
  assert_eq(vim.bo[b].modified, true, "still modified after conflict")
  vim.cmd("write!")
  assert_eq(fs["/orig.txt"].data, "ONE\n2\n3\n", ":w! overwrites on conflict")
  assert_eq(vim.bo[b].modified, false, "not modified after :w!")

  -- a new remote file gets LF line endings, not the Windows default
  local nb = edit("/brand_new.txt")
  assert_eq(vim.bo[nb].fileformat, "unix", "new remote file is unix")
  vim.api.nvim_buf_set_lines(nb, 0, -1, false, { "n1", "n2" })
  vim.cmd("write")
  assert_eq(fs["/brand_new.txt"].data, "n1\nn2\n", "new file written with LF")

  -- from a local (non-thither) buffer
  vim.cmd("enew!")
  vim.bo.fileformat = "unix" -- (default is dos on Windows)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local" })
  vim.cmd("write " .. uri("/fromlocal.txt"))
  assert_eq(fs["/fromlocal.txt"].data, "local\n", "local buffer -> remote")
  vim.cmd("enew!")
end)

test("dir_browser parent at root", function()
  assert_eq(dir_browser.parent_uri("h", "/"), "thither://h/", "root is its own parent")
  assert_eq(dir_browser.parent_uri("h", "/home/"), "thither://h/", "/home -> /")
  assert_eq(dir_browser.parent_uri("local:", "/a/b/"), "thither://local:/a/", "/a/b -> /a/")
end)

-- A large file: 1000 CRLF lines
local function make_large(path, n, crlf)
  local t = {}
  for i = 1, n do t[i] = string.format("line %04d padding padding", i) .. (crlf and "\r\n" or "\n") end
  return set_file(path, table.concat(t))
end

local function open_large(path)
  vim.cmd("enew!")
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(b, uri(path))
  local ok, err = large_file.open(b, fake, path, SPEC)
  assert_eq(ok, true, "large open " .. vim.inspect(err))
  return b, large_file.buffers[b]
end

test("large CRLF window round-trips; edits keep CRLF", function()
  make_large("/big_crlf.txt", 1000, true)
  local orig = fs["/big_crlf.txt"].data
  local b, st = open_large("/big_crlf.txt")
  assert_eq(vim.bo[b].fileformat, "dos", "window ff dos")
  large_file.goto_line(b, 500)
  -- unmodified save: nothing written
  large_file.save(b)
  assert_eq(fs["/big_crlf.txt"].data, orig, "unmodified window byte-identical")
  -- edit one line
  local idx = 500 - st.window.start_line
  vim.api.nvim_buf_set_lines(b, idx, idx + 1, false, { "EDITED" })
  assert_eq(large_file.save(b), true, "save ok")
  local expect = orig:gsub("line 0500 padding padding\r\n", "EDITED\r\n")
  assert_eq(fs["/big_crlf.txt"].data, expect, "only that line changed, CRLF kept")
  vim.cmd("bwipeout! " .. b)
end)

test("undo cannot cross a window load", function()
  make_large("/big_undo.txt", 1000, false)
  local b, st = open_large("/big_undo.txt")
  vim.api.nvim_set_current_buf(b)
  large_file.page_next(b)
  local after = table.concat(lines_of(b), "\n")
  vim.cmd("silent! undo")
  assert_eq(table.concat(lines_of(b), "\n"), after, "undo did not restore previous window")
  assert_eq(vim.bo[b].modified, false, "not modified")
  -- edits inside the window are still undoable
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "X" })
  vim.cmd("let &l:undolevels = &l:undolevels")
  vim.cmd("silent undo")
  assert_eq(table.concat(lines_of(b), "\n"), after, "in-window edit undone")
  local before = fs["/big_undo.txt"].data
  large_file.save(b)
  assert_eq(fs["/big_undo.txt"].data, before, "nothing written after undo")
  vim.cmd("bwipeout! " .. b)
end)

test("read_range is split into server-sized requests; window capped by bytes", function()
  local old_max = large_file.MAX_READ
  read_limit, large_file.MAX_READ = 1000, 1000
  config.setup({ window_max_bytes = 2500 })
  make_large("/big_split.txt", 1000, false) -- 26 bytes per line
  local b, st = open_large("/big_split.txt")
  for _, a in ipairs(calls.read_range) do
    assert_eq(a.len <= 1000, true, "read_range len <= limit")
  end
  assert_eq(st.window.end_byte - st.window.start_byte <= 2500, true, "window capped")
  assert_eq(st.window.end_line, 96, "complete lines only (2500 / 26)")
  assert_eq(lines_of(b)[96], "line 0096 padding padding", "last line of capped window")
  large_file.goto_line(b, 700)
  assert_eq(st.window.start_line <= 700 and st.window.end_line >= 700, true, "target inside capped window")
  assert_eq(lines_of(b)[700 - st.window.start_line + 1], "line 0700 padding padding", "line content at target")
  -- a single line longer than the cap is loaded whole (several reads)
  set_file("/longline.txt", string.rep("z", 5000) .. "\nshort\n")
  local b2, st2 = open_large("/longline.txt")
  assert_eq(#lines_of(b2)[1], 5000, "long line loaded whole")
  assert_eq(st2.window.end_line, 1, "window is that line")
  read_limit, large_file.MAX_READ = 8 * 1024 * 1024, old_max
  config.setup({ window_max_bytes = 4 * 1024 * 1024 })
  vim.cmd("bwipeout! " .. b)
  vim.cmd("bwipeout! " .. b2)
end)

test("large file: last window without EOL, :w to another name via apply_edit dest", function()
  set_file("/big_noeol.txt", "a\nb\nc")
  local b, st = open_large("/big_noeol.txt")
  assert_eq(vim.bo[b].endofline, false, "eol off at EOF window")
  vim.bo[b].fixendofline = false
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "A" })
  vim.api.nvim_set_current_buf(b)
  vim.cmd("write " .. uri("/big_copy.txt"))
  assert_eq(fs["/big_copy.txt"].data, "A\nb\nc", "dest has edits, no EOL added")
  assert_eq(fs["/big_noeol.txt"].data, "a\nb\nc", "source untouched")
  assert_eq(vim.bo[b].modified, true, "still modified")
  vim.cmd("write")
  assert_eq(fs["/big_noeol.txt"].data, "A\nb\nc", "own save")
  vim.cmd("bwipeout! " .. b)
end)

test("quickfix navigation follows absolute lines", function()
  local f = make_large("/big_qf.txt", 1000, false)
  f.data = f.data:gsub("line 0200 padding", "line 0200 NEEDLE"):gsub("line 0800 padding", "line 0800 NEEDLE")
    :gsub("line 0950 padding", "line 0950 NEEDLE")
  local b, st = open_large("/big_qf.txt")
  vim.api.nvim_set_current_buf(b)
  large_file.search(b, "NEEDLE")
  vim.cmd("wincmd p")
  assert_eq(vim.api.nvim_get_current_buf(), b, "back in large buffer")
  assert_eq(st.window.start_line <= 200 and st.window.end_line >= 200, true, "first match shown")
  local function abs() return st.window.start_line + vim.fn.line(".") - 1 end
  local function settle(n) vim.wait(1000, function() return abs() == n end, 5) end
  vim.cmd("cnext")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = b })
  settle(800)
  assert_eq(st.window.start_line <= 800 and st.window.end_line >= 800, true, "viewport follows :cnext")
  assert_eq(vim.api.nvim_get_current_line(), "line 0800 NEEDLE padding", "cursor on match line")
  -- cursor already on the window's last line: :cnext cannot move it, so only
  -- CmdlineLeave triggers the sync
  vim.cmd("normal! G")
  vim.cmd("cnext")
  vim.api.nvim_exec_autocmds("CmdlineLeave", { pattern = ":" })
  settle(950)
  assert_eq(vim.api.nvim_get_current_line(), "line 0950 NEEDLE padding", ":cnext from the last window line")
  -- from the quickfix window: BufEnter fires before :cc places the cursor
  vim.cmd("copen")
  vim.cmd("cc 1")
  settle(200)
  assert_eq(vim.api.nvim_get_current_buf(), b, ":cc 1 enters the large buffer")
  assert_eq(vim.api.nvim_get_current_line(), "line 0200 NEEDLE padding", ":cc 1 from the quickfix window")
  vim.cmd("cclose")
  vim.cmd("bwipeout! " .. b)
end)

test("search_next starts after the shown match", function()
  local f = make_large("/big_sn.txt", 1000, false)
  f.data = f.data:gsub("line 0100 padding", "line 0100 HIT"):gsub("line 0900 padding", "line 0900 HIT")
  local b, st = open_large("/big_sn.txt")
  vim.api.nvim_set_current_buf(b)
  large_file.search(b, "HIT")
  vim.cmd("wincmd p")
  large_file.search_next(b)
  assert_eq(st.window.start_line <= 900 and st.window.end_line >= 900, true, "next goes to match 2")
  vim.cmd("cclose")
  vim.cmd("bwipeout! " .. b)
end)

test("large file reconnects after the connection died", function()
  make_large("/big_rc.txt", 300, false)
  local b, st = open_large("/big_rc.txt")
  fake:close() -- connection drops
  local fresh = new_fake(SPEC)
  Client.instances[SPEC] = fresh
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "after reconnect" })
  assert_eq(large_file.save(b), true, "save works after reconnect")
  assert_eq(st.client, fresh, "state uses new client")
  assert_eq(fs["/big_rc.txt"].data:sub(1, 16), "after reconnect\n", "written")
  fake = fresh
  vim.cmd("bwipeout! " .. b)
end)

test("client fails pending requests on unmatched error frames, protocol errors, close", function()
  local function stub_client()
    local c = Client.new("stub")
    c.state = "ready"
    local written = {}
    local function h() return { is_closing = function() return false end, close = function() end, kill = function() end } end
    c.proc = { stdin = h(), stdout = h(), stderr = h(), handle = h() }
    c.proc.stdin.write = function(_, d) written[#written + 1] = d end
    return c, written
  end
  local results = {}
  local function cb(tag) return function(r, e) results[tag] = e and e.code or "ok" end end

  local c, written = stub_client()
  c:call("stat", { path = "/x" }, cb("a"))
  assert_eq(#written, 1, "request sent")
  c:_handle_message({ err = { code = "bad_frame", msg = "garbage" } })
  vim.wait(100, function() return results.a ~= nil end)
  assert_eq(results.a, "bad_frame", "unmatched error frame fails pending")
  assert_eq(c.state, "ready", "bad_frame keeps session")

  c:call("stat", { path = "/y" }, cb("b"))
  c:_handle_protocol_error("frame_too_large", 99999999)
  vim.wait(100, function() return results.b ~= nil end)
  assert_eq(results.b, "frame_too_large", "protocol error fails pending")
  c:call("stat", { path = "/z" }, cb("c"))
  vim.wait(100, function() return results.c ~= nil end)
  assert_eq(results.c, "frame_too_large", "later calls fail immediately")

  local c2 = stub_client()
  c2:call("stat", { path = "/w" }, cb("d"))
  c2:close()
  vim.wait(100, function() return results.d ~= nil end)
  assert_eq(results.d, "closed", "close fails pending")

  local c3 = stub_client()
  c3.stderr_tail = "bash: thither-server: command not found\n"
  c3:call("stat", { path = "/v" }, function(_, e) results.e = e end)
  c3:_handle_exit(127, 0)
  vim.wait(200, function() return results.e ~= nil end)
  assert_eq(results.e.code, "closed", "exit fails pending")
  assert_eq(results.e.msg:find("command not found", 1, true) ~= nil, true, "stderr in error message")
  assert_eq(c3.last_error.code, "closed", "last_error set on exit")
end)

test("build_cmd: --session after --stdio in every transport; plink takes -P", function()
  local transport = require("thither.transport")
  local saved = vim.deepcopy(config.values)
  config.values.server_args = { "--root", "/srv" }
  config.values.hosts = {
    ["local:"] = { session = "s1" },
    ["wsl:Ubuntu"] = { session = true },
    ["box"] = { session = "proj.a-1", port = 2222 },
    ["pbox"] = { ssh_command = { "C:/Tools/PuTTY/PLINK.EXE", "-batch", "-T" }, port = 2200 },
    ["bad"] = { session = "no spaces" },
    ["long"] = { session = string.rep("x", 33) },
  }
  local cmd, args = transport.build_cmd("local:")
  assert_eq(cmd, "thither-server", "local cmd")
  assert_eq(table.concat(args, " "), "--stdio --session s1 --root /srv", "local args")
  cmd, args = transport.build_cmd("wsl:Ubuntu")
  assert_eq(table.concat(args, " "), "-d Ubuntu -e thither-server --stdio --session default --root /srv", "wsl args")
  cmd, args = transport.build_cmd("box")
  assert_eq(cmd, "ssh", "ssh cmd")
  assert_eq(table.concat(args, " "), "-T -p 2222 box thither-server --stdio --session proj.a-1 --root /srv", "ssh args")
  cmd, args = transport.build_cmd("pbox")
  assert_eq(table.concat(args, " "), "-batch -T -P 2200 pbox thither-server --stdio --root /srv", "plink -P, no session")
  config.values.hosts["u@pbox:2201"] = { ssh_command = { "/usr/bin/plink", "-batch" } }
  cmd, args = transport.build_cmd("u@pbox:2201")
  assert_eq(table.concat(args, " "), "-batch -P 2201 u@pbox thither-server --stdio --root /srv", "plink by basename (u@host:port)")
  cmd, args = transport.build_cmd("other")
  assert_eq(table.concat(args, " "), "-T other thither-server --stdio --root /srv", "no session option")
  local ok, err = pcall(transport.build_cmd, "bad")
  assert_eq(ok, false, "invalid name refused")
  assert_eq(tostring(err):find("Invalid session name", 1, true) ~= nil, true, "error names the problem")
  assert_eq(pcall(transport.build_cmd, "long"), false, "33-character name refused")
  config.values = saved
end)

test("session notices on hello: skew, restart, same pid, old server", function()
  local saved = vim.deepcopy(config.values)
  config.values.hosts = { ["sess"] = { session = "work" }, ["plain"] = {} }
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(m, lvl) notes[#notes + 1] = { msg = m, level = lvl } end
  local function hello(spec, session, extra)
    local c = Client.new(spec)
    c.state = "connecting"
    local h = { ev = "hello", proto_version = 1, server_version = "2.1.7", build_id = "bbbb",
                caps = { "fs", "session" }, session = session }
    for k, v in pairs(extra or {}) do h[k] = v end
    c:_handle_message(h)
    vim.wait(50, function() return false end)
    assert_eq(c.state, "ready", "hello accepted")
    return c
  end
  local function take()
    local n = notes
    notes = {}
    return n
  end
  local function S(pid, skew)
    return { name = "work", daemon_pid = pid, started = 1, version = "2.1.7", version_skew = skew,
             plugins = {}, connections = 1 }
  end

  hello("sess", S(100))
  assert_eq(#take(), 0, "first hello: no notice")
  hello("sess", S(100))
  assert_eq(#take(), 0, "reconnect to the same daemon: no notice")
  hello("sess", S(200))
  local n = take()
  assert_eq(#n, 1, "pid change: one notice")
  assert_eq(n[1].msg:find("session work was restarted (pid 100 → 200)", 1, true) ~= nil, true, "restart text")
  assert_eq(n[1].level, vim.log.levels.WARN, "unexpected restart is a warning")
  assert_eq(Client.session_pids["sess|work"], 200, "new pid remembered")
  local other = S(900)
  other.name = "other"
  hello("sess", other)
  assert_eq(#take(), 0, "another session name on the same host is no restart")

  Client.session_restart_requested.sess = true
  hello("sess", S(300))
  n = take()
  assert_eq(#n, 1, "requested restart: one notice")
  assert_eq(n[1].msg:find("restarted as requested (pid 200 → 300)", 1, true) ~= nil, true, "requested wording")
  assert_eq(Client.session_restart_requested.sess, nil, "request flag cleared")

  hello("sess", S(300, "2.1.8 (cccc)"))
  n = take()
  assert_eq(#n, 1, "skew: one notice")
  assert_eq(n[1].msg:find("remote session work runs thither-server 2.1.7 (bbbb), installed is 2.1.8 (cccc); restart the session to upgrade", 1, true) ~= nil, true, "skew text: " .. n[1].msg)
  hello("sess", S(300, "2.1.8 (cccc)"))
  assert_eq(#take(), 0, "skew: once per host and daemon")
  hello("sess", S(400, "2.1.8 (cccc)"))
  n = take()
  assert_eq(#n, 2, "new daemon with skew: restart + skew notice")

  hello("sess", nil)
  n = take()
  assert_eq(#n, 1, "old server: one notice")
  assert_eq(n[1].msg:find("has no session support", 1, true) ~= nil, true, "old-server text")
  hello("sess", nil)
  assert_eq(#take(), 0, "old server: warned once")
  hello("plain", nil)
  assert_eq(#take(), 0, "no session option, no session table: silent")

  -- session_closing event
  local c = hello("sess", S(400))
  take()
  c:_handle_message({ ev = "session_closing" })
  vim.wait(50, function() return false end)
  n = take()
  assert_eq(#n, 1, "session_closing logged")
  assert_eq(n[1].msg:find("remote session work is shutting down", 1, true) ~= nil, true, "closing text")

  vim.notify = orig_notify
  config.values = saved
  Client.session_pids = {}
  Client.session_warned = { skew = {}, old = {} }
end)

test("session commands refuse hosts without a session", function()
  local thither = require("thither")
  local saved = vim.deepcopy(config.values)
  local info, err = thither.session_info("nosession")
  assert_eq(info, nil, "no session option")
  assert_eq(err:find("not in session mode", 1, true) ~= nil, true, "clear error: " .. err)
  local ok, rerr = thither.restart_session("nosession")
  assert_eq(ok, false, "restart refused")
  assert_eq(rerr:find("not in session mode", 1, true) ~= nil, true, "clear restart error")
  -- the fake server has no session cap
  config.values.hosts = { [SPEC] = { session = true } }
  fake.server_info = { server_version = "1.0" }
  info, err = thither.session_info(SPEC)
  assert_eq(info, nil, "server without session support")
  assert_eq(err:find("no session support", 1, true) ~= nil, true, "old server error: " .. err)
  fake.server_info = nil
  config.values = saved
end)

print(string.format("  ✓ test_offline passed! (%d tests)", passed))
