# PKG-842 vs PXB-3568: Two Different Bugs

These two JIRA tickets are frequently confused because they both
involve LZ4 compression in PXC Docker images. They are completely
unrelated code paths.

## At a Glance

| | PKG-842 | PXB-3568 |
|---|---------|----------|
| **What** | SST script version parsing | XtraBackup LZ4 buffer sizing |
| **Status** | Done (8.0.45) | **Open** (no fix version) |
| **Priority** | Normal | **Urgent** |
| **Component** | `wsrep_sst_xtrabackup-v2` (bash) | `ds_compress_lz4.cc` (C++) |
| **Error** | `Cannot determine the xtrabackup 2.x version` | Signal 6 / SIGABRT |
| **When** | SST startup (before transfer) | SST data transfer (during compression) |
| **Fix** | Sed patch on version regex in Dockerfile | Patch `ds_compress_lz4.cc` |

## PKG-842: Docker Image SST Script Fix (Done)

The PXC 8.0.42 Docker image's SST script (`wsrep_sst_xtrabackup-v2`)
could not parse the xtrabackup version string. The version regex did
not match the format produced by newer XtraBackup versions.

The fix was a `sed` patch in the Dockerfile that corrects the version
detection regex. This allows SST to proceed past the version check.

**This fix has no effect on the LZ4 crash.** The crash occurs later,
during the actual data transfer phase, in XtraBackup's C++ compression
code.

## PXB-3568: XtraBackup Signal 6 with LZ4 (Open)

The actual crash. On EL9/aarch64, GCC 11 LTO generates incorrect code for
`std::vector::operator[]` bounds checking when `_GLIBCXX_ASSERTIONS` is
enabled (EL9 default). The bounds-check assertion fires on valid indices,
causing `abort()` via Signal 6. The fix is to use `.data()` raw pointer
access to bypass the corrupted assertion. See `analysis/root-cause.md`
for the full root cause analysis.

Additionally, the code has a secondary bug where `comp_buf_size` is
never updated after `my_realloc`, causing unnecessary reallocations.

**PXB-3568 is still Open and Unassigned.** Upgrading to PXC 8.0.45
does not fix this crash. Both 8.0.42 and 8.0.45 ship XtraBackup
8.0.35-35.

## JIRA Relationship

In JIRA, PXB-3568 "Causes" PKG-842. This is because the original
reporter encountered both issues: the SST script error first, then
the LZ4 crash after working around the script error. Fixing PKG-842
only resolved the first issue.

## Timeline of Confusion

1. User reports LZ4 crash on PXC 8.0.42 (forum post #23)
2. Staff responds that 8.0.45 includes the fix from PKG-842 (post #25)
3. User upgrades to 8.0.45, LZ4 crash persists (post #30)
4. Clarification: PKG-842 was the wrong fix for the reported symptom

## Workaround for PXB-3568

Since PXB-3568 has no fix version, the recommended workaround is:

```ini
[xtrabackup]
compress=zstd
```

This uses the zstd compression code path (`ds_compress_zstd.cc`),
which does not have the buffer sizing bug.
