/*
 * rastertoricohlhpl.c — Native CUPS raster filter for Ricoh SP 150 series (LHPL protocol)
 *
 * Supports:
 *   - Ricoh SP 150 / SP 150w / SP 150SU / SP 150SUw
 *   - Lenovo M100D / L100D (compatible LHPL OEM engine)
 *
 * Protocol Overview:
 *   Unlike Ricoh SP 100/111/200/210/310 which use Ricoh DDST bi-level stream
 *   framing, the Ricoh SP 150 series uses the LHPL protocol:
 *     1. PJL job header entering LHPL: @PJL ENTER LANGUAGE=LHPL
 *     2. Fixed 64-byte binary command packets (@sj, @sp, @ep) with XOR checksums
 *     3. JBIG T.85 single-progression compression with L0=128, SDRST resets, and MX=64
 *     4. 128-scanline blank top padding to prevent paper feed motor stall
 *
 * Developed for the Ricoh Universal DDST/GDI Driver Suite.
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/types.h>
#include <cups/cups.h>
#include <cups/raster.h>
#include "jbig/jbig85.h"

#define LHPL_CMD_SIZE        64
#define LHPL_PAGE_WIDTH      5120   /* Standard printable raster width at 600 DPI */
#define LHPL_TOP_PAD_ROWS    128    /* Blank padding rows required by LHPL engine */
#define LHPL_STRIPE_HEIGHT   128    /* L0 stripe height for JBIG T.85 */

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

/* Growable output buffer for JBIG encoder output callback */
typedef struct {
    unsigned char* data;
    size_t         size;
    size_t         cap;
} Buf;

STATIC void jbig_buf_cb(unsigned char* d, size_t n, void* arg)
{
    Buf* b = (Buf*)arg;
    if (b->size + n > b->cap) {
        size_t new_cap = (b->size + n) * 2;
        if (new_cap < 65536) new_cap = 65536;
        unsigned char* new_data = (unsigned char*)REALLOC(b->data, new_cap);
        if (!new_data) {
            fprintf(stderr, "ERROR: rastertoricohlhpl: Out of memory expanding buffer\n");
            return;
        }
        b->data = new_data;
        b->cap = new_cap;
    }
    memcpy(b->data + b->size, d, n);
    b->size += n;
}

/* 8x8 Bayer ordered dithering threshold matrix for fast high-quality halftoning */
static const unsigned char bayer8x8[8][8] = {
    {   0, 128,  32, 160,   8, 136,  40, 168 },
    { 192,  64, 224,  96, 200,  72, 232, 104 },
    {  48, 176,  16, 144,  56, 184,  24, 152 },
    { 240, 112, 208,  80, 248, 120, 216,  88 },
    {  12, 140,  44, 172,   4, 132,  36, 164 },
    { 204,  76, 236, 108, 196,  68, 228, 100 },
    {  60, 188,  28, 156,  52, 180,  20, 148 },
    { 252, 124, 220,  92, 244, 116, 212,  84 }
};

/* Compute 1-byte XOR checksum over bytes 0..len-2 and store in buf[len-1] */
STATIC void lhpl_xor_checksum(unsigned char* buf, size_t len)
{
    unsigned char xor_val = 0;
    for (size_t i = 0; i < len - 1; i++) {
        xor_val ^= buf[i];
    }
    buf[len - 1] = xor_val;
}

/* Write LHPL @sj (Start Job) frame (64 bytes) */
STATIC void write_lhpl_sj(int copies)
{
    unsigned char cmd[LHPL_CMD_SIZE];
    memset(cmd, 0, sizeof(cmd));

    /* Prefix: ESC LH @sj */
    cmd[0] = 0x1b; cmd[1] = 'L'; cmd[2] = 'H'; cmd[3] = '@';
    cmd[4] = 's';  cmd[5] = 'j';

    cmd[6] = 0x01; /* Version */
    cmd[7] = 0x00;
    cmd[8] = (unsigned char)(copies & 0xff);
    cmd[9] = (unsigned char)((copies >> 8) & 0xff);

    lhpl_xor_checksum(cmd, sizeof(cmd));
    fwrite(cmd, 1, sizeof(cmd), stdout);
}

