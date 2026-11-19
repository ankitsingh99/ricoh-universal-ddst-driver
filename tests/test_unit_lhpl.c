/*
 * test_unit_lhpl.c — Unit tests and error injection tests for rastertoricohlhpl
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

typedef struct {
    unsigned char* data;
    size_t         size;
    size_t         cap;
} Buf;

extern int test_fail_malloc;
extern int test_fail_calloc;
extern int test_fail_realloc;
extern int test_fake_null_time;

void jbig_buf_cb(unsigned char* d, size_t n, void* arg);
void lhpl_xor_checksum(unsigned char* buf, size_t len);
void write_lhpl_sj(int copies);
void write_lhpl_sp(unsigned width, unsigned height, unsigned resolution,
                   const unsigned char* jbig_data, size_t jbig_len);
void write_lhpl_ep(void);
void write_job_header(int copies, unsigned dpi, const char* user, const char* title);
int driver_main_lhpl(int argc, char* argv[]);

int main(int argc, char* argv[])
{
    printf("[*] Running rastertoricohlhpl unit & error injection tests...\n");

    /* Test 1: Buffer expansion and callback */
    Buf b = { (unsigned char*)malloc(16), 0, 16 };
    assert(b.data != NULL);
    unsigned char test_data[64];
    memset(test_data, 0x55, sizeof(test_data));
    jbig_buf_cb(test_data, sizeof(test_data), &b);
    assert(b.size == 64);
    assert(b.cap >= 64);
    free(b.data);

    /* Test 1b: realloc failure in jbig_buf_cb */
    Buf b_fail = { (unsigned char*)malloc(16), 0, 16 };
    test_fail_realloc = 1;
    jbig_buf_cb(test_data, sizeof(test_data), &b_fail);
    test_fail_realloc = 0;
    free(b_fail.data);

    /* Test 2: XOR checksum calculation */
    unsigned char test_chk[8] = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x00 };
    lhpl_xor_checksum(test_chk, 8);
    assert(test_chk[7] == (0x01 ^ 0x02 ^ 0x04 ^ 0x08 ^ 0x10 ^ 0x20 ^ 0x40));

    /* Test 3: write_lhpl_sj / sp / ep output generation */
    write_lhpl_sj(1);
    write_lhpl_sp(5120, 6820, 600, test_data, sizeof(test_data));
    write_lhpl_ep();

    /* Test 4: write_job_header fallback with null time */
    test_fake_null_time = 1;
    write_job_header(2, 600, NULL, NULL);
    test_fake_null_time = 0;
    write_job_header(1, 1200, "user", "title");

    /* Test 5: Error injection on driver_main_lhpl */
    if (argc >= 3) {
        char* mono_ras = argv[1];
        char* gray_ras = argv[2];

        /* Calloc failure on page buffer */
        test_fail_calloc = 1;
        char* argv_calloc_fail[] = { "rastertoricohlhpl", "1", "user", "Title", "1", "", mono_ras };
        int rc = driver_main_lhpl(7, argv_calloc_fail);
        assert(rc == 1);
        test_fail_calloc = 0;

        /* Malloc failure on row buffer */
        test_fail_malloc = 1;
        char* argv_malloc_fail[] = { "rastertoricohlhpl", "1", "user", "Title", "1", "", mono_ras };
        rc = driver_main_lhpl(7, argv_malloc_fail);
        assert(rc == 1);
        test_fail_malloc = 0;

        /* Calloc failure on JBIG history lines */
        /* To test calloc failure on history lines, we let the first calloc (page_buf) succeed */
        test_fail_calloc = 2; // will fail on 2nd calloc
        char* argv_jbig_calloc_fail[] = { "rastertoricohlhpl", "1", "user", "Title", "1", "", mono_ras };
        rc = driver_main_lhpl(7, argv_jbig_calloc_fail);
        assert(rc == 1);
        test_fail_calloc = 0;

        /* Test with gray_ras */
        char* argv_gray[] = { "rastertoricohlhpl", "1", "user", "Title", "1", "", gray_ras };
        rc = driver_main_lhpl(7, argv_gray);
        assert(rc == 0);
    }

    printf("[PASS] All rastertoricohlhpl unit & error injection tests succeeded.\n");
    return 0;
}
