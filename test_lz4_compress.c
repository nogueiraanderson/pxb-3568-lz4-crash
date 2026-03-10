/*
 * Test LZ4 compression exactly as ds_compress_lz4.cc does it.
 * Reproduces the compress_write() logic to find the crash condition.
 *
 * Compile: gcc -O2 -o test_lz4 test_lz4_compress.c -llz4
 * Run:     ./test_lz4
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lz4.h>

int test_compress(size_t chunk_size, size_t input_len, int use_random) {
    const size_t comp_size = LZ4_compressBound(chunk_size);
    const size_t n_chunks = (input_len / chunk_size * chunk_size == input_len)
        ? (input_len / chunk_size)
        : (input_len / chunk_size + 1);
    const size_t comp_buf_size = comp_size * n_chunks;

    printf("  chunk_size=%zu input_len=%zu comp_size=%zu n_chunks=%zu comp_buf=%zu\n",
           chunk_size, input_len, comp_size, n_chunks, comp_buf_size);

    /* Allocate input buffer */
    char *input = malloc(input_len);
    if (!input) { printf("  FAIL: malloc input\n"); return 1; }

    /* Fill with data */
    if (use_random) {
        /* Random (incompressible) data */
        for (size_t i = 0; i < input_len; i++)
            input[i] = (char)(rand() & 0xff);
    } else {
        /* Compressible data (repeated pattern) */
        memset(input, 'A', input_len);
        for (size_t i = 0; i < input_len; i += 100)
            input[i] = (char)('A' + (i % 26));
    }

    /* Allocate output buffer exactly like compress_write */
    char *comp_buf = malloc(comp_buf_size);
    if (!comp_buf) { printf("  FAIL: malloc comp_buf\n"); free(input); return 1; }

    /* Compress each chunk (simulating the thread pool tasks) */
    int any_failure = 0;
    for (size_t i = 0; i < n_chunks; i++) {
        size_t from_len = input_len - i * chunk_size;
        if (from_len > chunk_size) from_len = chunk_size;

        const char *from = input + chunk_size * i;
        char *to = comp_buf + comp_size * i;
        size_t to_size = comp_size;

        int to_len = LZ4_compress_default(from, to, (int)from_len, (int)to_size);

        if (to_len == 0) {
            printf("  CHUNK %zu: LZ4_compress_default RETURNED 0! from_len=%zu to_size=%zu\n",
                   i, from_len, to_size);
            any_failure = 1;
        } else if (to_len > 0 && (size_t)to_len < chunk_size) {
            /* Compressed successfully */
            if (i < 3 || i == n_chunks - 1)
                printf("  chunk %zu: compressed %zu -> %d (%.1f%%)\n",
                       i, from_len, to_len, 100.0 * to_len / from_len);
        } else {
            /* Uncompressible, would write raw */
            if (i < 3 || i == n_chunks - 1)
                printf("  chunk %zu: uncompressible %zu -> %d (raw)\n",
                       i, from_len, to_len);
        }
    }

    free(input);
    free(comp_buf);
    return any_failure;
}

int main() {
    printf("LZ4 version: %s (number: %d)\n", LZ4_versionString(), LZ4_versionNumber());
    printf("LZ4_compressBound(65534) = %d\n", LZ4_compressBound(65534));
    printf("LZ4_compressBound(65535) = %d\n", LZ4_compressBound(65535));
    printf("LZ4_compressBound(64*1024) = %d\n", LZ4_compressBound(64*1024));
    printf("\n");

    /* Test various input sizes with chunk_size=65534 */
    size_t chunk = 65534;
    int tests[][2] = {
        {512, 0},       /* small, redo log block */
        {512, 1},       /* small random */
        {65534, 0},     /* exactly one chunk */
        {65534, 1},     /* exactly one chunk, random */
        {65535, 0},     /* one byte over chunk (2 chunks) */
        {65535, 1},     /* one byte over, random */
        {131068, 0},    /* exactly 2 chunks */
        {131068, 1},    /* exactly 2 chunks, random */
        {524288, 0},    /* 512KB, compressible */
        {524288, 1},    /* 512KB, random */
        {1048576, 0},   /* 1MB */
        {1048576, 1},   /* 1MB random */
        {8388608, 0},   /* 8MB (typical redo log buffer) */
        {8388608, 1},   /* 8MB random */
    };

    int n = sizeof(tests) / sizeof(tests[0]);
    int failures = 0;
    for (int t = 0; t < n; t++) {
        size_t input_len = tests[t][0];
        int use_random = tests[t][1];
        printf("Test %d: len=%zu %s\n", t+1, input_len, use_random ? "(random)" : "(compressible)");
        if (test_compress(chunk, input_len, use_random)) {
            failures++;
            printf("  >>> FAILURE detected <<<\n");
        }
        printf("\n");
    }

    printf("=== %d/%d tests had LZ4 failures ===\n", failures, n);

    /* Now test: what happens with extremely small input but large chunk_size? */
    printf("\n--- Edge case: input < chunk_size ---\n");
    for (size_t len = 1; len <= 512; len *= 2) {
        printf("Test: len=%zu chunk=%zu\n", len, chunk);
        test_compress(chunk, len, 1);
    }

    return failures > 0 ? 1 : 0;
}
