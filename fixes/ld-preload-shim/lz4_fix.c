/*
 * PXB-3568 workaround: LD_PRELOAD shim for LZ4_compress_default
 *
 * The bug in ds_compress_lz4.cc:
 *
 *   const size_t comp_buf_size = LZ4_compressBound(ctrl->chunk_size);
 *   if (comp_file->comp_buf_size < comp_buf_size) {
 *       comp_file->comp_buf = my_realloc(..., comp_buf_size, ...);
 *       // BUG: comp_file->comp_buf_size is NEVER updated
 *   }
 *
 * comp_file->comp_buf_size is initialized to 0 and never written.
 * The realloc fires every call, but the buffer is correctly sized.
 * However, the output buffer passed to LZ4_compress_default uses
 * to_size = ctrl->chunk_size (not the larger LZ4_compressBound value).
 *
 * When input is near 64KB (the default compress-chunk-size), the
 * compressed output can exceed chunk_size by up to 16 bytes (LZ4
 * frame header). LZ4_compress_default returns 0, and xtrabackup
 * calls abort() via Signal 6.
 *
 * This shim intercepts LZ4_compress_default. On failure, it retries
 * with a correctly sized temporary buffer and copies back.
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
