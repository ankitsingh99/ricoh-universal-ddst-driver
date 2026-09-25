/*
 * rastertoricohjbig.c — CUPS raster filter for Ricoh SP 200 series printers
 *
 * Converts CUPS raster input to the Ricoh SP 200 PJL + JBIG1 bi-level protocol.
 *
 * Original reverse engineering & implementation by Aryan Kushwaha (funinkina).
 * Maintained and updated by Ankit Kumar Singh (ankitsingh99) and contributors.
 *
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <jbig.h>
#include <cups/cups.h>
#include <cups/raster.h>

#ifndef STATIC
#define STATIC static
#endif

#ifdef TESTING
extern int test_fail_malloc;
extern int test_fail_calloc;
extern int test_fail_realloc;
extern int test_fake_null_time;
void* test_mock_malloc(size_t sz);
void* test_mock_calloc(size_t n, size_t sz);
void* test_mock_realloc(void* ptr, size_t sz);
struct tm* test_mock_localtime(const time_t* timep);

#define MALLOC test_mock_malloc
#define CALLOC test_mock_calloc
#define REALLOC test_mock_realloc
#define LOCALTIME test_mock_localtime
#else
#define MALLOC malloc
#define CALLOC calloc
#define REALLOC realloc
#define LOCALTIME localtime
#endif

/* Growable output buffer used as the jbg_enc_out callback target */
typedef struct {
    unsigned char* data;
    size_t         size;
    size_t         cap;
} Buf;

STATIC void buf_cb(unsigned char* d, size_t n, void* arg)
{
    Buf* b = (Buf*)arg;
    if (b->size + n > b->cap) {
        size_t new_cap = (b->size + n) * 2;
        unsigned char* new_data = (unsigned char*)REALLOC(b->data, new_cap);
        if (!new_data) {
            fprintf(stderr, "ERROR: rastertoricohjbig: Out of memory expanding buffer\n");
            return;
        }
        b->data = new_data;
        b->cap = new_cap;
    }
    memcpy(b->data + b->size, d, n);
    b->size += n;
}

STATIC void write_job_header(int copies)
{
    time_t     now = time(NULL);
    struct tm* t = LOCALTIME(&now);

    fputs("\x1b%-12345X@PJL\r\n", stdout);

    if (t) {
        fprintf(stdout,
            "@PJL SET TIMESTAMP=%04d/%02d/%02d %02d:%02d:%02d\r\n",
            t->tm_year + 1900, t->tm_mon + 1, t->tm_mday,
            t->tm_hour, t->tm_min, t->tm_sec);
    } else {
        fprintf(stdout, "@PJL SET TIMESTAMP=2026/01/01 00:00:00\r\n");
    }

    fprintf(stdout,
        "@PJL SET FILENAME=printjob\r\n"
        "@PJL SET COMPRESS=JBIG\r\n"
        "@PJL SET USERNAME=lp\r\n"
        "@PJL SET COVER=OFF\r\n"
        "@PJL SET HOLD=OFF\r\n"
        "@PJL SET PAGESTATUS=START\r\n"
        "@PJL SET COPIES=%d\r\n"
        "@PJL SET MEDIASOURCE=TRAY1\r\n"
        "@PJL SET MEDIATYPE=PLAINRECYCLE\r\n",
        copies);
}

/* Count black pixels across a 1-bit packed bitmap (for DOTCOUNT). */
STATIC unsigned long count_dots(const unsigned char* bmp, unsigned w, unsigned h)
{
    unsigned stride = (w + 7) / 8;
    unsigned long n = 0;
    for (unsigned y = 0; y < h; y++) {
        for (unsigned x = 0; x < stride; x++) {
            n += (unsigned long)__builtin_popcount(bmp[y * stride + x]);
        }
    }
    return n;
}

/*
 * Encode and send one page. Protocol (from USB capture of Windows driver):
 *
 *   For page 1:  job header already emitted PAGESTATUS=START + COPIES + MEDIA.
 *   For page N>1: we emit PAGESTATUS=END (closes page N-1) then the full
 *                 per-page setup block before this page's IMAGELEN.
 *
 *   After every page's JBIG data: DOTCOUNT + PAGESTATUS=END.
 *   After the final page: caller emits EOJ + UEL.
 *
 *   Without the per-page PAGESTATUS=END the firmware treats every subsequent
 *   IMAGELEN as another chunk of the same page and never ejects it.
 */
