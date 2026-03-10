/*
 * PXB-3568 workaround attempt: LD_PRELOAD shim for LZ4_compress_default
 *
 * NOTE: This approach was INSUFFICIENT. The actual root cause is GCC 11/12
 * LTO generating incorrect stride (36920 instead of 40) for std::vector
 * element traversal in compress_write(). The crash is a false-positive
 * _GLIBCXX_ASSERTIONS bounds check, not a buffer sizing issue.
 * See analysis/root-cause.md for the definitive analysis.
 *
 * The shim below was written during the initial investigation phase when
 * the hypothesis was buffer undersizing. It addresses a real secondary bug
 * (comp_buf_size never updated after my_realloc) but does not prevent
 * the LTO stride corruption that causes Signal 6.
 *
 * Build: gcc -shared -fPIC -o lz4_fix.so lz4_fix.c -ldl
 * Use:   LD_PRELOAD=/path/to/lz4_fix.so xtrabackup --compress=lz4 ...
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

typedef int (*lz4_compress_fn)(const char*, char*, int, int);

int LZ4_compress_default(const char* src, char* dst,
                         int srcSize, int dstCapacity)
{
    static lz4_compress_fn real_fn = NULL;
    if (!real_fn) {
        real_fn = (lz4_compress_fn)dlsym(RTLD_NEXT, "LZ4_compress_default");
    }

    /* Try the real call first */
    int ret = real_fn(src, dst, srcSize, dstCapacity);
    if (ret > 0) return ret;

    /* If it failed and the buffer looks undersized, retry with a bigger one */
    if (dstCapacity <= srcSize && srcSize > 0) {
        int safe_size = srcSize + (srcSize / 255) + 16 + 64;
        char* tmp = (char*)malloc(safe_size);
        if (!tmp) return 0;

        ret = real_fn(src, tmp, srcSize, safe_size);
        if (ret > 0 && ret <= dstCapacity) {
            memcpy(dst, tmp, ret);
        } else {
            /* Compressed output larger than original buffer */
            ret = 0;
        }
        free(tmp);
    }
    return ret;
}
