/*
 * test_unit_jbig.c — Unit tests and error injection tests for rastertoricohjbig
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <cups/raster.h>

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

unsigned char* pad_to_page(unsigned char* src, unsigned src_stride,
    unsigned w, unsigned h, const cups_page_header2_t* hdr,
    unsigned* out_w, unsigned* out_h);

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
    /* Test unaligned buffer pointer to exercise unaligned count_dots branch */
    unsigned char unaligned[24];
    memset(unaligned, 0x00, sizeof(unaligned));
    unaligned[1] = 0xAA; /* 4 bits set */
    unaligned[2] = 0x55; /* 4 bits set */
    assert(count_dots(unaligned + 1, 16, 1) == 8);

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

    /* pad_to_page: macOS imageable-area bitmap lands at the margin offset */
    {
        cups_page_header2_t ph;
        memset(&ph, 0, sizeof(ph));
        ph.HWResolution[0] = ph.HWResolution[1] = 600;
        ph.PageSize[0] = 595; ph.PageSize[1] = 842;
        ph.ImagingBoundingBox[0] = 10; ph.ImagingBoundingBox[1] = 10;
        ph.ImagingBoundingBox[2] = 585; ph.ImagingBoundingBox[3] = 832;
        unsigned sw = 4792, sh = 6850, ss = (sw + 7) / 8, ow, oh;
        unsigned char* src = calloc(ss, sh);
        assert(src);
        src[0] = 0x80;                                   /* pixel (0,0) */
        src[(size_t)(sh - 1) * ss + (sw - 1) / 8] |= (unsigned char)(0x80 >> ((sw - 1) & 7)); /* last pixel */
        unsigned char* dst = pad_to_page(src, ss, sw, sh, &ph, &ow, &oh);
        assert(dst && dst != src && ow == 4958 && oh == 7017);
        unsigned ds = (ow + 7) / 8;
        assert(dst[83 * ds + 83 / 8] & (0x80 >> (83 & 7)));          /* 10pt = 83px */
        unsigned lx = 83 + sw - 1, ly = 83 + sh - 1;
        assert(dst[(size_t)ly * ds + lx / 8] & (0x80 >> (lx & 7)));
        free(dst);

        /* Full-page bitmap (Ghostscript) or no bounding box: unchanged */
        assert(pad_to_page(src, ss, 4958, 7017, &ph, &ow, &oh) == src && ow == 4958 && oh == 7017);
        ph.ImagingBoundingBox[2] = 0;
        assert(pad_to_page(src, ss, sw, sh, &ph, &ow, &oh) == src);
        ph.ImagingBoundingBox[2] = 585;
        ph.HWResolution[1] = 0;
        assert(pad_to_page(src, ss, sw, sh, &ph, &ow, &oh) == src);
        ph.HWResolution[1] = 600;
        ph.ImagingBoundingBox[0] = 300;                  /* box doesn't fit the page */
        assert(pad_to_page(src, ss, sw, sh, &ph, &ow, &oh) == src);
        ph.ImagingBoundingBox[0] = 10;

        test_fail_calloc = 1;                            /* allocation failure */
        assert(pad_to_page(src, ss, sw, sh, &ph, &ow, &oh) == NULL);
        test_fail_calloc = 0;
        free(src);
    }

    if (argc >= 4) {
        char* argv_img[] = { "rastertoricohjbig", "1", "user", "title", "1", "", argv[3] };
        test_fail_calloc = 1;                            /* padding allocation fails: abort */
        assert(driver_main_jbig(7, argv_img) == 1);
        test_fail_calloc = 0;
    }

    printf("  [OK] rastertoricohjbig unit & error injection tests passed\n");
    return 0;
}
