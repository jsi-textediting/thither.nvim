#!/usr/bin/env bash
# Runs the thither.nvim test suite.
#
#   tests/run.sh
#
# Environment:
#   NVIM            nvim executable (default: nvim)
#   THITHER_SERVER  thither-server binary for the live tests
#                   (default: <repo parent>/thither/build/thither-server)
#   THITHER_REQUIRE_SERVER=1  fail instead of skipping the live tests when
#                   the server binary is missing
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
NVIM="${NVIM:-nvim}"
export THITHER_SERVER="${THITHER_SERVER:-$ROOT/thither/build/thither-server}"

# nvim on Windows (Git Bash) needs Windows paths
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
NDIR="$(native_path "$DIR")"
if [[ -x "$THITHER_SERVER" ]]; then
  THITHER_SERVER="$(native_path "$THITHER_SERVER")"
fi

echo "=========================================="
echo " Running thither.nvim test suite          "
echo "=========================================="

offline_tests=(
  "tests/test_frame.lua"
  "tests/test_offline.lua"
)
server_tests=(
  "tests/test_client.lua"
  "tests/test_vfs.lua"
  "tests/test_large_file.lua"
  "tests/test_integration.lua"
)

failed=0
skipped=0

run_test() {
  local t="$1"
  echo ""
  echo "--- $t ---"
  # A Lua error inside :luafile does not change nvim's exit status, so run the
  # file under pcall and leave with :cquit on failure.
  if ! "$NVIM" --headless -u NONE -i NONE -n \
      --cmd "set rtp^=$NDIR" \
      -c "lua local ok, e = xpcall(dofile, debug.traceback, '$NDIR/$t'); if not ok then io.stderr:write('FAILED: ' .. tostring(e) .. '\n'); vim.cmd('cquit 1') end" \
      -c "qa!"; then
    echo ""
    echo "!!! $t FAILED"
    failed=$((failed + 1))
  fi
}

for t in "${offline_tests[@]}"; do run_test "$t"; done

if [[ -x "$THITHER_SERVER" || -f "$THITHER_SERVER" ]]; then
  for t in "${server_tests[@]}"; do run_test "$t"; done
else
  if [[ "${THITHER_REQUIRE_SERVER:-0}" == "1" ]]; then
    echo "thither-server not found at $THITHER_SERVER" >&2
    exit 1
  fi
  echo ""
  echo "--- skipping live-server tests: no thither-server at $THITHER_SERVER ---"
  skipped=${#server_tests[@]}
fi

echo ""
echo "=========================================="
if [[ $failed -ne 0 ]]; then
  echo " $failed TEST FILE(S) FAILED"
  echo "=========================================="
  exit 1
fi
if [[ $skipped -ne 0 ]]; then
  echo " PASSED ($skipped live-server test files skipped)"
else
  echo " ALL TESTS PASSED!"
fi
echo "=========================================="