STATIC void write_page(unsigned char* bmp, unsigned w, unsigned h,
    const char* paper, int first_page,
    unsigned dpi, int copies)
{
    Buf buf = { (unsigned char*)MALLOC(1 << 17), 0, 1 << 17 };
    if (!buf.data) {
        fprintf(stderr, "ERROR: rastertoricohjbig: Out of memory allocating page buffer\n");
        return;
    }

    struct jbg_enc_state enc;
    unsigned char* planes[1] = { bmp };

    /* Pages 2+ need their own PAGESTATUS=START + media header.
     * Page 1 inherits these from the job header. */
    if (!first_page) {
        fprintf(stdout,
            "@PJL SET PAGESTATUS=START\r\n"
            "@PJL SET COPIES=%d\r\n"
            "@PJL SET MEDIASOURCE=TRAY1\r\n"
            "@PJL SET MEDIATYPE=PLAINRECYCLE\r\n",
            copies);
    }

    /* PAPERWIDTH and PAPERLENGTH are both required and are repeated for every
     * page (not just the first). Omitting PAPERLENGTH causes the printer to
     * initialise but never feed the page. */
    fprintf(stdout,
        "@PJL SET PAPER=%s\r\n"
        "@PJL SET PAPERWIDTH=%u\r\n"
        "@PJL SET PAPERLENGTH=%u\r\n"
        "@PJL SET RESOLUTION=%u\r\n",
        paper, w, h, dpi);

    jbg_enc_init(&enc, w, h, 1, planes, buf_cb, &buf);
    /* jbigkit stores the order and options arguments directly into BIE
     * bytes 18 and 19. Both must match the Windows driver's output exactly:
     * byte 18 = 0x03, byte 19 = 0x48. Sending byte 19 = 0x08 causes the
     * printer to warm up but refuse to pull the page. */
    jbg_enc_options(&enc, 0x03, 0x48, 128, 0, 0);
    jbg_enc_out(&enc);
    jbg_enc_free(&enc);

    fprintf(stdout, "@PJL SET IMAGELEN=%zu\r\n", buf.size);
    fwrite(buf.data, 1, buf.size, stdout);

    /* DOTCOUNT + PAGESTATUS=END must follow every page's JBIG data.
     * This triggers paper ejection. Without it the printer accumulates all
     * subsequent IMAGELEN blocks as extra chunks of the same page. */
    unsigned long dots = count_dots(bmp, w, h);
    fprintf(stdout,
        "@PJL SET DOTCOUNT=%lu\r\n"
        "@PJL SET PAGESTATUS=END\r\n",
        dots);
    fflush(stdout);

    free(buf.data);
}

int main(int argc, char* argv[])
{
    int copies = 1;
    int fd = 0;

    /*
     * CUPS filter command line arguments:
     * argv[1] = Job ID
     * argv[2] = User
     * argv[3] = Title
     * argv[4] = Number of copies
     * argv[5] = Options
     * argv[6] = Optional filename (if omitted, read from stdin fd=0)
     */
    if (argc >= 5) {
        copies = atoi(argv[4]);
        if (copies < 1) copies = 1;
    }

    if (argc >= 7 && argv[6] && argv[6][0] != '\0') {
        fd = open(argv[6], O_RDONLY);
        if (fd < 0) {
            fprintf(stderr, "ERROR: rastertoricohjbig: Unable to open print file '%s'\n", argv[6]);
            return 1;
        }
    }

    cups_raster_t* ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
    if (!ras) {
        fprintf(stderr, "ERROR: rastertoricohjbig: Unable to open raster stream\n");
        if (fd != 0) close(fd);
        return 1;
    }

    cups_page_header2_t hdr;
    int                 page = 0;

    write_job_header(copies);

    while (cupsRasterReadHeader2(ras, &hdr)) {
        unsigned w = hdr.cupsWidth;
        unsigned h = hdr.cupsHeight;
        unsigned bpp = hdr.cupsBitsPerPixel;
        unsigned cspace = hdr.cupsColorSpace;
        unsigned dpi = hdr.HWResolution[0];
        unsigned stride = hdr.cupsBytesPerLine;

        const char* paper = (hdr.PageSize[0] > 610) ? "LETTER" : "A4";

        unsigned char* bmp = (unsigned char*)MALLOC(stride * h);
        if (!bmp) {
            fprintf(stderr, "ERROR: rastertoricohjbig: Out of memory allocating raster bitmap\n");
            cupsRasterClose(ras);
            if (fd != 0) close(fd);
            return 1;
        }

        for (unsigned y = 0; y < h; y++) {
            cupsRasterReadPixels(ras, bmp + y * stride, stride);
        }

        unsigned char* bmp1 = bmp;
        if (bpp > 1) {
            unsigned stride1 = (w + 7) / 8;
            bmp1 = (unsigned char*)CALLOC(stride1, h);
            if (!bmp1) {
                fprintf(stderr, "ERROR: rastertoricohjbig: Out of memory allocating 1-bit conversion buffer\n");
                free(bmp);
                cupsRasterClose(ras);
                if (fd != 0) close(fd);
                return 1;
            }
            for (unsigned y = 0; y < h; y++) {
                for (unsigned x = 0; x < w; x++) {
                    unsigned char px;
                    if (bpp == 8) {
                        px = bmp[y * stride + x];
                    } else {
                        px = (unsigned char)(((unsigned)bmp[y * stride + x * 3] +
                            bmp[y * stride + x * 3 + 1] +
                            bmp[y * stride + x * 3 + 2]) / 3);
                    }
                    int black = (cspace == 3) ? (px > 128) : (px < 128);
                    if (black) {
                        bmp1[y * stride1 + x / 8] |= (0x80 >> (x & 7));
                    }
                }
            }
        }

        write_page(bmp1, w, h, paper, page == 0, dpi, copies);
        if (bpp > 1) {
            free(bmp1);
        }
        free(bmp);

        page++;
        fprintf(stderr, "PAGE: %d %d\n", page, copies);
    }

    cupsRasterClose(ras);
    if (fd != 0) {
        close(fd);
    }

    fputs("@PJL EOJ\r\n\x1b%-12345X\r\n", stdout);
    fflush(stdout);

    return 0;
}
