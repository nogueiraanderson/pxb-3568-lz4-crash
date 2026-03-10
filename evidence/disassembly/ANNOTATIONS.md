# Disassembly Annotations: compress_write (aarch64, GCC 11.5.0 + LTO)

Binary: `/usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup` from PXC 8.0.45 Docker image
Architecture: aarch64, OracleLinux 9, GCC 11.5.0, LTO enabled

## DEFINITIVE FINDING: LTO-Corrupted Element Stride

The LTO optimizer generates **36920 (0x9038)** as the element stride for iterating
over `std::vector<comp_thread_ctxt_t>`. The correct stride is **40 (0x28)** bytes
(sizeof(comp_thread_ctxt_t) = 5 fields x 8 bytes).

36920 = 923 x 40 = `contexts.capacity() * sizeof(element)` (NOT `n_chunks`,
which is 129 at crash time). The stride is a compile-time constant embedded in the
binary. The correlation with the runtime contexts capacity may indicate the LTO
optimizer confused a size-expression with a stride-expression, or may be coincidental.
The exact LTO optimization error cannot be determined without inspecting GCC's
intermediate representation.

### Crash Mechanism

1. **Iteration 0** (i=0): byte offset = 0. Accesses `contexts[0]` correctly.
2. **Iteration 1** (i=1): byte offset = 36920. With contexts at 923 capacity
   (36920 bytes), this writes at exactly `contexts.end()`, corrupting heap
   metadata (malloc chunk header) and adjacent heap allocations.
3. The struct members `tasks` and `contexts` are adjacent in `ds_compress_file_t`
   (offsets 40 and 64), but their heap data buffers are 81KB apart. The wrong
   stride corrupts heap memory past contexts' allocation, NOT the tasks vector
   struct metadata directly.
4. An assertion fires (exact trigger path unclear due to prior corruption),
   `std::__replacement_assert` calls `abort()`.
5. GDB showed tasks.size()=129 and contexts.size()=923. The contexts size does
   not match the current n_chunks=129; the mismatch may be due to LTO-reordered
   resize, prior corruption, or different calling context.

### Why It Needs Concurrent Writes

The crash requires enough redo log data to produce n_chunks > 1. With n_chunks=1,
the loop runs once and exits before the wrong stride causes an out-of-bounds access.
Concurrent database writes generate redo log activity that increases the buffer size,
producing more chunks.

## Key Addresses

### Setup Loop (first pass: populate contexts with from/to pointers)

| Address | Instruction | Meaning |
|---------|-------------|---------|
| `0x7f9d88` | `ldr x26, [x27, #1144]` | Load COMPRESS_CHUNK_SIZE |
| `0x7f9d8c-0x7f9d94` | `mov x24/x22/x20, #0x0` | Initialize offsets and counter |
| `0x7f9d98` | `cbz x23, 0x7fa2e0` | Skip if n_chunks == 0 |
| `0x7f9de4` | `cmp x0, x20` | **contexts bounds check**: size() vs i |
| `0x7f9de8` | `b.ls 0x7fa264` | Branch to assertion if size <= i |
| `0x7f9dec` | `add x3, x4, x22` | **Element address** = base + byte_offset |
| `0x7f9dfc` | `str x2, [x4, x22]` | Store `from` pointer |
| `0x7f9e10` | `stp x1, x2, [x3, #8]` | Store `from_len` and `to` at +8, +16 |
| `0x7f9e24` | `str x21, [x3, #32]` | Store `to_size` at +32 |
| `0x7f9e34-0x7f9e40` | `ldp/sub/cmp/b.cs` | **tasks bounds check**: i vs tasks.size() |
| `0x7f9ecc` | `add x20, x20, #0x1` | i++ |
| `0x7f9ed0` | `mov x1, #0x9038` | **BUG: stride = 36920 instead of 40** |
| `0x7f9ed8` | `add x22, x22, x1` | byte_offset += 36920 (should be += 40) |
| `0x7f9edc-0x7f9ee0` | `cmp x20, x23; b.ne` | Loop while i != n_chunks |

### Write Loop (second pass: collect results and write to datasink)

| Address | Instruction | Meaning |
|---------|-------------|---------|
| `0x7fa050` | `add x22, x22, x26` | Advance contexts pointer by x26 |
| `0x7fa054` | `ldr x3, [x22, #24]` | Load `to_len` at offset 24 |
| `0x7fa098` | `add x20, x20, #0x1` | i++ |
| `0x7fa09c` | `mov x0, #0x9038` | **Same wrong stride: 36920** |
| `0x7fa0a0` | `add x26, x26, x0` | byte_offset += 36920 |

### End-pointer Computation

| Address | Instruction | Meaning |
|---------|-------------|---------|
| `0x7fa24c` | `mov x1, #0x9038` | 36920 |
| `0x7fa250` | `madd x1, x23, x1, x4` | end = n_chunks * 36920 + base |
| `0x7fa254` | `cmp x3, x1` | Compare vector end against computed end |

### Assertion Sites

| Address | Vector | Line |
|---------|--------|------|
| `0x7f99c8` | contexts (in write loop) | 1045 (stl_vector.h) |
| `0x7f99e8` | tasks (in write loop) | 1045 |
| `0x7f9c00` | contexts (in write loop, second copy) | 1045 |
| `0x7f9c20` | tasks (in write loop, second copy) | 1045 |
| `0x7fa264` | contexts (in setup loop) | 1045 |
| `0x7fa284` | tasks (in setup loop) | 1045 |

### Support Functions

| Address | Function |
|---------|----------|
| `0x7f1a30` | `std::__replacement_assert` (calls printf then abort) |

## Register Map (at crash point, from GDB)

| Register | Value | Meaning |
|----------|-------|---------|
| x20 | 1 | Loop index i = 1 |
| x22 | 36920 | Byte offset (should be 40 for i=1) |
| contexts.size() | 923 | Correct (not yet corrupted) |
| tasks.size() | 129 | **Corrupted** by out-of-bounds write |

## Struct Layout Verification

Fields accessed from element pointer (x3 = base + x22):
- `[x3, #0]` = from (8 bytes)
- `[x3, #8]` = from_len (8 bytes)
- `[x3, #16]` = to (8 bytes)
- `[x3, #24]` = to_len (8 bytes)
- `[x3, #32]` = to_size (8 bytes)
- Total: 40 bytes per element (correct struct layout in memory)

The stride 40 is correct for accessing fields WITHIN an element. The bug is in
advancing BETWEEN elements: 36920 instead of 40.

## Files

- `compress_write-full.txt`: Full function disassembly (0x7f9800-0x7fa400)
- `compress_write-assertion-sites.txt`: Assertion region (0x7f9c00-0x7fa300)
- `replacement_assert.txt`: The `__replacement_assert` function (0x7f1a00-0x7f1a80)
