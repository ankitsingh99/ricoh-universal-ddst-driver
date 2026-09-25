/*
 * test_unit_jbig.c — Unit tests and error injection tests for rastertoricohjbig
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

void buf_cb(unsigned char* d, size_t n, void* arg);
void write_job_header(int copies);
unsigned long count_dots(const unsigned char* bmp, unsigned w, unsigned h);
void write_page(unsigned char* bmp, unsigned w, unsigned h,
    const char* paper, int first_page,
    unsigned dpi, int copies);
int driver_main_jbig(int argc, char* argv[]);

int main(int argc, char* argv[])
{
    printf("[*] Running rastertoricohjbig unit & error injection tests...\n");

    /* Test 1: Buffer expansion and callback */
    Buf b = { (unsigned char*)malloc(16), 0, 16 };
    assert(b.data != NULL);
    unsigned char test_data[64];
    memset(test_data, 0x33, sizeof(test_data));
    buf_cb(test_data, sizeof(test_data), &b);
    assert(b.size == 64);
    assert(b.cap >= 64);
    free(b.data);

    /* Test 1b: realloc failure in buf_cb */
    Buf b_fail = { (unsigned char*)malloc(16), 0, 16 };
    test_fail_realloc = 1;
    buf_cb(test_data, sizeof(test_data), &b_fail);
    test_fail_realloc = 0;
    free(b_fail.data);

    /* Test 2: count_dots */
    unsigned char all_zeros[16] = {0};
    unsigned char all_ones[16];
    memset(all_ones, 0xFF, sizeof(all_ones));
    assert(count_dots(all_zeros, 32, 4) == 0);
    assert(count_dots(all_ones, 32, 4) == 128);

    /* Test 3: write_job_header & fake null time */
    freopen("/dev/null", "w", stdout);
    test_fake_null_time = 1;
    write_job_header(3);
    test_fake_null_time = 0;
    write_job_header(1);

    /* Test 4: write_page */
    unsigned char dummy_bmp[128];
    memset(dummy_bmp, 0xAA, sizeof(dummy_bmp));
    write_page(dummy_bmp, 32, 32, "A4", 0, 600, 1);
    write_page(dummy_bmp, 32, 32, "A4", 1, 600, 1);

    /* Test 4b: write_page malloc failure */
    test_fail_malloc = 1;
    write_page(dummy_bmp, 32, 32, "A4", 1, 600, 1);
    test_fail_malloc = 0;

    /* Test 5: driver_main_jbig argv edge cases */
    freopen("/dev/null", "r", stdin);
    char* argv1[] = { "rastertoricohjbig", "1", "user", "title", "1", "options", "" };
    driver_main_jbig(7, argv1);

    char* argv2[] = { "rastertoricohjbig", "1", "user", "title", "-2" };
    driver_main_jbig(5, argv2);

    char* argv3[] = { "rastertoricohjbig" };
    driver_main_jbig(1, argv3);

    /* Test 6: driver_main_jbig memory failure handling */
    if (argc >= 2) {
        char* argv_mem1[] = { "rastertoricohjbig", "1", "user", "title", "1", "", argv[1] };
        test_fail_malloc = 1;
        driver_main_jbig(7, argv_mem1);
        test_fail_malloc = 0;
    }

    if (argc >= 3) {
        /* 8-bit/24-bit raster file passed as argv[2] for calloc failure test */
        char* argv_mem2[] = { "rastertoricohjbig", "1", "user", "title", "1", "", argv[2] };
        test_fail_calloc = 1;
        driver_main_jbig(7, argv_mem2);
        test_fail_calloc = 0;
    }

    printf("  [OK] rastertoricohjbig unit & error injection tests passed\n");
    return 0;
}
