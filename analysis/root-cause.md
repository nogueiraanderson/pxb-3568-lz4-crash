# Root Cause Analysis: PXB-3568

## Summary

XtraBackup crashes with Signal 6 (SIGABRT) during LZ4-compressed backups on
EL9-based PXC Docker images. The crash is caused by GCC 11/12
Link-Time Optimization (LTO) generating an incorrect element stride in the
`compress_write()` function's vector traversal loops. The stride 0x9038
(36920) appears where 0x28 (40 = `sizeof(comp_thread_ctxt_t)`) is expected.

## The Crash Mechanism

### What Happens

1. `compress_write()` in `ds_compress_lz4.cc` is called from `Redo_Log_Writer::write_buffer()`
2. The function resizes `std::vector<comp_thread_ctxt_t> contexts` to `n_chunks`
3. It accesses `comp_file->contexts[i]` via `operator[]`
4. `operator[]` contains `_GLIBCXX_ASSERTIONS` bounds check: `assert(__n < this->size())`
5. GCC 11/12 LTO generates incorrect element stride in the loop
6. The wrong stride causes out-of-bounds memory writes starting at iteration 1
7. These writes corrupt heap metadata or adjacent allocations
8. An assertion fires (exact trigger path discussed below), calling `abort()`
9. Signal 6 (SIGABRT)

### GDB Evidence

Register state at crash point:

```
x19 (comp_file) = 0x3c0ec90
x20 (index i)   = 1              <-- second iteration
x22             = 36920 (0x9038) <-- LTO-generated stride (should be 40)
x23 (n_chunks)  = 129
x25 (len)       = 8388608 (8MB)
tasks.size()    = 129            (from heap pointers: (0x3c10820 - 0x3c10010) / 16)
contexts.size() = 923            (from heap pointers: (0x3c2d4d8 - 0x3c244a0) / 40)
```

**Note on the size mismatch**: `tasks.size()` = 129 matches the current
`n_chunks`, but `contexts.size()` = 923 does not. After `resize(129)`,
contexts should also show size 129. The discrepancy has three possible
explanations:

1. LTO reordered or eliminated the `contexts.resize()` call
2. The `_M_finish` pointer in the contexts vector was corrupted by the
   wrong stride during a prior `compress_write()` invocation
3. The crash occurred during a call where `n_chunks` was actually 923
   (from a larger buffer) and `x23=129` reflects a different register
   assignment under LTO

We cannot determine which explanation is correct from the available
evidence. The GDB snapshot captures state after corruption has already
occurred.

### Assembly Analysis

Full disassembly of the LTO-generated `compress_write` confirms the wrong
stride. The setup loop at `0x7f9d88-0x7f9ee0` uses register x22 as a byte
offset into the contexts array, incremented each iteration:

```asm
; Loop increment (end of each iteration):
0x7f9ecc:  add x20, x20, #0x1      ; i++
0x7f9ed0:  mov x1, #0x9038          ; stride = 36920 (BUG: should be 40)
0x7f9ed8:  add x22, x22, x1         ; byte_offset += 36920

; Element access (start of each iteration):
0x7f9dec:  add x3, x4, x22          ; element_ptr = contexts.data() + byte_offset
0x7f9dfc:  str x2, [x4, x22]        ; store .from at element_ptr + 0
0x7f9e10:  stp x1, x2, [x3, #8]     ; store .from_len and .to at +8, +16
0x7f9e24:  str x21, [x3, #32]       ; store .to_size at +32
```

The struct fields are accessed at offsets 0, 8, 16, 24, 32 (confirming 40-byte
struct layout). But the **inter-element stride is 36920 instead of 40**.

The same wrong stride appears in the write loop and end-pointer computation:
```asm
0x7fa09c:  mov x0, #0x9038          ; same wrong stride
0x7fa0a0:  add x26, x26, x0         ; byte_offset += 36920
...
0x7fa24c:  mov x1, #0x9038          ; 36920
0x7fa250:  madd x1, x23, x1, x4     ; end = n_chunks * 36920 + base
```

### Arithmetic

```
stride in binary:     0x9038 = 36920
expected stride:      0x28   = 40 = sizeof(comp_thread_ctxt_t)
36920 / 40          = 923
contexts.capacity() = 923 elements = 36920 bytes (from GDB heap pointers)
```

