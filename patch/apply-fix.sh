#!/bin/bash
# Apply all fixes to ds_compress_lz4.cc
# See patch/PATCH-NOTES.md for details
#
# Usage: ./apply-fix.sh <path-to-ds_compress_lz4.cc>
set -euo pipefail

SRC="$1"

echo "=== Before patch ==="
grep -n 'comp_buf_size\|1204\|contexts\[i\]\|tasks\[i\]' "$SRC" | head -20

# Fix 1: Update comp_buf_size after realloc (line ~135)
# The comp_buf_size member is initialized to 0 and never updated,
# causing my_realloc on every compress_write call.
sed -i '/MYF(MY_FAE | MY_ALLOW_ZERO_PTR)));/a\    comp_file->comp_buf_size = comp_buf_size;' "$SRC"

# Fix 2: Fix 1204 typo to 1024 in BD byte calculation (line ~192)
sed -i 's/1 \* 1204 \* 1024/1 * 1024 * 1024/' "$SRC"

# Fix 3 (PRIMARY): Replace operator[] with .data() raw pointer access
# This bypasses _GLIBCXX_ASSERTIONS bounds check which is corrupted by
# GCC 11 LTO on aarch64. See PXB-3568 for details.

# Add raw pointer declarations before the setup loop
sed -i '/comp_file->contexts.resize(n_chunks);/{
N
a\
\
  /* Use .data() to bypass LTO-corrupted operator[] bounds check (PXB-3568) */\
  comp_thread_ctxt_t *ctx_data = comp_file->contexts.data();\
  std::future<void> *task_data = comp_file->tasks.data();
}' "$SRC"

# Replace contexts[i] with ctx_data[i] in setup loop
sed -i 's/auto &thd = comp_file->contexts\[i\]/comp_thread_ctxt_t *thd = \&ctx_data[i]/' "$SRC"
# Replace tasks[i] assignment with task_data[i]
sed -i 's/comp_file->tasks\[i\] =/task_data[i] =/' "$SRC"
# Fix lambda capture from reference to value (pointer)
sed -i 's/\[&thd\]/[thd]/' "$SRC"
# Fix member access from dot to arrow (thd is now a pointer)
sed -i 's/thd\.from/thd->from/g; s/thd\.to/thd->to/g' "$SRC"

# Replace contexts[i] and tasks[i] in write loop
sed -i 's/const auto &thd = comp_file->contexts\[i\]/const comp_thread_ctxt_t *thd = \&ctx_data[i]/' "$SRC"
sed -i 's/comp_file->tasks\[i\]\.wait/task_data[i].wait/' "$SRC"

# Fix 4: Comment typo "trhead pool" -> "thread pool"
sed -i 's/trhead pool/thread pool/' "$SRC"

echo ""
echo "=== After patch ==="
grep -n 'comp_buf_size\|1024 \* 1024\|ctx_data\|task_data\|thd->' "$SRC" | head -30
