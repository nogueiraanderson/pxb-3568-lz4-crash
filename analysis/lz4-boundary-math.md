# LZ4 64KB Boundary Arithmetic

## The Numbers

XtraBackup's default `compress-chunk-size` is 64KB (65536 bytes).
Setting it to 65534 (just under 64KB) maximizes the reproduction
probability.

### LZ4_compressBound Values

```
LZ4_compressBound(65536) = 65552   (+16 bytes)
LZ4_compressBound(65534) = 65550   (+16 bytes)
LZ4_compressBound(65535) = 65551   (+16 bytes)
```

The extra 16 bytes account for the LZ4 block header and termination.

### What XtraBackup Allocates

Due to the `comp_buf_size` bug, each compression thread gets:

```
to_size = ctrl->chunk_size = 65534   (or 65536)
```

Instead of:

```
to_size = LZ4_compressBound(chunk_size) = 65550   (or 65552)
```

Deficit: **16 bytes**.

## When Does LZ4 Need More Than chunk_size?

`LZ4_compress_default` may produce output larger than input when:

1. Data is incompressible (random, encrypted, already compressed)
2. Input is near a block size boundary
3. LZ4 needs space for block headers and checksums

For a 65534-byte input of random data:

```
LZ4_compress_default output = ~65534 + overhead
                            = ~65540-65548 bytes
Buffer available            = 65534 bytes
Result                      = 0 (failure)
```

## LZ4 Issue #1374

[LZ4 issue #1374](https://github.com/lz4/lz4/issues/1374) affects
LZ4 1.9.x. `LZ4F_compressFrameBound()` returns an undersized value
for inputs of exactly 65533, 65534, or 65535 bytes with B4 (64KB)
block size.

This was fixed in LZ4 1.10.0 by adjusting the frame bound calculation.

| LZ4 Version | Platform | `LZ4F_compressFrameBound(65534)` | Bug? |
|-------------|----------|--------------------------------|------|
| 1.8.3 | EL8 | N/A (older API) | No |
| 1.9.3 | EL9 | Undersized | **Yes** |
| 1.10.0 | Fix A image | Correct | No |

## Dynamic Linking

XtraBackup in PXC Docker images dynamically links `liblz4.so`:

```
$ docker exec pxc-node1 ldd /usr/bin/xtrabackup | grep lz4
    liblz4.so.1 => /usr/lib64/liblz4.so.1 (0x...)
```

This means:
- The system LZ4 version directly affects XtraBackup behavior
- Replacing `/usr/lib64/liblz4.so.1` with LZ4 1.10.0 fixes the crash
- LD_PRELOAD interposition works because the symbol is dynamically resolved

Note: The XtraBackup CMake configuration defaults to `WITH_LZ4=bundled`
(static linking), but the RPM/Docker package builds override this to
use the system library. The empirical `ldd` evidence takes precedence
over the CMake default.

## Reproduction Probability

With `compress-chunk-size=65534` and varied row sizes (mix of
compressible text and random binary), the crash should reproduce
within 1-3 SST attempts on EL9. The test data generator produces
rows between 1KB and 12KB with a mix of `REPEAT()` (compressible)
and `RANDOM_BYTES()` (incompressible) to ensure some compression
chunks hit the boundary.
