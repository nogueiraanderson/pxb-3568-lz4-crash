# GCC 8 (EL8) vs GCC 11 (EL9): Why the Bug Surfaces on EL9

> **Note:** This document was written during the initial investigation phase
> when the root cause was hypothesized to be buffer undersizing. The actual
> root cause is a GCC 11 LTO false-positive `_GLIBCXX_ASSERTIONS` assertion
> in `std::vector::operator[]`. See `root-cause.md` for the final analysis.
> The compiler and hardening flag differences documented below remain accurate
> and relevant (especially `_GLIBCXX_ASSERTIONS` being EL9-default).

## Compiler Versions

| Platform | Default GCC | Toolset Override |
|----------|-------------|-----------------|
| EL8 | 8.5.x | gcc-toolset-10 (used in some builds) |
| EL9 | 11.x | **None** (bare system GCC) |

The PXB Jenkins build pipeline has no toolset override for EL9 builds.
EL9 uses the system GCC 11 directly.

## RHEL9 Default Hardening Flags

EL9's `redhat-rpm-config` injects these flags into RPM builds:

| Flag | EL8 | EL9 | Effect |
|------|-----|-----|--------|
| `-fstack-clash-protection` | No | **Yes** | Probes stack pages on allocation; freed vector memory overwritten faster |
| `-fcf-protection` | No | **Yes** | Indirect call validation (CET) |
| `-D_GLIBCXX_ASSERTIONS` | No | **Yes** | Runtime bounds checking on `std::vector::operator[]` |
| `-D_FORTIFY_SOURCE=2` | Yes | Yes | Buffer overflow detection |

## GCC 11 Optimization Differences

### Improved IPA Value Range Propagation

GCC 11 has significantly enhanced Inter-Procedural Analysis (IPA).
It can determine that `comp_file->comp_buf_size` is always 0 (since
it is never written after initialization) and potentially:

1. Prove the realloc guard is always true (dead code elimination
   of the else branch)
2. Inline the realloc path differently
3. Change register allocation around the compression loop

Under GCC 8, the optimizer does not trace the value through the
struct member, so it generates more conservative code.

### `-fipa-icf` Enhancements

GCC 11's Identical Code Folding is more aggressive. Functions with
similar structure (like the compression thread lambdas) may be
folded, changing memory layout and timing.

## Combined Effect

> **Note:** This section has been updated from the initial hypothesis.
> See `root-cause.md` for the definitive analysis.

The crash requires all of these conditions simultaneously:

1. GCC 11+ LTO on aarch64 generates incorrect element stride (36920
   instead of 40) in the `compress_write()` vector traversal loop
2. `_GLIBCXX_ASSERTIONS` is enabled (EL9 default), adding bounds
   checks to `std::vector::operator[]`
3. Concurrent database writes produce enough redo log data for
   n_chunks > 1, triggering the wrong stride on iteration >= 1

On EL8, GCC 8 does not have the LTO code generation bug, and
`_GLIBCXX_ASSERTIONS` is not enabled by default.

## ASAN/UBSAN Verification

XtraBackup supports sanitizer builds:

```bash
cmake -DWITH_ASAN=ON -DWITH_UBSAN=ON -DWITH_TSAN=ON ...
```

Running LZ4-compressed backups under ASAN on EL9 would show:

- The LTO stride corruption as a heap-buffer-overflow (writing past
  the vector's allocated storage at iteration >= 1)
- Any concurrency issues via TSAN (if `compress_write` is called
  concurrently on the same file handle)

## Sources

- [GCC 11 Release Changes](https://gcc.gnu.org/gcc-11/changes.html)
- [RHEL9 Compiler Flags](https://src.fedoraproject.org/rpms/redhat-rpm-config/blob/rawhide/f/buildflags.md)
- [Detecting memory management bugs with GCC 11](https://developers.redhat.com/blog/2021/04/30/detecting-memory-management-bugs-with-gcc-11-part-1-understanding-dynamic-allocation)