The stride 36920 equals `contexts.capacity() * sizeof(comp_thread_ctxt_t)`.
However, 0x9038 is a **compile-time constant** embedded in the binary
(`mov x1, #0x9038`). It cannot depend on runtime vector capacity. The
correlation may indicate LTO confused a size-expression (total array bytes)
with a stride-expression (per-element bytes) during optimization, or it
may be coincidental. Determining the exact LTO optimization error would
require inspecting GCC's LTO intermediate representation, which is outside
the scope of this analysis.

**What is NOT claimed**: The earlier version of this document stated
`36920 = n_chunks * sizeof(T)`. This was incorrect: at crash time,
`n_chunks` = 129 and `129 * 40 = 5160`, not 36920. The value 923 is
the observed `contexts.size()` (or capacity), not `n_chunks`.

### The Memory Corruption

**Struct layout** (`ds_compress_file_t`, from source lines 50-58):

```
offset  0: dest_file         (8 bytes)
offset  8: comp_ctxt         (8 bytes)
offset 16: bytes_processed   (8 bytes)
offset 24: comp_buf          (8 bytes)
offset 32: comp_buf_size     (8 bytes)
offset 40: tasks             (24 bytes: _M_start, _M_finish, _M_end_of_storage)
offset 64: contexts          (24 bytes: _M_start, _M_finish, _M_end_of_storage)
```

The struct members `tasks` and `contexts` are adjacent (offsets 40-63 and
64-87). However, their heap-allocated data buffers are NOT adjacent:

```
tasks heap:    0x3c10010 - 0x3c10820 (2064 bytes, 129 futures)
contexts heap: 0x3c244a0 - 0x3c2d4d8 (36920 bytes, 923 elements)
gap:           81024 bytes (0x13c80)
```

With the wrong stride, iteration 1 writes at `contexts.data() + 36920`:

```
contexts.data() = 0x3c244a0
iteration 1:      0x3c2d4d8 (= contexts.data() + 36920)
contexts.end():   0x3c2d4d8
```

Iteration 1 writes exactly at `contexts.end()`, corrupting heap metadata
(malloc chunk header) and any adjacent heap allocations. The writes span
offsets +0 through +32 (5 struct fields), corrupting 40 bytes past the
allocation boundary.

**What is NOT claimed**: The earlier version stated the wrong stride
corrupts the tasks vector because it is "stored adjacent to contexts."
The struct members are adjacent, but the wrong stride operates on heap
data, not struct members. The heap buffers are 81KB apart. The corruption
hits heap metadata, not the tasks vector directly.

The exact assertion path that fires (whether it is a corrupted tasks
bounds check or a contexts bounds check with corrupted metadata) cannot
be determined with certainty from the post-crash GDB state, since
multiple memory locations may have been corrupted by the time the
assertion triggers.

## Why It Only Affects EL9

Three conditions must all be present:

| Condition | EL8 | EL9 |
|-----------|-----|-----|
| GCC version | 8.5 | **11.5+ or 12** (generates LTO bug) |
| `_GLIBCXX_ASSERTIONS` | Not default | **Default** (redhat-rpm-config) |
| LTO build | Yes | **Yes** (confirmed by `.lto_priv.1` suffix) |

- **GCC 11 and GCC 12 LTO** both generate incorrect element stride
  in the compress_write function. Tested: GCC 11.5.0 (system) and GCC 12
  (gcc-toolset-12) both produce binaries with the 0x9038 stride bug.
  GCC 8 (EL8) does not have this bug.
- **`_GLIBCXX_ASSERTIONS`** enables the bounds check in `operator[]`.
  Without it, the wrong stride still exists but does not trigger an abort.
  The no-assertions build completes backups, but backup data integrity has
  not been validated (no `--prepare`, restore, or checksum was performed).
- The bug is specific to the **full program LTO context**. Standalone
  programs compiled with the same flags do not reproduce it.

## Concurrency

`compress_write()` has no internal locking (no mutex, no atomic operations).
It dispatches `n_chunks` compression tasks to a thread pool but joins all
futures before returning (`tasks[i].wait()`). The function is not designed
for concurrent access on the same `ds_compress_file_t*` and would be
catastrophically unsafe if called concurrently (unsynchronized mutations of
`comp_buf`, `comp_buf_size`, and both vectors).

The calling pattern (datasink write callback from `Redo_Log_Writer`) appears
to serialize calls per file. However, this has not been formally verified by
tracing the caller chain under concurrent workloads. A concurrency bug
(independent of LTO) cannot be fully ruled out without instrumentation.

