# PXB-3568: XtraBackup Signal 6 Crash with LZ4 Compression on EL9

**[PXB-3568](https://perconadev.atlassian.net/browse/PXB-3568)** (Urgent, Open, Unassigned).
XtraBackup crashes with Signal 6 during SST when using `compress=lz4` on
EL9-based PXC Docker images. Affects PXC 8.0.42 and 8.0.45 (both ship
XtraBackup 8.0.35-35).

This repo reproduces the crash, identifies the root cause, proposes a
source code patch, and validates it with a before/after comparison.

## The Bug

In `ds_compress_lz4.cc`, the output buffer for each compression chunk
is `chunk_size` bytes instead of `LZ4_compressBound(chunk_size)` bytes.
For inputs near 64KB, LZ4 needs up to 16 extra bytes for frame headers.
When the compressed output exceeds the undersized buffer,
`LZ4_compress_default` returns 0 and xtrabackup calls `abort()`.

```cpp
// Line 111: initialized to 0, NEVER updated
comp_file->comp_buf_size = 0;

// Line 132-136: computed correctly but never assigned back
const size_t comp_buf_size = comp_size * n_chunks;
if (comp_file->comp_buf_size < comp_buf_size) {
    comp_file->comp_buf = my_realloc(..., comp_buf_size, ...);
    // MISSING: comp_file->comp_buf_size = comp_buf_size;
}

// Line 160: uses chunk_size instead of LZ4_compressBound(chunk_size)
thd.to_size = ctrl->chunk_size;  // BUG: should be comp_size
```

Additional typo at line 192: `1 * 1204 * 1024` should be `1 * 1024 * 1024`.

## Why EL9 and Not EL8

| Factor | EL8 | EL9 |
|--------|-----|-----|
| System LZ4 | 1.8.3 | 1.9.3 ([has #1374 boundary bug](https://github.com/lz4/lz4/issues/1374)) |
| GCC | 8.5 | 11 (stricter optimization) |
| Hardening | Basic | `-fstack-clash-protection`, `-D_GLIBCXX_ASSERTIONS` |
| glibc | 2.28 | 2.34 (stricter heap corruption detection) |

XtraBackup dynamically links system `liblz4.so` in PXC Docker images.

## Proposed Fix

Patch file: [`patch/ds_compress_lz4.patch`](patch/ds_compress_lz4.patch)

Three changes to `storage/innobase/xtrabackup/src/ds_compress_lz4.cc`:

1. Initialize `comp_buf_size` from `LZ4_compressBound` (line 111)
2. Update `comp_buf_size` after `my_realloc` (line 136)
3. Use `comp_size` for `to_size` instead of `chunk_size` (line 160)
4. Fix 1204 to 1024 typo (line 192)

```bash
cd /path/to/percona-xtrabackup && git apply patch/ds_compress_lz4.patch
```

Full proposal: [patch/PATCH-NOTES.md](patch/PATCH-NOTES.md)

## Patch Validation (Before/After)

`just fix-c` runs a self-contained before/after experiment:

1. **BEFORE**: Stock PXC 8.0.45, force SST with LZ4. Expected: Signal 6 crash.
2. **AFTER**: Same image with patched xtrabackup binary. Expected: SST completes.
3. **VERDICT**: Side-by-side comparison with PASS/FAIL.

```bash
just build-patched   # Build xtrabackup from source with patch (~15-20 min)
just fix-c           # Run before/after comparison
```

The patched image is built via multi-stage Docker: clones `percona-xtrabackup`
branch `8.0`, applies `patch/ds_compress_lz4.patch`, builds only the xtrabackup
target, and copies the binary into the PXC 8.0.45 image.

## Quick Start

**Prerequisites**: Docker, Docker Compose, [just](https://github.com/casey/just), ~2GB RAM

```bash
just reproduce       # Trigger LZ4 crash during SST (3 attempts)
just fix-c           # Before/after patch validation (the main experiment)
just fix-a           # Workaround: LZ4 1.10.0 system library
just fix-b           # Workaround: LD_PRELOAD shim
just all             # Run everything
just                 # Show all available commands
```

## Workarounds

Until PXB-3568 is fixed:

| Workaround | Config Change | Risk |
|------------|--------------|------|
| **Switch to zstd** | `[xtrabackup] compress=zstd` | Low (zstd is default since PXB 8.0.34-29) |
| **Disable compression** | Remove `compress` line | None (slower SST) |
| **Upgrade system LZ4** | Replace liblz4 with 1.10.0 | Medium (unsupported library version) |

The `compress=zstd` workaround is recommended. It uses a completely
different code path (`ds_compress_zstd.cc`) that does not have the
buffer sizing bug.

## PKG-842 Is Not the Fix

[PKG-842](https://perconadev.atlassian.net/browse/PKG-842) (Done in
8.0.45) fixed the SST script's XtraBackup version parsing error
(`Cannot determine the xtrabackup 2.x version`). It is a Docker
packaging fix, not a fix for the LZ4 crash.

| Ticket | What It Fixes | Status |
|--------|--------------|--------|
| PKG-842 | SST script version check in Docker image | Done (8.0.45) |
| PXB-3568 | XtraBackup Signal 6 crash with LZ4 | **Open** (no fix) |

Details: [analysis/pkg842-vs-pxb3568.md](analysis/pkg842-vs-pxb3568.md)

## Project Structure

```
pxb-3568-lz4-crash/
├── Justfile                              Task runner
├── reproduce/
│   ├── docker-compose.yml                3-node PXC 8.0.45 cluster
│   ├── my.cnf                            LZ4 compression config
│   └── test-reproduce.sh                 Crash reproduction script
├── fixes/
│   ├── patched-source/                   Fix C: Patched xtrabackup from source
│   │   ├── Dockerfile                    Multi-stage build (clone, patch, compile)
│   │   ├── docker-compose.override.yml
│   │   └── test-fix-c.sh                Before/after comparison
│   ├── lz4-upgrade/                      Fix A: LZ4 1.10.0 (workaround)
│   │   ├── Dockerfile
│   │   ├── docker-compose.override.yml
│   │   └── test-fix-a.sh
│   └── ld-preload-shim/                  Fix B: LD_PRELOAD (workaround)
│       ├── Dockerfile
│       ├── lz4_fix.c                     Standalone shim source
│       ├── docker-compose.override.yml
│       └── test-fix-b.sh
├── patch/
│   ├── ds_compress_lz4.patch             Proposed source fix
│   └── PATCH-NOTES.md                    Patch explanation
├── analysis/
│   ├── root-cause.md                     Full root cause analysis
│   ├── gcc8-vs-gcc11.md                  Why EL9 exposes the bug
│   ├── pkg842-vs-pxb3568.md             PKG-842 is not the fix
│   └── lz4-boundary-math.md             64KB boundary arithmetic
└── evidence/                             Test outputs (gitignored)
```

## References

- JIRA: [PXB-3568](https://perconadev.atlassian.net/browse/PXB-3568) (Signal 6 with LZ4)
- JIRA: [PKG-842](https://perconadev.atlassian.net/browse/PKG-842) (Docker SST script fix)
- LZ4: [Issue #1374](https://github.com/lz4/lz4/issues/1374) (64KB boundary bug)
- Forum: [Thread #40148](https://forums.percona.com/t/full-crash-percona-after-oom/40148)
- Source: [percona/percona-xtrabackup](https://github.com/percona/percona-xtrabackup) branch `8.0`

## License

This reproduction lab is provided for educational and diagnostic purposes.
Percona XtraBackup source code is licensed under GPL v2.
