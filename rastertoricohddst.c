/*
 * rastertoricohddst.c — Universal CUPS raster filter for Ricoh DDST laser printers
 *
 * Supports:
 *   - Ricoh SP 100 / SP 110 / SP 111 / SP 112 / SP 150 series
 *   - Ricoh SP 200 / SP 201 / SP 202 / SP 203 / SP 204 series
 *   - Ricoh SP 210 / SP 211 / SP 212 / SP 213 / SP 220 / SP 230 series
 *   - Ricoh SP 310 / SP 311 / SP 320 / SP 325 / SP 330 / SP 3710 series
 *
 * Based on the reverse engineering work of Aryan Kushwaha (funinkina) and the
 * Ricoh DDST protocol analysis of Alexey (madlynx).
 * Developed and maintained by Ankit Kumar Singh (ankitsingh99) and contributors.
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
            fprintf(stderr, "ERROR: rastertoricohddst: Out of memory expanding buffer\n");
            return;
        }
        b->data = new_data;
        b->cap = new_cap;
    }
    memcpy(b->data + b->size, d, n);
    b->size += n;
}

STATIC void write_job_header(int copies, int duplex, int tumble, const char* tray)
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
        "@PJL SET MEDIASOURCE=%s\r\n"
        "@PJL SET MEDIATYPE=PLAINRECYCLE\r\n",
        copies,
        tray ? tray : "TRAY1");

    if (duplex) {
        fprintf(stdout,
            "@PJL SET DUPLEX=ON\r\n"
            "@PJL SET BINDING=%s\r\n",
            tumble ? "SHORT" : "LONG");
    } else {
        fprintf(stdout, "@PJL SET DUPLEX=OFF\r\n");
    }
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
 * Encode and send one page.
 */
STATIC void write_page(unsigned char* bmp, unsigned w, unsigned h,
    const char* paper, int first_page,
    unsigned dpi, int copies, const char* tray)
{
    Buf buf = { (unsigned char*)MALLOC(1 << 17), 0, 1 << 17 };
    if (!buf.data) {
        fprintf(stderr, "ERROR: rastertoricohddst: Out of memory allocating page buffer\n");
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
            "@PJL SET MEDIASOURCE=%s\r\n"
            "@PJL SET MEDIATYPE=PLAINRECYCLE\r\n",
            copies,
            tray ? tray : "TRAY1");
    }

    /* PAPER, PAPERWIDTH, PAPERLENGTH and RESOLUTION are required per page. */
    fprintf(stdout,
        "@PJL SET PAPER=%s\r\n"
        "@PJL SET PAPERWIDTH=%u\r\n"
        "@PJL SET PAPERLENGTH=%u\r\n"
        "@PJL SET RESOLUTION=%u\r\n",
        paper, w, h, dpi);

    jbg_enc_init(&enc, w, h, 1, planes, buf_cb, &buf);
    /* Standard Ricoh DDST BIE byte parameters: order 0x03, options 0x48 */
    jbg_enc_options(&enc, 0x03, 0x48, 128, 0, 0);
    jbg_enc_out(&enc);
    jbg_enc_free(&enc);

    fprintf(stdout, "@PJL SET IMAGELEN=%zu\r\n", buf.size);
    fwrite(buf.data, 1, buf.size, stdout);

    /* DOTCOUNT + PAGESTATUS=END triggers paper feed/eject */
    unsigned long dots = count_dots(bmp, w, h);
    fprintf(stdout,
        "@PJL SET DOTCOUNT=%lu\r\n"
        "@PJL SET PAGESTATUS=END\r\n",
        dots);
    fflush(stdout);

    free(buf.data);
}

STATIC const char* map_paper_name(unsigned width_pt, unsigned length_pt)
{
    if (length_pt > 900) return "LEGAL";
    if (width_pt > 600)  return "LETTER";
    return "A4";
}

int main(int argc, char* argv[])
{
    int copies = 1;
    int fd = 0;

    /*
     * Standard CUPS filter argument handling:
     * argv[1] = Job ID
     * argv[2] = User
     * argv[3] = Title
     * argv[4] = Number of copies
     * argv[5] = Options
     * argv[6] = Optional filename
     */
    if (argc >= 5) {
        copies = atoi(argv[4]);
        if (copies < 1) copies = 1;
    }

    if (argc >= 7 && argv[6] && argv[6][0] != '\0') {
        fd = open(argv[6], O_RDONLY);
        if (fd < 0) {
            fprintf(stderr, "ERROR: rastertoricohddst: Unable to open print file '%s'\n", argv[6]);
            return 1;
        }
    }

    cups_raster_t* ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
    if (!ras) {
        fprintf(stderr, "ERROR: rastertoricohddst: Unable to open raster stream\n");
        if (fd != 0) close(fd);
        return 1;
    }

    cups_page_header2_t hdr;
    int                 page = 0;
    int                 job_header_written = 0;

    while (cupsRasterReadHeader2(ras, &hdr)) {
        unsigned w = hdr.cupsWidth;
        unsigned h = hdr.cupsHeight;
        unsigned bpp = hdr.cupsBitsPerPixel;
        unsigned cspace = hdr.cupsColorSpace;
        unsigned dpi = hdr.HWResolution[0];
        unsigned stride = hdr.cupsBytesPerLine;

        const char* paper = map_paper_name(hdr.PageSize[0], hdr.PageSize[1]);
        const char* tray = (hdr.MediaPosition == 1) ? "MANUAL" : "TRAY1";
        int duplex = (hdr.Duplex != 0);
        int tumble = (hdr.Tumble != 0);

        if (!job_header_written) {
            write_job_header(copies, duplex, tumble, tray);
            job_header_written = 1;
        }

        unsigned char* bmp = (unsigned char*)MALLOC(stride * h);
        if (!bmp) {
            fprintf(stderr, "ERROR: rastertoricohddst: Out of memory allocating raster bitmap\n");
            cupsRasterClose(ras);
            if (fd != 0) close(fd);
            return 1;
        }

        for (unsigned y = 0; y < h; y++) {
            cupsRasterReadPixels(ras, bmp + y * stride, stride);
        }

        /* 1-bit monochrome conversion fallback if pipeline delivers 8-bit gray or 24-bit RGB */
        unsigned char* bmp1 = bmp;
        if (bpp > 1) {
            unsigned stride1 = (w + 7) / 8;
            bmp1 = (unsigned char*)CALLOC(stride1, h);
            if (!bmp1) {
                fprintf(stderr, "ERROR: rastertoricohddst: Out of memory allocating 1-bit conversion buffer\n");
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

        write_page(bmp1, w, h, paper, page == 0, dpi, copies, tray);
        if (bpp > 1) {
            free(bmp1);
        }
        free(bmp);

        page++;
        fprintf(stderr, "PAGE: %d %d\n", page, copies);
    }

    if (!job_header_written) {
        write_job_header(copies, 0, 0, "TRAY1");
    }

    cupsRasterClose(ras);
    if (fd != 0) {
        close(fd);
    }

    fputs("@PJL EOJ\r\n\x1b%-12345X\r\n", stdout);
    fflush(stdout);

    return 0;
}
