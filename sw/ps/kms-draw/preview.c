/* preview.c — offline render of kms-draw's composed 1920x1080 layout, no DRM
 * device needed. It includes kms-draw.c with main() compiled out, supplies a
 * heap framebuffer, loads frame N from a .p5q capture through the real frame
 * path, runs draw_layout(), and writes a PPM. Use it to eyeball layout changes
 * (Quake window placement, the palette grid, status text) without the board.
 *
 *   make preview
 *   ./preview <file.p5q> [frameN] [out.ppm]
 *   # e.g. ./preview /tmp/quake.p5q 183 out.ppm  (then view out.ppm)
 */
#define KMSDRAW_NO_MAIN
#include "kms-draw.c"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    const char *p5q = argc > 1 ? argv[1] : "quake.p5q";
    int         want = argc > 2 ? atoi(argv[2]) : 0;
    const char *out  = argc > 3 ? argv[3] : "preview.ppm";

    g_src_path = p5q;
    g_fb = calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    g_stride_px = SCREEN_W;
    if (!g_fb) { perror("calloc"); return 1; }

    /* a regular file advances one frame per poll; pull frame `want` */
    for (int i = 0; i <= want; i++)
        poll_quake_frames();

    draw_layout(42);

    FILE *f = fopen(out, "wb");
    if (!f) { perror("fopen"); return 1; }
    fprintf(f, "P6\n%d %d\n255\n", SCREEN_W, SCREEN_H);
    for (size_t i = 0; i < (size_t)SCREEN_W * SCREEN_H; i++) {
        uint16_t c = g_fb[i];
        unsigned r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f;
        unsigned char px[3] = {
            (unsigned char)((r << 3) | (r >> 2)),
            (unsigned char)((g << 2) | (g >> 4)),
            (unsigned char)((b << 3) | (b >> 2)),
        };
        fwrite(px, 1, 3, f);
    }
    fclose(f);
    fprintf(stderr, "preview: have_frame=%d qframe=%lu -> %s (%dx%d)\n",
            g_have_frame, g_qframe, out, SCREEN_W, SCREEN_H);
    return 0;
}
