# PXB-3568: XtraBackup Signal 6 Crash with LZ4 Compression

**[PXB-3568](https://perconadev.atlassian.net/browse/PXB-3568)** (Urgent, Open, Unassigned).
XtraBackup crashes with Signal 6 during backup when using `compress=lz4` on
EL9-based PXC Docker images. Affects PXC 8.0.42 and 8.0.45 (both ship
XtraBackup 8.0.35-35). This causes SST failures in PXC clusters.

This repo reproduces the crash, identifies the root cause, and provides a fix.

## Root Cause

The crash is a **false-positive `_GLIBCXX_ASSERTIONS` bounds check** in
`std::vector::operator[]` inside `compress_write()` (`ds_compress_lz4.cc`).

GCC 11.5.0 on aarch64 with Link-Time Optimization (LTO, `-flto`) generates
incorrect code for the `operator[]` bounds check. The assertion
`__n < this->size()` fires even when the index is valid (e.g., i=1 with
size=923). EL9 enables `_GLIBCXX_ASSERTIONS` by default via redhat-rpm-config.

Key evidence:
- GDB register analysis: `x20=1` (index), `contexts.size()=923` (valid access)
- Assembly shows LTO-generated stride 0x9038 (36920) instead of 0x28 (40 bytes)
- Standalone test with same struct/vector pattern does NOT crash (requires full
  program LTO context)
- The zstd datasink uses raw buffers (no `std::vector`), which is why it works

## Proposed Fix

Replace `std::vector::operator[]` with `std::vector::data()` raw pointer
access. `.data()` returns a raw pointer that bypasses the bounds-checked
`operator[]`, avoiding the LTO-corrupted assertion code entirely.

See [`patch/PATCH-NOTES.md`](patch/PATCH-NOTES.md) for full patch details.

**Summary of changes** in `ds_compress_lz4.cc`:

| Change | Description |
|--------|-------------|
| Use `.data()` | Replace `contexts[i]` / `tasks[i]` with raw pointer access |
| Fix `comp_buf_size` | Update member after `my_realloc` (was always 0) |
| Fix 1204 typo | `1 * 1204 * 1024` should be `1 * 1024 * 1024` |

Patch file: [`patch/ds_compress_lz4.patch`](patch/ds_compress_lz4.patch)
Fixed source: [`fixes/ds_compress_lz4_fixed.cc`](fixes/ds_compress_lz4_fixed.cc)

## Validated Results

Tested on PXC 8.0.45 Docker image (aarch64, OracleLinux 9, LZ4 1.9.3):

| Test | Command | Result |
|------|---------|--------|
| Stock + LZ4 + concurrent writes | `xtrabackup --backup --compress=lz4` | **CRASH (Signal 6)** |
| Stock + LZ4 (no concurrent) | Same, idle database | SUCCESS |
| Stock + zstd | `xtrabackup --backup --compress=zstd` | **SUCCESS** |
| Stock + no compression | `xtrabackup --backup` | **SUCCESS** |
| LZ4 1.10.0 upgrade | System liblz4 upgraded | **CRASH (Signal 6)** |
| `.data()` bypass test | Compiled with same flags on EL9 | **PASSES** |

The crash requires concurrent database writes (redo log activity) to trigger
the LZ4 compression path through `Redo_Log_Writer::write_buffer`.

## Reproduce

**Prerequisites**: Docker, Docker Compose, ~2GB RAM

```bash
# 1. Start a PXC 8.0.45 node
docker compose -f reproduce/docker-compose.yml up -d pxc-node1

# 2. Wait ~25s for bootstrap, then load data
docker exec lz4-pxc-node1 mysql -uroot -proot -e "CREATE DATABASE pxb3568"
docker exec lz4-pxc-node1 mysql -uroot -proot pxb3568 -e "
    CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY, data BLOB) ENGINE=InnoDB;
    INSERT INTO t (data) SELECT UNHEX(REPEAT(SHA2(RAND(),256), 2000))
    FROM (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
          UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t1
    CROSS JOIN (SELECT 1 b UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t2;"

# 3. Start concurrent writes and trigger crash
for i in $(seq 1 20); do
    docker exec lz4-pxc-node1 mysql -uroot -proot pxb3568 -e "
        INSERT INTO t (data) SELECT UNHEX(REPEAT(SHA2(RAND(),256), 2000))
        FROM (SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t1;" &
done
docker exec lz4-pxc-node1 bash -c "
    mkdir -p /tmp/backup-test
    /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup \
        --backup --user=root --password=root \
        --compress=lz4 --compress-chunk-size=65534 \
        --target-dir=/tmp/backup-test --no-server-version-check 2>&1 | tail -5"
# Output: "terribly wrong... Fatal signal 6"

# 4. Verify zstd works
docker exec lz4-pxc-node1 bash -c "
    mkdir -p /tmp/backup-zstd
    /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup \
        --backup --user=root --password=root \
        --compress=zstd \
        --target-dir=/tmp/backup-zstd --no-server-version-check 2>&1 | tail -1"
# Output: "completed OK!"
```

## Workarounds

Until PXB-3568 is fixed:

| Workaround | Config Change | Risk |
|------------|--------------|------|
| **Switch to zstd** | `[xtrabackup] compress=zstd` | Low (zstd is default since PXB 8.0.34-29) |
| **Disable compression** | Remove `compress` line | None (slower SST) |

The `compress=zstd` workaround is recommended. It uses a completely
different code path (`ds_compress_zstd.cc`) that does not use `std::vector`.

## PKG-842 Is Not the Fix

[PKG-842](https://perconadev.atlassian.net/browse/PKG-842) (Done in
8.0.45) fixed the SST script's XtraBackup version parsing error.
This is a separate failure from the Signal 6 crash.

| Ticket | What It Fixes | Status |
|--------|--------------|--------|
| PKG-842 | SST script version check in Docker image | Done (8.0.45) |
| PXB-3568 | XtraBackup Signal 6 crash with LZ4 | **Open** (no fix) |

## Why EL9 and Not EL8

| Factor | EL8 | EL9 |
|--------|-----|-----|
| GCC | 8.5 | 11.5.0 (generates LTO bug) |
| `_GLIBCXX_ASSERTIONS` | Not default | **Default** (via redhat-rpm-config) |
| System LZ4 | 1.8.3 | 1.9.3 |

The crash requires all three conditions:
1. GCC 11 LTO code generation bug on aarch64
2. `_GLIBCXX_ASSERTIONS` enabled (bounds check in `operator[]`)
3. `std::vector` access pattern in `compress_write`

## Project Structure

```
pxb-3568-lz4-crash/
├── README.md                             This file
├── reproduce/
│   └── docker-compose.yml                PXC 8.0.45 cluster with LZ4 config
├── fixes/
│   ├── ds_compress_lz4_fixed.cc          Complete fixed source file
│   ├── test_fix_validation.cpp           Validates .data() bypasses assertion
│   ├── patched-source/                   Buffer patch attempt (insufficient)
│   └── lz4-upgrade/                      LZ4 1.10.0 upgrade (insufficient)
├── patch/
│   ├── ds_compress_lz4.patch             Unified diff patch
│   ├── PATCH-NOTES.md                    Detailed patch explanation
│   └── apply-fix.sh                      Applies ds_compress_lz4.cc fixes
├── analysis/
│   ├── root-cause.md                     Full root cause analysis
│   ├── pkg842-vs-pxb3568.md             PKG-842 is not the fix
│   └── lz4-boundary-math.md             64KB boundary arithmetic
├── test-validate.sh                      Automated before/after test
├── test_lz4_compress.c                   Standalone LZ4 test (library is fine)
└── evidence/                             Test outputs (gitignored)
```

## References

- JIRA: [PXB-3568](https://perconadev.atlassian.net/browse/PXB-3568) (Signal 6 with LZ4)
- JIRA: [PKG-842](https://perconadev.atlassian.net/browse/PKG-842) (Docker SST script fix)
- Forum: [Thread #40148](https://forums.percona.com/t/full-crash-percona-after-oom/40148)
- Source: [percona/percona-xtrabackup](https://github.com/percona/percona-xtrabackup) branch `8.0`

## License

This reproduction lab is provided for educational and diagnostic purposes.
Percona XtraBackup source code is licensed under GPL v2.