/* Write LHPL @sp (Start Page) frame header (64 bytes) followed by JBIG stream */
STATIC void write_lhpl_sp(unsigned width, unsigned height, unsigned resolution,
                          const unsigned char* jbig_data, size_t jbig_len)
{
    unsigned char hdr[LHPL_CMD_SIZE];
    unsigned uncompressed_size = ((width + 7) / 8) * height;

    memset(hdr, 0, sizeof(hdr));

    /* Prefix: ESC LH @sp */
    hdr[0] = 0x1b; hdr[1] = 'L'; hdr[2] = 'H'; hdr[3] = '@';
    hdr[4] = 's';  hdr[5] = 'p';

    /* Page type / flags: 0x0102 (Little-Endian) */
    hdr[6] = 0x02;
    hdr[7] = 0x01;

    /* Width (32-bit LE) */
    hdr[8]  = (unsigned char)(width & 0xff);
    hdr[9]  = (unsigned char)((width >> 8) & 0xff);
    hdr[10] = (unsigned char)((width >> 16) & 0xff);
    hdr[11] = (unsigned char)((width >> 24) & 0xff);

    /* Height (32-bit LE) */
    hdr[12] = (unsigned char)(height & 0xff);
    hdr[13] = (unsigned char)((height >> 8) & 0xff);
    hdr[14] = (unsigned char)((height >> 16) & 0xff);
    hdr[15] = (unsigned char)((height >> 24) & 0xff);

    /* Uncompressed size in bytes (32-bit LE) */
    hdr[16] = (unsigned char)(uncompressed_size & 0xff);
    hdr[17] = (unsigned char)((uncompressed_size >> 8) & 0xff);
    hdr[18] = (unsigned char)((uncompressed_size >> 16) & 0xff);
    hdr[19] = (unsigned char)((uncompressed_size >> 24) & 0xff);

    /* Compressed size in bytes (32-bit LE) */
    hdr[20] = (unsigned char)(jbig_len & 0xff);
    hdr[21] = (unsigned char)((jbig_len >> 8) & 0xff);
    hdr[22] = (unsigned char)((jbig_len >> 16) & 0xff);
    hdr[23] = (unsigned char)((jbig_len >> 24) & 0xff);

    /* Compressed size repeated (32-bit LE) */
    hdr[24] = hdr[20];
    hdr[25] = hdr[21];
    hdr[26] = hdr[22];
    hdr[27] = hdr[23];

    /* Resolution (16-bit LE, at offset 42) */
    hdr[42] = (unsigned char)(resolution & 0xff);
    hdr[43] = (unsigned char)((resolution >> 8) & 0xff);

    /* Engine constants in 0.1mm units: 0x0834 (2100 = 210mm), 0x0b9a (2970 = 297mm) */
    hdr[44] = 0x34; hdr[45] = 0x08;
    hdr[46] = 0x9a; hdr[47] = 0x0b;

    lhpl_xor_checksum(hdr, sizeof(hdr));

    fwrite(hdr, 1, sizeof(hdr), stdout);
    if (jbig_len > 0 && jbig_data) {
        fwrite(jbig_data, 1, jbig_len, stdout);
    }
}

/* Write LHPL @ep (End Page) frame (64 bytes) */
STATIC void write_lhpl_ep(void)
{
    unsigned char cmd[LHPL_CMD_SIZE];
    memset(cmd, 0, sizeof(cmd));

    /* Prefix: ESC LH @ep */
    cmd[0] = 0x1b; cmd[1] = 'L'; cmd[2] = 'H'; cmd[3] = '@';
    cmd[4] = 'e';  cmd[5] = 'p';

    lhpl_xor_checksum(cmd, sizeof(cmd));
    fwrite(cmd, 1, sizeof(cmd), stdout);
}

