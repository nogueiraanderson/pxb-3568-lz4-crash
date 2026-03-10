# Root Cause Analysis: PXB-3568

## Summary

XtraBackup crashes with Signal 6 (abort) during SST when using
`compress=lz4` on EL9-based PXC Docker images. The crash occurs in
`ds_compress_lz4.cc` during `compress_write` when `LZ4_compress_default`
returns 0 due to an undersized output buffer.

Three interacting bugs produce this crash.

## Bug A: `comp_buf_size` Never Updated After Realloc (Primary)

File: `storage/innobase/xtrabackup/src/ds_compress_lz4.cc`

```cpp
// Line 111: initialized to 0
comp_file->comp_buf_size = 0;

// Lines 132-136: computed but never assigned back
const size_t comp_buf_size = comp_size * n_chunks;
if (comp_file->comp_buf_size < comp_buf_size) {
    comp_file->comp_buf = static_cast<char *>(
        my_realloc(PSI_NOT_INSTRUMENTED, comp_file->comp_buf, comp_buf_size,
                   MYF(MY_FAE | MY_ALLOW_ZERO_PTR)));
    // MISSING: comp_file->comp_buf_size = comp_buf_size;
}
```

The buffer (`comp_buf`) is reallocated to the correct size, but the
member tracking the size (`comp_buf_size`) stays at 0. This means:

1. The realloc fires on **every** `compress_write` call (guard always
   sees 0 < anything).
2. More critically, each compression thread's `to_size` is set to
   `ctrl->chunk_size` (line 160) instead of `LZ4_compressBound(chunk_size)`.

When input data near 64KB is incompressible, LZ4 needs up to 16 extra
bytes for frame headers. The undersized `to_size` causes
`LZ4_compress_default` to return 0, triggering `abort()`.

## LZ4 Library Bug #1374 (Contributing)

[LZ4 issue #1374](https://github.com/lz4/lz4/issues/1374):
`LZ4F_compressFrameBound()` returns an undersized value for inputs of
65533-65535 bytes with B4 (64KB) block size. Fixed in LZ4 1.10.0.

| Platform | System LZ4 | Has #1374 |
|----------|-----------|-----------|
| EL8 | 1.8.3 | No (older API, different code path) |
| EL9 | 1.9.3 | **Yes** |

XtraBackup in PXC Docker images **dynamically links** system `liblz4.so`
(confirmed via `ldd`), so the system library version directly affects
the crash behavior.

The default `compress-chunk-size` in XtraBackup is 64KB, hitting
the exact boundary where #1374 manifests.

## Bug B: Vector Resize Race (Secondary)

```cpp
if (comp_file->contexts.size() < n_chunks) {
    comp_file->contexts.resize(n_chunks);
}
// ...
for (size_t i = 0; i < n_chunks; i++) {
    auto &thd = comp_file->contexts[i];
    // thd is a reference into the vector
    comp_file->tasks[i] =
        comp_ctxt->thread_pool->add_task([&thd](size_t thread_id) {
            thd.to_len = LZ4_compress_default(thd.from, thd.to,
                                               thd.from_len, thd.to_size);
        });
}
```

If `resize` relocates the vector's storage (when growing beyond
capacity), and a previous task is still running against an old
`contexts[i]` address, that is a use-after-free. This is a secondary
concern and warrants TSAN investigation separately.

## Typo: Line 192

```cpp
if (len > 1 * 1204 * 1024) {  // should be 1024, not 1204
```

Sets the parallel compression threshold to ~1.18MB instead of 1MB.
Minor but worth fixing.

## Crash Path

```
compress_write called with len near 64KB
  -> LZ4_compressBound(65534) returns 65550 (16 bytes > chunk_size)
  -> thd.to_size = ctrl->chunk_size = 65534 (undersized)
  -> LZ4_compress_default(src, dst, 65534, 65534) attempts compression
  -> incompressible data: compressed output = ~65540 bytes
  -> 65540 > 65534 (dstCapacity): returns 0
  -> xtrabackup checks return value, calls abort()
  -> Signal 6 (SIGABRT)
```

## Why It Worked Before

On EL8 (LZ4 1.8.3), the boundary arithmetic is slightly different
and the compressed output stays within the buffer. On EL9 (LZ4 1.9.3),
the boundary condition in #1374 causes the output to exceed the buffer
by exactly the frame header size.

Additionally, GCC 11 (EL9 default) has stricter optimization and
RHEL9 default hardening flags that change memory layout, making the
crash deterministic rather than probabilistic.
