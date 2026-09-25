/*
 * generate_test_raster.c — Test utility to generate synthetic CUPS raster test streams
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cups/cups.h>
#include <cups/raster.h>

int main(int argc, char* argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <output_file> [type: mono|gray|rgb|legal|duplex|empty|multipage]\n", argv[0]);
        return 1;
    }

    const char* filename = argv[1];
    const char* type = (argc >= 3) ? argv[2] : "mono";

    FILE* fp = fopen(filename, "wb");
    if (!fp) {
        perror("fopen");
        return 1;
    }

    cups_raster_t* ras = cupsRasterOpen(fileno(fp), CUPS_RASTER_WRITE);
    if (!ras) {
        fprintf(stderr, "Failed to open cups raster writer\n");
        fclose(fp);
        return 1;
    }

    if (strcmp(type, "empty") == 0) {
        cupsRasterClose(ras);
        fclose(fp);
        return 0;
    }

    int num_pages = (strcmp(type, "multipage") == 0) ? 2 : 1;

    for (int p = 0; p < num_pages; p++) {
        cups_page_header2_t hdr;
        memset(&hdr, 0, sizeof(hdr));

        hdr.HWResolution[0] = 600;
        hdr.HWResolution[1] = 600;
        hdr.cupsWidth = 64;   /* 64 pixels wide */
        hdr.cupsHeight = 64;  /* 64 pixels high */

        if (strcmp(type, "large") == 0) {
            hdr.cupsWidth = 3000;
            hdr.cupsHeight = 3000;
            hdr.PageSize[0] = 595;
            hdr.PageSize[1] = 842;
            hdr.cupsBitsPerPixel = 1;
            hdr.cupsColorSpace = CUPS_CSPACE_K;
        } else if (strcmp(type, "legal") == 0) {
            hdr.PageSize[0] = 612;
            hdr.PageSize[1] = 1008; /* Legal height > 900 */
            hdr.MediaPosition = 1;  /* Manual tray */
            hdr.Duplex = 1;
            hdr.Tumble = 1;
            hdr.cupsBitsPerPixel = 1;
            hdr.cupsColorSpace = CUPS_CSPACE_K;
        } else if (strcmp(type, "duplex") == 0) {
            hdr.PageSize[0] = 612;  /* Letter width > 600 */
            hdr.PageSize[1] = 792;
            hdr.MediaPosition = 0;
            hdr.Duplex = 1;
            hdr.Tumble = 0;
            hdr.cupsBitsPerPixel = 1;
            hdr.cupsColorSpace = CUPS_CSPACE_K;
        } else if (strcmp(type, "gray") == 0) {
            hdr.PageSize[0] = 595;  /* A4 */
            hdr.PageSize[1] = 842;
            hdr.cupsBitsPerPixel = 8;
            hdr.cupsColorSpace = CUPS_CSPACE_W; /* White */
        } else if (strcmp(type, "gray_cspace3") == 0) {
            hdr.PageSize[0] = 595;
            hdr.PageSize[1] = 842;
            hdr.cupsBitsPerPixel = 8;
            hdr.cupsColorSpace = (cups_cspace_t)3; /* ColorSpace 3 */
        } else if (strcmp(type, "rgb") == 0) {
            hdr.PageSize[0] = 595;
            hdr.PageSize[1] = 842;
            hdr.cupsBitsPerPixel = 24;
            hdr.cupsColorSpace = CUPS_CSPACE_RGB;
        } else {
            /* Default mono */
            hdr.PageSize[0] = 595;
            hdr.PageSize[1] = 842;
            hdr.cupsBitsPerPixel = 1;
            hdr.cupsColorSpace = CUPS_CSPACE_K;
        }

        hdr.cupsBytesPerLine = (hdr.cupsWidth * hdr.cupsBitsPerPixel + 7) / 8;

        if (!cupsRasterWriteHeader2(ras, &hdr)) {
            fprintf(stderr, "Failed to write header\n");
            cupsRasterClose(ras);
            fclose(fp);
            return 1;
        }

        unsigned char* line = (unsigned char*)malloc(hdr.cupsBytesPerLine);
        unsigned seed = 12345;
        for (unsigned y = 0; y < hdr.cupsHeight; y++) {
            for (unsigned x = 0; x < hdr.cupsBytesPerLine; x++) {
                if (strcmp(type, "large") == 0) {
                    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
                    line[x] = (unsigned char)(seed & 0xFF);
                } else if (hdr.cupsBitsPerPixel == 1) {
                    line[x] = (unsigned char)((x + y + p) % 2 == 0 ? 0xAA : 0x55);
                } else if (hdr.cupsBitsPerPixel == 8) {
                    line[x] = (unsigned char)((x * 16 + y * 8) % 256);
                } else if (hdr.cupsBitsPerPixel == 24) {
                    line[x] = (unsigned char)((x * 32 + y * 16) % 256);
                }
            }
            cupsRasterWritePixels(ras, line, hdr.cupsBytesPerLine);
        }
        free(line);
    }

    cupsRasterClose(ras);
    fclose(fp);
    return 0;
}
