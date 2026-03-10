# Proposed Patch for PXB-3568

## What This Patch Changes

Three fixes in `storage/innobase/xtrabackup/src/ds_compress_lz4.cc`:

### 1. Initialize `comp_buf_size` from `LZ4_compressBound` (line 111)

```diff
- comp_file->comp_buf_size = 0;
+ comp_file->comp_buf_size = LZ4_compressBound(comp_ctxt->ctrl.chunk_size);
```

The member was initialized to 0, making the realloc guard in
`compress_write` always true (unnecessary realloc on every call).

### 2. Update `comp_buf_size` after realloc (line 136)

```diff
  comp_file->comp_buf = static_cast<char *>(
      my_realloc(PSI_NOT_INSTRUMENTED, comp_file->comp_buf, comp_buf_size,
                 MYF(MY_FAE | MY_ALLOW_ZERO_PTR)));
+ comp_file->comp_buf_size = comp_buf_size;
```

The critical bug. `comp_buf_size` (local) is computed but never
assigned to `comp_file->comp_buf_size` (member). This is the root
cause of the Signal 6 crash.

### 3. Use `comp_size` for `to_size` (line 160)

```diff
- thd.to_size = ctrl->chunk_size;
+ thd.to_size = comp_size;
```

Each compression thread's output buffer size was set to `chunk_size`
instead of `LZ4_compressBound(chunk_size)`. For inputs near 64KB,
LZ4 needs up to 16 bytes more than the input for frame headers.

### 4. Fix typo in parallel threshold (line 192)

```diff
- if (len > 1 * 1204 * 1024) {
+ if (len > 1 * 1024 * 1024) {
```

`1204` should be `1024`. Sets threshold to 1MB instead of ~1.18MB.

## How to Apply

```bash
cd /path/to/percona-xtrabackup
git checkout 8.0
git apply /path/to/ds_compress_lz4.patch
```

## How to Verify

Build XtraBackup with ASAN on EL9 and run LZ4-compressed backups:

```bash
cmake -DWITH_ASAN=ON -DWITH_UBSAN=ON ...
# Then run a backup with compress=lz4 against a database with
# varied row sizes to hit the 64KB boundary
```

## Scope

This patch addresses only the buffer sizing bug (Bug A) and the typo.
It does not address the secondary vector resize race (Bug B) identified
in the thread pool task dispatch, which warrants separate investigation
under TSAN.