## Why the Crash Requires Concurrent Writes

The crash only occurs when the redo log writer is actively compressing data
(concurrent INSERT workload generates redo log entries). Without concurrent
writes, the redo log buffer is small enough that `compress_write` receives
small inputs that do not trigger the code path with the corrupted stride.

With concurrent writes, `Redo_Log_Writer::write_buffer()` passes 8MB+
buffers, creating 129+ chunks. The loop iterates past the first element,
hitting the incorrect stride.

## The Fix

Replace `std::vector::operator[]` with `std::vector::data()` raw pointer access:

```cpp
// BEFORE (buggy):
auto &thd = comp_file->contexts[i];    // goes through operator[], assertion fires

// AFTER (fixed):
comp_thread_ctxt_t *ctx_data = comp_file->contexts.data();
comp_thread_ctxt_t *thd = &ctx_data[i]; // raw pointer, no assertion check
```

`.data()` returns a raw `comp_thread_ctxt_t*` pointer. Array subscript on a
raw pointer uses normal pointer arithmetic, completely bypassing the
LTO-corrupted `operator[]` bounds check.

**Validation status**: The patched binary (GCC 12, LTO ON, assertions ON)
completed 5/5 backup runs without crashing. However, the following
validations remain open:

- Patched binary disassembly has not been checked to confirm the stride
  is correct (0x28 instead of 0x9038)
- Backup data integrity has not been validated (`--prepare`, restore,
  and checksum comparison)
- The experiments used XtraBackup branch HEAD (revision `c9efec73`), not
  the exact stock revision (`be447639`), introducing a source confound

## Additional Bugs (Non-Crash)

### comp_buf_size Never Updated (line 136)

```cpp
if (comp_file->comp_buf_size < comp_buf_size) {
    comp_file->comp_buf = static_cast<char *>(
        my_realloc(PSI_NOT_INSTRUMENTED, comp_file->comp_buf, comp_buf_size,
                   MYF(MY_FAE | MY_ALLOW_ZERO_PTR)));
    // MISSING: comp_file->comp_buf_size = comp_buf_size;
}
```

`comp_buf_size` (local) is computed but never assigned to
`comp_file->comp_buf_size` (member, initialized to 0). Causes unnecessary
`my_realloc` on every `compress_write` call.

### Typo: 1204 Should Be 1024 (line 192)

```cpp
} else if (COMPRESS_CHUNK_SIZE <= 1 * 1204 * 1024) {  // should be 1024
```

Sets the BD byte max block size threshold to ~1.18MB instead of 1MB.

## Why Earlier Fix Attempts Failed

| Attempt | Why It Failed |
|---------|--------------|
| LZ4 1.10.0 upgrade | Inconclusive: SST failed at PKG-842 script check before reaching compression. LZ4 library is not the root cause regardless (bug is in LTO-generated code). |
| Buffer sizing patch | Fixed real bugs but not the LTO stride corruption |
| Binary stride patch (0x9038 to 0x28) | Other LTO-corrupted constants exist; patching one is insufficient |
| LD_PRELOAD abort() override | Suppressing abort causes infinite retry loop in inline assertion |

## Comparison with zstd Datasink

The zstd datasink (`ds_compress_zstd.cc`) works because it does NOT use
`std::vector` at all. It uses raw `char*` buffers and ZSTD's built-in
streaming API with thread pool. No `operator[]`, no `_GLIBCXX_ASSERTIONS`,
no LTO code generation issue.

## Open Questions

1. **Patched disassembly**: Does the `.data()` fix produce correct stride
   (0x28) in the generated assembly, or does LTO also miscompile pointer
   arithmetic on the raw pointer?
2. **Data integrity**: Do backups from the no-assertions and patched builds
   survive `--prepare`, decompression, restore, and checksum validation?
3. **Source revision confound**: The experiment rebuilds used branch HEAD
   (`c9efec73`), not the stock revision (`be447639`). Repeating on the
   exact stock revision would eliminate this confound.
4. **Concurrency**: Can `compress_write()` be entered concurrently for
   the same file handle under specific workloads? Instrumentation (logging
   thread ID and comp_file address on entry/exit) would rule this out.
5. **GCC bug report**: Should be filed after either producing a minimal
   reproducer or assembling a stock-revision evidence package.
6. **Default chunk size**: All reproduction used `compress-chunk-size=65534`.
   Does the default 65536 also trigger the crash?
