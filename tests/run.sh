#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

echo "=========================================="
echo " Running thither.nvim test suite          "
echo "=========================================="

test_files=(
  "tests/test_frame.lua"
  "tests/test_client.lua"
  "tests/test_vfs.lua"
  "tests/test_large_file.lua"
  "tests/test_integration.lua"
)

for t in "${test_files[@]}"; do
  echo ""
  echo "--- $t ---"
  nvim --headless -u NONE -c "set rtp+=$DIR" -c "luafile $DIR/$t" -c "qa!"
done

echo ""
echo "=========================================="
echo " ALL TESTS PASSED!                        "
echo "=========================================="
