# PXB-3568: XtraBackup Signal 6 Crash with LZ4 Compression

**[PXB-3568](https://perconadev.atlassian.net/browse/PXB-3568)** (Urgent, Open, Unassigned).
XtraBackup crashes with Signal 6 during backup when using `compress=lz4` on
EL9-based PXC Docker images. Affects PXC 8.0.42 and 8.0.45 (both ship
XtraBackup 8.0.35-35). This causes SST failures in PXC clusters.

This repo reproduces the crash and validates workarounds.

## Validated Results

Tested on PXC 8.0.45 Docker image (aarch64, OracleLinux 9, LZ4 1.9.3):

| Test | Command | Result |
|------|---------|--------|
| Stock + LZ4 | `xtrabackup --backup --compress=lz4 --compress-chunk-size=65534` | **CRASH (Signal 6)** |
| LZ4 1.10.0 + LZ4 | Same command, system liblz4 upgraded to 1.10.0 | **CRASH (Signal 6)** |
| Patched source + LZ4 | Same command, ds_compress_lz4.cc buffer fixes applied | **CRASH (Signal 6)** |
| Stock + zstd | `xtrabackup --backup --compress=zstd` | **SUCCESS** |
| Stock + no compression | `xtrabackup --backup` (no compress flag) | **SUCCESS** |

### Key Finding

The crash is NOT in the LZ4 library or `ds_compress_lz4.cc` buffer sizing.
The stack trace shows the crash in **`Redo_Log_Writer::write_buffer`**, which
is the redo log compression path, distinct from the data file compression path:

```
xtrabackup(Redo_Log_Writer::write_buffer+0x164)
xtrabackup() [0x7fa284]  // compress datasink
xtrabackup() [0x7f1a60]  // LZ4_compress_default returns 0 -> abort
/lib64/libc.so.6(abort+0xe8)
```

Neither upgrading LZ4 to 1.10.0 nor patching `ds_compress_lz4.cc` buffer
tracking fixes the crash. The real fix requires changes to how xtrabackup
handles LZ4 compression in the redo log write path.

## Reproduce

**Prerequisites**: Docker, Docker Compose, ~2GB RAM

```bash
# 1. Start a PXC 8.0.45 node
docker compose -f reproduce/docker-compose.yml up -d pxc-node1

# 2. Wait ~25s for bootstrap, load data
docker exec lz4-pxc-node1 mysql -uroot -proot -e "CREATE DATABASE pxb3568"
docker exec lz4-pxc-node1 mysql -uroot -proot pxb3568 -e "
    CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY, data BLOB) ENGINE=InnoDB;
    INSERT INTO t (data) SELECT UNHEX(REPEAT(SHA2(RAND(),256), 2000))
    FROM (SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t1;"

# 3. Trigger crash
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
different code path (`ds_compress_zstd.cc`) that does not have the bug.

**What does NOT fix it:**
- Upgrading system liblz4 to 1.10.0 (same crash)
- Patching `ds_compress_lz4.cc` buffer tracking (same crash)

## Why EL9 and Not EL8

| Factor | EL8 | EL9 |
|--------|-----|-----|
| System LZ4 | 1.8.3 | 1.9.3 |
| GCC | 8.5 | 11 (stricter optimization) |
| glibc | 2.28 | 2.34 (stricter heap corruption detection) |

XtraBackup dynamically links system `liblz4.so` in PXC Docker images.

## PKG-842 Is Not the Fix

[PKG-842](https://perconadev.atlassian.net/browse/PKG-842) (Done in
8.0.45) fixed the SST script's XtraBackup version parsing error.
Additionally, this version parsing bug causes the SST script to select
**PXB 2.4** instead of PXB 8.0 for the joiner's decompress step (because
the donor version string is empty, defaults to "0.0.0", which is < 8.0.0).
This is a separate failure from the Signal 6 crash.

| Ticket | What It Fixes | Status |
|--------|--------------|--------|
| PKG-842 | SST script version check in Docker image | Done (8.0.45) |
| PXB-3568 | XtraBackup Signal 6 crash with LZ4 | **Open** (no fix) |

## Source Code Notes

Two real (but non-crash-causing) bugs exist in `ds_compress_lz4.cc`:

1. **`comp_buf_size` never updated** (line ~136): After `my_realloc`,
   `comp_file->comp_buf_size` is not set to the new size, causing
   unnecessary reallocation on every call.
2. **1204 typo** (line ~192): `1 * 1204 * 1024` should be `1 * 1024 * 1024`.

These bugs exist in the current `8.0` branch HEAD but do NOT cause the
Signal 6 crash. The `thd.to_size` assignment is already correct
(`= comp_size`, not `= ctrl->chunk_size` as initially hypothesized).

## Project Structure

```
pxb-3568-lz4-crash/
├── README.md                             This file
├── reproduce/
│   └── docker-compose.yml                PXC 8.0.45 cluster with LZ4 config
├── fixes/
│   ├── patched-source/                   Source patch (does NOT fix crash)
│   │   └── Dockerfile                    Multi-stage build from percona-xtrabackup 8.0
│   └── lz4-upgrade/                      LZ4 1.10.0 upgrade (does NOT fix crash)
│       └── Dockerfile
├── patch/
│   ├── apply-fix.sh                      Applies ds_compress_lz4.cc fixes
│   └── PATCH-NOTES.md                    Patch explanation
├── analysis/
│   ├── root-cause.md                     Full root cause analysis
│   ├── pkg842-vs-pxb3568.md             PKG-842 is not the fix
│   └── lz4-boundary-math.md             64KB boundary arithmetic
├── test-validate.sh                      Automated before/after test
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
