#!/bin/bash
# Apply fixes to ds_compress_lz4.cc
# See patch/PATCH-NOTES.md for details
set -euo pipefail

SRC="$1"

echo "=== Before patch ==="
grep -n 'comp_buf_size\|1204' "$SRC" | head -10

# Fix 1: Update comp_buf_size after realloc (line ~135)
# The comp_buf_size member is initialized to 0 and never updated,
# causing my_realloc on every compress_write call.
sed -i '/MYF(MY_FAE | MY_ALLOW_ZERO_PTR)));/a\    comp_file->comp_buf_size = comp_buf_size;' "$SRC"

# Fix 2: Fix 1204 typo to 1024 in BD byte calculation (line ~192)
sed -i 's/1 \* 1204 \* 1024/1 * 1024 * 1024/' "$SRC"

echo "=== After patch ==="
grep -n 'comp_buf_size\|1024 \* 1024' "$SRC" | head -10
