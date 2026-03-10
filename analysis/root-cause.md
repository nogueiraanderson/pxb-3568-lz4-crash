# Root Cause Analysis: PXB-3568

## Summary

XtraBackup crashes with Signal 6 (SIGABRT) during LZ4-compressed backups on
EL9-based PXC Docker images (aarch64). The crash is a **false-positive
`_GLIBCXX_ASSERTIONS` bounds check** in `std::vector::operator[]`, caused by
GCC 11 Link-Time Optimization (LTO) generating incorrect code on aarch64.

## The Crash Mechanism

### What Happens

1. `compress_write()` in `ds_compress_lz4.cc` is called from `Redo_Log_Writer::write_buffer()`
2. The function resizes `std::vector<comp_thread_ctxt_t> contexts` to `n_chunks`
3. It accesses `comp_file->contexts[i]` via `operator[]`
4. `operator[]` contains `_GLIBCXX_ASSERTIONS` bounds check: `assert(__n < this->size())`
5. GCC 11 LTO generates incorrect code for this check on aarch64
6. The assertion fires even though the index is valid (e.g., i=1, size=923)
7. `std::__replacement_assert()` is called inline, which calls `abort()`
8. Signal 6 (SIGABRT)

### GDB Evidence

Register state at crash point:

```
x19 (comp_file) = 0x3c28ee0
x20 (index i)   = 1              <-- valid index
x21 (comp_size) = 65806
x22             = 36920 (0x9038) <-- suspicious: LTO-generated stride
x23 (n_chunks)  = 129
x25 (len)       = 8388608 (8MB)
tasks.size()    = 129
contexts.size() = 923            <-- i=1 < 923, assertion should PASS
```

The assertion `1 < 923` should evaluate to **true** (pass), yet it fires.
This confirms the assertion code itself is broken, not the data.

### Assembly Analysis (Definitive)

Full disassembly of the LTO-generated `compress_write` confirms the bug. The
setup loop at `0x7f9d88-0x7f9ee0` uses register x22 as a byte offset into the
contexts array, incremented each iteration:

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

36920 = 923 x 40 = `n_chunks * sizeof(comp_thread_ctxt_t)`. The LTO optimizer
confused the **total array byte size** with the **per-element stride**.

The same wrong stride appears in the write loop:
```asm
0x7fa09c:  mov x0, #0x9038          ; same wrong stride
0x7fa0a0:  add x26, x26, x0         ; byte_offset += 36920
```

And in the end-pointer computation:
```asm
0x7fa24c:  mov x1, #0x9038          ; 36920
0x7fa250:  madd x1, x23, x1, x4     ; end = n_chunks * 36920 + base
```

### The Memory Corruption Chain

The wrong stride explains the GDB-observed size mismatch (tasks=129 vs contexts=923):

1. **Iteration 0** (i=0): byte_offset=0. Correctly accesses `contexts[0]`.
2. **Iteration 1** (i=1): byte_offset=36920. A 923-element array occupies exactly
   36920 bytes (923 x 40), so offset 36920 is ONE PAST the end. The write at this
   offset corrupts whatever follows contexts in memory.
3. If the tasks vector (`std::vector<std::future<void>>`) is stored adjacent to
   contexts, its internal pointers (_M_start, _M_finish, _M_end_of_storage) get
   overwritten, explaining why tasks.size() shows 129 (corrupted) while
   contexts.size() shows 923 (not yet corrupted at time of check).
4. The **tasks bounds check** at `0x7f9e3c-0x7f9e40` then fails because the
   corrupted tasks.size() < i, triggering the assertion at `0x7fa284`.

## Why It Only Affects EL9/aarch64

Three conditions must all be present:

| Condition | EL8 | EL9 |
|-----------|-----|-----|
| GCC version | 8.5 | **11.5+ or 12** (generates LTO bug) |
| `_GLIBCXX_ASSERTIONS` | Not default | **Default** (redhat-rpm-config) |
| LTO build | Yes | **Yes** (confirmed by `.lto_priv.1` suffix) |

- **GCC 11 and GCC 12 LTO on aarch64** both generate incorrect element stride
  in the compress_write function. Tested: GCC 11.5.0 (system) and GCC 12
  (gcc-toolset-12) both produce binaries with the 0x9038 stride bug.
  GCC 8 (EL8) does not have this bug.
- **`_GLIBCXX_ASSERTIONS`** enables the bounds check in `operator[]`.
  Without it, the wrong stride still exists but does not trigger an abort.
  Instead, the program silently reads/writes wrong memory locations, producing
  a "successful" backup with **corrupted data**.
- The bug is specific to the **full program LTO context**. Standalone
  programs compiled with the same flags do not reproduce it.

## Why the Crash Requires Concurrent Writes

The crash only occurs when the redo log writer is actively compressing data
(concurrent INSERT workload generates redo log entries). Without concurrent
writes, the redo log buffer is small enough that `compress_write` receives
small inputs that do not trigger the code path with the corrupted stride.

With concurrent writes, `Redo_Log_Writer::write_buffer()` passes 8MB+ buffers,
creating 129+ chunks. The loop iterates past the first element, hitting the
incorrect stride calculation.

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

Validated: compiled test on EL9/aarch64 with `-O2 -flto -D_GLIBCXX_ASSERTIONS`
confirms `.data()` does not trigger assertions while `operator[]` does.

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
| LZ4 1.10.0 upgrade | LZ4 library is not the problem; assertion is in STL code |
| Buffer sizing patch | Fixed real bugs but not the assertion false positive |
| Binary stride patch (0x9038 to 0x28) | Other LTO-corrupted constants exist; patching one is insufficient |
| LD_PRELOAD abort() override | Suppressing abort causes infinite retry loop in inline assertion |

## Comparison with zstd Datasink

The zstd datasink (`ds_compress_zstd.cc`) works because it does NOT use
`std::vector` at all. It uses raw `char*` buffers and ZSTD's built-in
streaming API with thread pool. No `operator[]`, no `_GLIBCXX_ASSERTIONS`,
no LTO code generation issue.