/* Emit PJL Job Header switching to LHPL */
STATIC void write_job_header(int copies, unsigned dpi, const char* user, const char* title)
{
    time_t     now = time(NULL);
    struct tm* t = LOCALTIME(&now);

    fputs("\x1b%-12345X@PJL JOB NAME=PRINTER\r\n", stdout);
    fprintf(stdout, "@PJL SET JOBATTR=HST:localhost\r\n");
    fprintf(stdout, "@PJL SET JOBATTR=USR:%s\r\n", (user && user[0]) ? user : "lp");
    fprintf(stdout, "@PJL SET JOBATTR=DOC:%s\r\n", (title && title[0]) ? title : "printjob");

    if (t) {
        fprintf(stdout,
            "@PJL SET JOBATTR=DATE:%02d/%02d/%04d\r\n"
            "@PJL SET JOBATTR=TIME:%02d:%02d:%02d\r\n",
            t->tm_mon + 1, t->tm_mday, t->tm_year + 1900,
            t->tm_hour, t->tm_min, t->tm_sec);
    } else {
        fprintf(stdout,
            "@PJL SET JOBATTR=DATE:01/01/2026\r\n"
            "@PJL SET JOBATTR=TIME:00:00:00\r\n");
    }

    fprintf(stdout,
        "@PJL SET DUPLEX=OFF\r\n"
        "@PJL SET MEDIASOURCE=0\r\n"
        "@PJL SET MDPXS=0\r\n"
        "@PJL SET BITSPERPIXEL=1\r\n"
        "@PJL SET COPIES=%d\r\n"
        "@PJL SET RESOLUTION=%u\r\n"
        "@PJL SET RENDERMODE=GRAYSCALE\r\n"
        "@PJL ENTER LANGUAGE=LHPL\r\n",
        copies, dpi);
}

