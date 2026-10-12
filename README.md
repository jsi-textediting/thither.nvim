# thither.nvim

A high-performance remote editing package for **Neovim** powered by [`thither-server`](https://github.com/jsi-textediting/thither), engineered with **first-class priority on multi-gigabyte large file support**.

`thither.nvim` allows opening, viewing, searching, and editing multi-GB files on remote servers in milliseconds over SSH stdio without downloading entire files or running out of memory in Neovim.

---

## ⚡ Highlights

* **🚀 Instant Large File Opening**: Multi-GB files open in < 50ms using server-side chunked line indexing (`lineindex`).
* **🧠 Bounded O(1) Memory Usage**: Loads a sliding viewport window (e.g. 5,000 lines) into Neovim, ensuring a 10 GB file consumes no more RAM than a small file.
* **🔎 Server-Side Search Across Gigabytes**: Executes regex or literal searches (`search`) on the remote server at disk speed, streaming matches directly into Neovim's Quickfix list.
* **✏️ Atomic In-Window Saving**: Edits in the viewport window are committed via `apply_edit` scripts (kept byte ranges + inserts). Only the edited text crosses the wire—no full file uploads!
* **🛡️ Conflict Detection**: ETag verification prevents accidental overwrites when a remote file is modified externally.
* **📁 Built-in Directory Browser**: Seamlessly browse and open remote directories.
* **🔌 No Open Ports**: Connects over standard SSH stdio (`ssh -T`) or local/WSL processes without needing open network ports; an opt-in `session` keeps a per-user daemon across reconnects.

---

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jsi-textediting/thither.nvim",
  config = function()
    require("thither").setup({
      -- server_path = "thither-server",
      -- large_file_threshold = 10 * 1024 * 1024, -- 10 MB
      -- window_size_lines = 5000,
    })
  end,
}
```

---

## 🚀 Usage

### Opening Files

Open remote files using standard commands or URI schemes:

```vim
" Via ThitherEdit command
:ThitherEdit devbox:/var/log/syslog
:ThitherEdit thither://user@myserver.com:2222/etc/nginx/nginx.conf

" Force Large File Mode on any file
:ThitherLargeEdit devbox:/var/log/huge_dataset.csv

" Standard :edit command with URI
:edit thither://devbox/home/user/project/main.c

" Browse a remote directory
:edit thither://devbox/var/log/
```

### Navigating Large Files

In a large file viewport buffer:

* **Jump to line**: `:ThitherGoto 2500000` (jumps to line 2.5 million in O(log N) chunks)
* **Jump to percentage**: `:ThitherGoto 75%`
* **Page forward/backward**: `]p` / `[p` or `:ThitherPageNext` / `:ThitherPagePrev`
* **Search entire file**: `:ThitherSearch ERROR` or `:ThitherSearchRegex \bFATAL\b`
  * Matches populate the Neovim Quickfix window.
  * Selecting a match immediately moves the viewport window to that line and sets the cursor!

### Editing and Saving

Edit lines within the viewport window just like any regular buffer.
When you run `:write` (`:w`), `thither.nvim`:
1. Compares the window text with the original slice.
2. Emits an `apply_edit` script:
   `keep [0, start_byte)` + `insert new_window_text` + `keep [end_byte, total_size)`.
3. The server commits the edit atomically using `copy_file_range` and updates the index incrementally.

---

## ⚙️ Configuration

```lua
require("thither").setup({
  -- Path to thither-server executable on remote machines
  server_path = "thither-server",

  -- Additional flags passed to the server
  server_args = {},

  -- Base SSH command (with PuTTY's plink, `port` is passed as -P)
  ssh_command = { "ssh", "-T" },

  -- Persistent remote session: nil = a fresh server per connection,
  -- true = session "default", or a name ([A-Za-z0-9._-], max 32 chars).
  -- Runs the server as `thither-server --stdio --session NAME`.
  session = nil,

  -- Large file subsystem options [PRIORITY]
  large_file_threshold = 10 * 1024 * 1024, -- 10 MB (auto-triggers Large File Mode)
  chunk_size = 65536,                      -- 64 KiB chunk size for indexing
  window_size_lines = 5000,                -- Lines loaded in viewport window
  enable_winbar = true,                    -- Display large file stats in winbar

  -- Timeout for synchronous requests (seconds)
  timeout_seconds = 30,

  -- Host-specific overrides
  hosts = {
    my_remote = {
      port = 2222,
      identity = "~/.ssh/id_ed25519",
      user = "deploy",
      session = "work",
    },
  },
})
```

### Sessions

With `session` set for a host, a dropped connection (network, killed ssh)
reconnects to the same remote daemon on the next operation. Notices tell you
when the daemon runs another thither-server version than the one installed
(once per daemon), when the session was restarted (its pid changed), and when
the server has no session support.

* `:ThitherSessionInfo [host]`: name, daemon pid, start time, version, skew,
  connections and plugins of the host's session.
* `:ThitherRestartSession [host]`: after a confirmation, ends the session and
  disconnects; the next operation starts a new daemon. Use it to upgrade after
  a version skew notice. Open files are unaffected; the session's terminals
  and jobs end with it.

---

## 🧪 Testing

Run the automated test suite with headless Neovim:

```bash
cd thither.nvim
./tests/run.sh
```

Tests cover:
- Binary framing and incremental parser
- Handshake and protocol multiplexing
- VFS file operations and conflict detection
- Large file indexing, viewport window sliding, `apply_edit`, and server-side search
- Neovim buffer integration (`thither://` URI, `BufReadCmd`, `BufWriteCmd`)

---

## 📜 License

MIT License. Open-source text editing tools for high performance.