int main(int argc, char* argv[])
{
    int copies = 1;
    int fd = 0;
    const char* user = "lp";
    const char* title = "printjob";

    if (argc >= 3 && argv[2] && argv[2][0] != '\0') {
        user = argv[2];
    }
    if (argc >= 4 && argv[3] && argv[3][0] != '\0') {
        title = argv[3];
    }
    if (argc >= 5 && argv[4] && argv[4][0] != '\0') {
        copies = atoi(argv[4]);
        if (copies < 1) copies = 1;
    }
    if (argc >= 7 && argv[6] && argv[6][0] != '\0') {
        fd = open(argv[6], O_RDONLY);
        if (fd < 0) {
            fprintf(stderr, "ERROR: rastertoricohlhpl: Unable to open print file '%s'\n", argv[6]);
            return 1;
        }
    }

    cups_raster_t* ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
    if (!ras) {
        fprintf(stderr, "ERROR: rastertoricohlhpl: Unable to open raster stream\n");
        if (fd != 0) close(fd);
        return 1;
    }

    cups_page_header2_t hdr;
    int page = 0;
    int job_header_written = 0;

    while (cupsRasterReadHeader2(ras, &hdr)) {
        unsigned cups_w = hdr.cupsWidth;
        unsigned cups_h = hdr.cupsHeight;
        unsigned bpp = hdr.cupsBitsPerPixel;
        unsigned cspace = hdr.cupsColorSpace;
        unsigned dpi = (hdr.HWResolution[0] >= 1200) ? 1200 : 600;
        unsigned stride_in = hdr.cupsBytesPerLine;

        if (cups_w == 0 || cups_h == 0) continue;

        if (!job_header_written) {
            write_job_header(copies, dpi, user, title);
            write_lhpl_sj(copies);
            job_header_written = 1;
        }

        unsigned out_w = (cups_w > LHPL_PAGE_WIDTH) ? cups_w : LHPL_PAGE_WIDTH;
        unsigned out_bpl = (out_w + 7) / 8;
        unsigned total_h = cups_h + LHPL_TOP_PAD_ROWS;

        size_t total_buf_size = (size_t)total_h * out_bpl;
        unsigned char* page_buf = (unsigned char*)CALLOC(total_h, out_bpl);
        if (!page_buf) {
            fprintf(stderr, "ERROR: rastertoricohlhpl: Out of memory allocating page bitmap (%zu bytes)\n", total_buf_size);
            cupsRasterClose(ras);
            if (fd != 0) close(fd);
            return 1;
        }

        unsigned char* row_in = (unsigned char*)MALLOC(stride_in);
        if (!row_in) {
            fprintf(stderr, "ERROR: rastertoricohlhpl: Out of memory allocating row buffer\n");
            free(page_buf);
            cupsRasterClose(ras);
            if (fd != 0) close(fd);
            return 1;
        }

        int is_cspace_k = (cspace == 3);

        /* Read and dither lines into page_buf after top padding */
        for (unsigned y = 0; y < cups_h; y++) {
            if (cupsRasterReadPixels(ras, row_in, stride_in) == 0) {
                break;
            }

            unsigned char* dst_line = page_buf + (size_t)(LHPL_TOP_PAD_ROWS + y) * out_bpl;

            if (bpp == 1) {
                /* 1-bit packed raster: copy up to cups_w bits */
                unsigned copy_bytes = (cups_w + 7) / 8;
                if (copy_bytes > stride_in) copy_bytes = stride_in;
                if (copy_bytes > out_bpl) copy_bytes = out_bpl;

                if (is_cspace_k) {
                    /* In K color space 1=black, matches hardware polarity */
                    memcpy(dst_line, row_in, copy_bytes);
                } else {
                    /* In White/Gray 1-bit, 0=black, invert to 1=black */
                    for (unsigned i = 0; i < copy_bytes; i++) {
                        dst_line[i] = (unsigned char)~row_in[i];
                    }
                }
            } else if (bpp == 8) {
                /* 8-bit grayscale: Bayer 8x8 ordered dither */
                for (unsigned x = 0; x < cups_w; x++) {
                    unsigned char px = row_in[x];
                    unsigned char threshold = bayer8x8[y & 7][x & 7];
                    int is_black = is_cspace_k ? (px > threshold) : ((255 - px) > threshold);
                    if (is_black) {
                        dst_line[x >> 3] |= (unsigned char)(0x80 >> (x & 7));
                    }
                }
            } else {
                /* 24-bit/32-bit RGB(A): convert to luminance then dither */
                unsigned bpp_step = bpp / 8;
                for (unsigned x = 0; x < cups_w; x++) {
                    unsigned r = row_in[x * bpp_step];
                    unsigned g = row_in[x * bpp_step + 1];
                    unsigned b_val = row_in[x * bpp_step + 2];
                    unsigned char px = (unsigned char)((r * 77 + g * 150 + b_val * 29) >> 8);
                    unsigned char threshold = bayer8x8[y & 7][x & 7];
                    int is_black = is_cspace_k ? (px > threshold) : ((255 - px) > threshold);
                    if (is_black) {
                        dst_line[x >> 3] |= (unsigned char)(0x80 >> (x & 7));
                    }
                }
            }
        }
        free(row_in);

        /* Encode page using JBIG T.85 */
        Buf jbig_buf = { NULL, 0, 0 };
        struct jbg85_enc_state jbig_state;
        jbg85_enc_init(&jbig_state, out_w, total_h, jbig_buf_cb, &jbig_buf);
        jbg85_enc_options(&jbig_state, JBG_LRLTWO, LHPL_STRIPE_HEIGHT, 8);

        unsigned char* prev_line  = (unsigned char*)CALLOC(out_bpl, 1);
        unsigned char* prev2_line = (unsigned char*)CALLOC(out_bpl, 1);
        unsigned char* cur_line   = (unsigned char*)CALLOC(out_bpl, 1);

        if (!prev_line || !prev2_line || !cur_line) {
            fprintf(stderr, "ERROR: rastertoricohlhpl: Out of memory allocating JBIG history buffers\n");
            free(prev_line); free(prev2_line); free(cur_line);
            free(page_buf);
            cupsRasterClose(ras);
            if (fd != 0) close(fd);
            return 1;
        }

        for (unsigned y = 0; y < total_h; y++) {
            memcpy(cur_line, page_buf + (size_t)y * out_bpl, out_bpl);
            jbg85_enc_lineout(&jbig_state, cur_line, prev_line, prev2_line);
            unsigned char* tmp = prev2_line;
            prev2_line = prev_line;
            prev_line  = cur_line;
            cur_line   = tmp;
        }

        free(prev_line);
        free(prev2_line);
        free(cur_line);
        free(page_buf);

        /* Write LHPL @sp (Start Page) frame and JBIG stream */
        write_lhpl_sp(out_w, total_h, dpi, jbig_buf.data, jbig_buf.size);
        free(jbig_buf.data);

        /* Write LHPL @ep (End Page) frame */
        write_lhpl_ep();
        fflush(stdout);

        page++;
        fprintf(stderr, "PAGE: %d %d\n", page, copies);
    }

    if (!job_header_written) {
        write_job_header(copies, 600, user, title);
        write_lhpl_sj(copies);
    }

    cupsRasterClose(ras);
    if (fd != 0) {
        close(fd);
    }

    /* PJL EOJ */
    fputs("@PJL EOJ\r\n\x1b%-12345X\r\n", stdout);
    fflush(stdout);

    return 0;
}
