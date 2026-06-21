#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#define DEV_PATH "/dev/dri/card0"

#define CONN_ID 45
#define CRTC_ID 43

#define SCREEN_W 1920
#define SCREEN_H 1080

#define LEFT_X 60
#define TOP_Y  60
#define CB_W   1280
#define CB_H   960

#define GAP    60
#define TEXT_X (LEFT_X + CB_W + GAP)
#define TEXT_Y 60
#define TEXT_W 460
#define TEXT_H 960

struct kms_buf {
    uint32_t handle;
    uint32_t fb_id;
    uint32_t pitch;
    uint64_t size;
    uint16_t *pix;
};

static int drm_fd = -1;
static uint32_t conn_id = CONN_ID;
static uint32_t crtc_id = CRTC_ID;
static drmModeModeInfo mode;

static struct kms_buf bufs[2];

static volatile sig_atomic_t running = 1;
static volatile int page_flip_pending = 0;

static uint16_t *g_fb = NULL;
static uint32_t g_stride_px = 0;

/* ---- Quake P5Q1 framebuffer source ------------------------------------------
 * The userspace Quake guest emits frames over the P5Q1 protocol (vid_p5fb.c;
 * verif/bench/p5q_to_png.py): a one-time header {u32 magic 'P5Q1', u32 w, u32 h}
 * then, per frame, {palette[768] = 256*RGB8, pixels[w*h] = 8-bit indices}. We
 * read that stream from g_src_path, keep the latest decoded frame, and blit it
 * nearest-neighbour-scaled into the 1280x960 left window every vsync.
 *   - a regular .p5q FILE  -> paced replay, one frame per flip, looped at EOF
 *   - a FIFO               -> live:  mkfifo /tmp/q.fifo
 *                                    ven_soc_app --video /tmp/q.fifo --quake ... &
 *                                    kms-draw /tmp/q.fifo
 * Source is opened O_NONBLOCK so the vsync page-flip loop never stalls on it. */
#define QK_MAGIC 0x31513550u            /* 'P5Q1', little-endian */
#define QK_W     320
#define QK_H     200

static const char   *g_src_path = "/tmp/quake.p5q";
static int           g_src_fd   = -1;
static int           g_src_is_reg = 0;          /* regular file -> paced + looped */
/* --vga13: show the live mode-13h fb (core-physical 0xA0000 in the carveout) +
 * the exported VGA DAC directly, instead of a P5Q1 stream. For DOS Quake / any
 * native mode-13h app on the board (F4A). */
#define VEN_CARVEOUT_BASE 0x40000000UL
#define VGA13_FB_OFF      0xA0000UL
static int           g_vga13   = 0;
static const uint8_t *g_vga13_fb = 0;           /* mmap'd /dev/mem carveout + 0xA0000 */
static const char   *g_dac_path = "/dev/shm/ven_vga_dac";
static int           g_qw = QK_W, g_qh = QK_H;
static size_t        g_framesz   = 768 + (size_t)QK_W * QK_H;
static uint8_t       g_qpix[QK_W * QK_H];       /* latest frame, 8-bit indices */
static uint16_t      g_qlut[256];               /* latest palette -> RGB565 */
static int           g_have_frame = 0;
static unsigned long g_qframe = 0;              /* Quake frames consumed */

/* incremental stream assembly (tolerates partial reads / FIFO trickle) */
static uint8_t       g_asm[768 + QK_W * QK_H];
static size_t        g_asmfill = 0;
static int           g_hdr_done = 0;

/* dst(1280x960) -> src(qw x qh) nearest-neighbour index maps */
static int g_colmap[CB_W];
static int g_rowmap[CB_H];

static void die(const char *s)
{
    perror(s);
    exit(1);
}

static void on_sigint(int sig)
{
    (void)sig;
    running = 0;
}

static void page_flip_handler(int fd,
                              unsigned int frame,
                              unsigned int sec,
                              unsigned int usec,
                              void *data)
{
    (void)fd;
    (void)frame;
    (void)sec;
    (void)usec;
    (void)data;
    page_flip_pending = 0;
}

static uint16_t rgb565(unsigned r, unsigned g, unsigned b)
{
    return (uint16_t)(((r & 0xf8) << 8) |
                      ((g & 0xfc) << 3) |
                      ((b & 0xf8) >> 3));
}

static void putpx(int x, int y, uint16_t c)
{
    if (x < 0 || x >= SCREEN_W || y < 0 || y >= SCREEN_H)
        return;
    g_fb[y * g_stride_px + x] = c;
}

static void fill_rect(int x, int y, int w, int h, uint16_t c)
{
    if (w <= 0 || h <= 0)
        return;

    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > SCREEN_W) w = SCREEN_W - x;
    if (y + h > SCREEN_H) h = SCREEN_H - y;

    if (w <= 0 || h <= 0)
        return;

    for (int yy = y; yy < y + h; yy++) {
        uint16_t *row = g_fb + yy * g_stride_px + x;
        for (int xx = 0; xx < w; xx++)
            row[xx] = c;
    }
}

static void draw_rect_outline(int x, int y, int w, int h, int t, uint16_t c)
{
    fill_rect(x, y, w, t, c);
    fill_rect(x, y + h - t, w, t, c);
    fill_rect(x, y, t, h, c);
    fill_rect(x + w - t, y, t, h, c);
}

/* 5x7 bitmap font, 1:1 pixels when scale=1. */
static const uint8_t GLYPH_SPACE[7] = {0,0,0,0,0,0,0};
static const uint8_t GLYPH_DOT[7]   = {0,0,0,0,0,0x0C,0x0C};
static const uint8_t GLYPH_COLON[7] = {0,0x0C,0x0C,0,0x0C,0x0C,0};
static const uint8_t GLYPH_DASH[7]  = {0,0,0,0x1E,0,0,0};
static const uint8_t GLYPH_SLASH[7] = {0x01,0x02,0x04,0x08,0x10,0,0};
static const uint8_t GLYPH_XLOW[7]  = {0x11,0x0A,0x04,0x04,0x0A,0x11,0};

static const uint8_t GLYPH_0[7] = {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E};
static const uint8_t GLYPH_1[7] = {0x04,0x0C,0x04,0x04,0x04,0x04,0x0E};
static const uint8_t GLYPH_2[7] = {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F};
static const uint8_t GLYPH_3[7] = {0x1E,0x01,0x01,0x0E,0x01,0x01,0x1E};
static const uint8_t GLYPH_4[7] = {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02};
static const uint8_t GLYPH_5[7] = {0x1F,0x10,0x10,0x1E,0x01,0x01,0x1E};
static const uint8_t GLYPH_6[7] = {0x07,0x08,0x10,0x1E,0x11,0x11,0x0E};
static const uint8_t GLYPH_7[7] = {0x1F,0x01,0x02,0x04,0x08,0x08,0x08};
static const uint8_t GLYPH_8[7] = {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E};
static const uint8_t GLYPH_9[7] = {0x0E,0x11,0x11,0x0F,0x01,0x02,0x1C};

static const uint8_t GLYPH_A[7] = {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11};
static const uint8_t GLYPH_B[7] = {0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E};
static const uint8_t GLYPH_C[7] = {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E};
static const uint8_t GLYPH_D[7] = {0x1E,0x11,0x11,0x11,0x11,0x11,0x1E};
static const uint8_t GLYPH_E[7] = {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F};
static const uint8_t GLYPH_F[7] = {0x1F,0x10,0x10,0x1E,0x10,0x10,0x10};
static const uint8_t GLYPH_G[7] = {0x0E,0x11,0x10,0x13,0x11,0x11,0x0E};
static const uint8_t GLYPH_H[7] = {0x11,0x11,0x11,0x1F,0x11,0x11,0x11};
static const uint8_t GLYPH_I[7] = {0x1F,0x04,0x04,0x04,0x04,0x04,0x1F};
static const uint8_t GLYPH_J[7] = {0x01,0x01,0x01,0x01,0x11,0x11,0x0E};
static const uint8_t GLYPH_K[7] = {0x11,0x12,0x14,0x18,0x14,0x12,0x11};
static const uint8_t GLYPH_L[7] = {0x10,0x10,0x10,0x10,0x10,0x10,0x1F};
static const uint8_t GLYPH_M[7] = {0x11,0x1B,0x15,0x15,0x11,0x11,0x11};
static const uint8_t GLYPH_N[7] = {0x11,0x19,0x15,0x13,0x11,0x11,0x11};
static const uint8_t GLYPH_O[7] = {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E};
static const uint8_t GLYPH_P[7] = {0x1E,0x11,0x11,0x1E,0x10,0x10,0x10};
static const uint8_t GLYPH_Q[7] = {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D};
static const uint8_t GLYPH_R[7] = {0x1E,0x11,0x11,0x1E,0x14,0x12,0x11};
static const uint8_t GLYPH_S[7] = {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E};
static const uint8_t GLYPH_T[7] = {0x1F,0x04,0x04,0x04,0x04,0x04,0x04};
static const uint8_t GLYPH_U[7] = {0x11,0x11,0x11,0x11,0x11,0x11,0x0E};
static const uint8_t GLYPH_V[7] = {0x11,0x11,0x11,0x11,0x11,0x0A,0x04};
static const uint8_t GLYPH_W[7] = {0x11,0x11,0x11,0x15,0x15,0x15,0x0A};
static const uint8_t GLYPH_X[7] = {0x11,0x11,0x0A,0x04,0x0A,0x11,0x11};
static const uint8_t GLYPH_Y[7] = {0x11,0x11,0x0A,0x04,0x04,0x04,0x04};
static const uint8_t GLYPH_Z[7] = {0x1F,0x01,0x02,0x04,0x08,0x10,0x1F};

static const uint8_t *glyph_for_char(char ch)
{
    switch (ch) {
    case ' ': return GLYPH_SPACE;
    case '.': return GLYPH_DOT;
    case ':': return GLYPH_COLON;
    case '-': return GLYPH_DASH;
    case '/': return GLYPH_SLASH;
    case 'x': return GLYPH_XLOW;

    case '0': return GLYPH_0; case '1': return GLYPH_1;
    case '2': return GLYPH_2; case '3': return GLYPH_3;
    case '4': return GLYPH_4; case '5': return GLYPH_5;
    case '6': return GLYPH_6; case '7': return GLYPH_7;
    case '8': return GLYPH_8; case '9': return GLYPH_9;

    case 'A': return GLYPH_A; case 'B': return GLYPH_B;
    case 'C': return GLYPH_C; case 'D': return GLYPH_D;
    case 'E': return GLYPH_E; case 'F': return GLYPH_F;
    case 'G': return GLYPH_G; case 'H': return GLYPH_H;
    case 'I': return GLYPH_I; case 'J': return GLYPH_J;
    case 'K': return GLYPH_K; case 'L': return GLYPH_L;
    case 'M': return GLYPH_M; case 'N': return GLYPH_N;
    case 'O': return GLYPH_O; case 'P': return GLYPH_P;
    case 'Q': return GLYPH_Q; case 'R': return GLYPH_R;
    case 'S': return GLYPH_S; case 'T': return GLYPH_T;
    case 'U': return GLYPH_U; case 'V': return GLYPH_V;
    case 'W': return GLYPH_W; case 'X': return GLYPH_X;
    case 'Y': return GLYPH_Y; case 'Z': return GLYPH_Z;

    default: return GLYPH_SPACE;
    }
}

static void draw_char(int x, int y, char ch, int scale, uint16_t fg, uint16_t bg, int opaque)
{
    const uint8_t *g = glyph_for_char(ch);

    for (int row = 0; row < 7; row++) {
        for (int col = 0; col < 5; col++) {
            int bit = (g[row] >> (4 - col)) & 1;
            if (bit || opaque) {
                fill_rect(x + col * scale,
                          y + row * scale,
                          scale,
                          scale,
                          bit ? fg : bg);
            }
        }
    }
}

static void draw_text(int x, int y, const char *s, int scale,
                      uint16_t fg, uint16_t bg, int opaque)
{
    int cx = x;
    int cy = y;

    while (*s) {
        if (*s == '\n') {
            cx = x;
            cy += 8 * scale;
            s++;
            continue;
        }

        draw_char(cx, cy, *s, scale, fg, bg, opaque);
        cx += 6 * scale;
        s++;
    }
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* Integer (square-pixel) scale: the largest N such that N*src fits the CB_W x
 * CB_H window, then centre it with a black letterbox/pillarbox. Never distort.
 *   320x200 -> 4x = 1280x800 (80px top/bottom bars)
 *   320x240 -> 4x = 1280x960 (fills the window)
 * The maps carry -1 for the border pixels so draw_quake() blacks them out. */
static void build_maps(void)
{
    int sx = CB_W / (g_qw > 0 ? g_qw : 1);
    int sy = CB_H / (g_qh > 0 ? g_qh : 1);
    int n  = sx < sy ? sx : sy;
    if (n < 1) n = 1;
    int xoff = (CB_W - n * g_qw) / 2;
    int yoff = (CB_H - n * g_qh) / 2;
    for (int dx = 0; dx < CB_W; dx++)
        g_colmap[dx] = (dx >= xoff && dx < xoff + n * g_qw) ? (dx - xoff) / n : -1;
    for (int dy = 0; dy < CB_H; dy++)
        g_rowmap[dy] = (dy >= yoff && dy < yoff + n * g_qh) ? (dy - yoff) / n : -1;
}

static void open_source(void)
{
    g_src_fd = open(g_src_path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (g_src_fd < 0)
        return;

    struct stat st;
    g_src_is_reg = (fstat(g_src_fd, &st) == 0) && S_ISREG(st.st_mode);
    g_hdr_done = 0;
    g_asmfill = 0;
}

static void commit_frame(void)
{
    const uint8_t *pal = g_asm;
    for (int i = 0; i < 256; i++)
        g_qlut[i] = rgb565(pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]);

    memcpy(g_qpix, g_asm + 768, (size_t)g_qw * g_qh);
    g_have_frame = 1;
    g_qframe++;
}

/* Pull whatever the stream has ready and update the latest frame. Never blocks
 * (the source is O_NONBLOCK). FILE: one frame per call, rewound at EOF. FIFO:
 * drain all queued frames, keeping the most recent (so the display never lags
 * behind a fast producer). Partial reads accumulate in g_asm across calls. */
static void poll_quake_frames(void)
{
    if (g_src_fd < 0) {
        open_source();
        if (g_src_fd < 0)
            return;
    }

    if (!g_hdr_done) {
        while (g_asmfill < 12) {
            ssize_t n = read(g_src_fd, g_asm + g_asmfill, 12 - g_asmfill);
            if (n > 0) { g_asmfill += (size_t)n; continue; }
            if (n == 0 && g_src_is_reg) { close(g_src_fd); g_src_fd = -1; }
            return;                       /* EAGAIN or short header: retry later */
        }
        if (le32(g_asm) != QK_MAGIC ||
            le32(g_asm + 4) != (uint32_t)QK_W ||
            le32(g_asm + 8) != (uint32_t)QK_H) {
            close(g_src_fd); g_src_fd = -1; g_asmfill = 0;   /* not a 320x200 P5Q1 */
            return;
        }
        g_qw = QK_W; g_qh = QK_H;
        g_framesz = 768 + (size_t)g_qw * g_qh;
        build_maps();
        g_hdr_done = 1;
        g_asmfill = 0;
    }

    for (;;) {
        ssize_t n = read(g_src_fd, g_asm + g_asmfill, g_framesz - g_asmfill);
        if (n > 0) {
            g_asmfill += (size_t)n;
            if (g_asmfill == g_framesz) {
                commit_frame();
                g_asmfill = 0;
                if (g_src_is_reg)
                    return;               /* pace replay: one frame per flip */
            }
            continue;
        }
        if (n == 0) {                      /* EOF */
            if (g_src_is_reg) {            /* loop the captured file */
                lseek(g_src_fd, 12, SEEK_SET);
                g_asmfill = 0;
            } else {                       /* FIFO writer departed */
                close(g_src_fd); g_src_fd = -1;
            }
            return;
        }
        return;                            /* EAGAIN / EINTR: nothing more now */
    }
}

/* ---- VGA TEXT MODE (mode 3) renderer ------------------------------------
 * FreeDOS/DOS write 80x25 char+attr cells to core-physical 0xB8000. kms-draw
 * only rasterized the mode-13h gfx fb (0xA0000), so in text mode the monitor
 * showed garbage. Render the text page with a real VGA 8x16 font + the 16-color
 * attribute palette, integer-scaled (2x = 1280x800) and centered in the window. */
#include "vga_font_8x16.h"
static const uint8_t *m_carveout = 0;   /* mmap'd carveout base (low 1 MiB) */
/* standard VGA 16-color palette as RGB565 */
static uint16_t g_vga16[16];
static void vga16_init(void) {
    static const uint8_t p[16][3] = {
        {0,0,0},{0,0,170},{0,170,0},{0,170,170},{170,0,0},{170,0,170},{170,85,0},{170,170,170},
        {85,85,85},{85,85,255},{85,255,85},{85,255,255},{255,85,85},{255,85,255},{255,255,85},{255,255,255}};
    for (int i=0;i<16;i++) g_vga16[i]=rgb565(p[i][0],p[i][1],p[i][2]);
}
/* true if the core is in a text mode (BDA video mode @0x449 != 0x13 gfx). */
static int vga_is_text(void) { return m_carveout && m_carveout[0x449] != 0x13; }
/* VGA text "special attributes": bit7=blink (default mode; the char's glyph
 * is hidden on the off phase). When the attribute controller has blink DISABLED
 * (mode-control bit set, exposed by ven_soc_app at BDA 0x465 bit5=0 -> 16 bg
 * colors), bit7 becomes the bg-intensity bit instead. Plus the hardware cursor:
 * a blinking block/underline at the BDA cursor cell, shaped by BDA 0x460/0x461. */
static unsigned g_text_blink_ctr = 0;
static void render_vga_text(int ox, int oy) {
    const uint8_t *txt = m_carveout + 0xB8000;
    int cols = m_carveout[0x44a]; if (cols < 1 || cols > 132) cols = 80;
    int rows = 25;
    int sc = CB_W/(cols*8); if (CB_H/(rows*16) < sc) sc = CB_H/(rows*16); if (sc < 1) sc = 1;
    int tw = cols*8*sc, th = rows*16*sc;
    int x0 = ox + (CB_W - tw)/2, y0 = oy + (CB_H - th)/2;
    /* ~1.9 Hz blink at 60 fps (16 frames on / 16 off). Char-blink and the cursor
     * share the phase, matching real VGA (cursor ~ same rate). */
    int blink_on = ((g_text_blink_ctr++ >> 4) & 1) == 0;
    /* blink-enable: BDA 0x465 (CRTC mode-control shadow) bit5 set => blink mode;
     * default to blink-enabled if the byte is unset/zero. */
    uint8_t modectl = m_carveout[0x465];
    int blink_mode = (modectl == 0) ? 1 : ((modectl & 0x20) != 0);
    /* cursor: BDA 0x450=col,0x451=row ; shape 0x460=end,0x461=start scanline.
     * shape start bit5 (0x20) set => cursor hidden. */
    int ccol = m_carveout[0x450], crow = m_carveout[0x451];
    uint8_t cstart = m_carveout[0x461], cend = m_carveout[0x460];
    int cur_hidden = (cstart & 0x20) != 0;
    if (cend == 0 && cstart == 0) { cstart = 14; cend = 15; cur_hidden = 0; }  /* default underline */
    for (int dy=0; dy<CB_H; dy++) {                 /* clear window to black */
        uint16_t *r = g_fb + (size_t)(oy+dy)*g_stride_px + ox;
        for (int dx=0; dx<CB_W; dx++) r[dx] = 0;
    }
    for (int row=0; row<rows; row++) for (int col=0; col<cols; col++) {
        const uint8_t *cell = txt + ((size_t)row*cols + col)*2;
        uint8_t ch = cell[0], attr = cell[1];
        int fg_i = attr & 0x0f;
        int bg_i = blink_mode ? ((attr>>4) & 0x07) : ((attr>>4) & 0x0f);  /* 8 vs 16 bg */
        int blink = blink_mode && (attr & 0x80);
        uint16_t fg = g_vga16[fg_i], bg = g_vga16[bg_i];
        const uint8_t *gl = vga_font_8x16[ch];
        int is_cur = !cur_hidden && blink_on && row==crow && col==ccol;
        for (int gy=0; gy<16; gy++) {
            uint8_t bits = gl[gy];
            if (blink && !blink_on) bits = 0;                         /* blink: glyph -> bg */
            if (is_cur && gy >= cstart && gy <= cend) bits = 0xff;    /* cursor scanlines -> fg */
            int py = y0 + (row*16+gy)*sc;
            for (int gx=0; gx<8; gx++) {
                uint16_t c = (bits & (0x80>>gx)) ? fg : bg;
                int px = x0 + (col*8+gx)*sc;
                for (int sy=0; sy<sc; sy++) {
                    int Y = py+sy; if (Y<0 || Y>=SCREEN_H) continue;
                    uint16_t *r = g_fb + (size_t)Y*g_stride_px;
                    for (int sx=0; sx<sc; sx++) { int X=px+sx; if (X>=0 && X<SCREEN_W) r[X]=c; }
                }
            }
        }
    }
}

static void draw_quake(int ox, int oy)
{
    if (vga_is_text()) { render_vga_text(ox, oy); return; }   /* DOS text mode */
    if (!g_have_frame) {
        fill_rect(ox, oy, CB_W, CB_H, rgb565(8, 10, 16));
        draw_text(ox + CB_W / 2 - 180, oy + CB_H / 2 - 14,
                  "WAITING FOR QUAKE", 4, rgb565(120, 240, 255), 0, 0);
        return;
    }

    for (int dy = 0; dy < CB_H; dy++) {
        uint16_t *drow = g_fb + (size_t)(oy + dy) * g_stride_px + ox;
        int sry = g_rowmap[dy];
        if (sry < 0) {                          /* letterbox row -> black */
            for (int dx = 0; dx < CB_W; dx++) drow[dx] = 0;
            continue;
        }
        const uint8_t *srow = g_qpix + (size_t)sry * g_qw;
        for (int dx = 0; dx < CB_W; dx++) {
            int srx = g_colmap[dx];             /* pillarbox column -> black */
            drow[dx] = (srx < 0) ? 0 : g_qlut[srow[srx]];
        }
    }
}

/* The 256-entry palette currently in use (the active frame's VGA palette) as a
 * 16x16 swatch grid: index = row*16 + col, a 1px gap between cells. g_qlut is
 * already the RGB565 form of the live palette, so this mirrors exactly what the
 * Quake window is drawing with. */
static void draw_palette(int ox, int oy, int sw)
{
    for (int i = 0; i < 256; i++) {
        int cx = ox + (i & 15) * sw;
        int cy = oy + (i >> 4) * sw;
        uint16_t c = g_have_frame ? g_qlut[i] : rgb565(24, 24, 28);
        fill_rect(cx, cy, sw - 1, sw - 1, c);
    }
    /* enclosing frame */
    draw_rect_outline(ox - 2, oy - 2, 16 * sw + 3, 16 * sw + 3, 1,
                      rgb565(160, 160, 170));
}

static void draw_layout(int frame)
{
    uint16_t black   = rgb565(0, 0, 0);
    uint16_t white   = rgb565(255, 255, 255);
    uint16_t blue_bg = rgb565(12, 20, 44);
    uint16_t cyan    = rgb565(120, 240, 255);
    uint16_t green   = rgb565(80, 255, 120);
    uint16_t amber   = rgb565(255, 200, 80);

    fill_rect(0, 0, SCREEN_W, SCREEN_H, black);

    /* Left 1280x960 window: the live Quake framebuffer, nearest-neighbour
       scaled from 320x200 (fills the box -> Quake's intended 4:3 aspect). */
    draw_quake(LEFT_X, TOP_Y);
    draw_rect_outline(LEFT_X, TOP_Y, CB_W, CB_H, 4, white);

    /* Right 460x960 status panel. */
    fill_rect(TEXT_X, TEXT_Y, TEXT_W, TEXT_H, blue_bg);
    draw_rect_outline(TEXT_X, TEXT_Y, TEXT_W, TEXT_H, 4, white);

    draw_text(TEXT_X + 20, TEXT_Y + 18, "QUAKE ON VENTIUM", 2, cyan, blue_bg, 0);

    /* Top of the panel: the 256-colour VGA palette currently in use. */
    draw_text(TEXT_X + 20, TEXT_Y + 48, "VGA PALETTE", 2, white, blue_bg, 0);
    int pal_sw = 26;                                   /* 16 * 26 = 416 px */
    int pal_x  = TEXT_X + (TEXT_W - 16 * pal_sw) / 2;  /* centred (+22) */
    int pal_y  = TEXT_Y + 74;
    draw_palette(pal_x, pal_y, pal_sw);
    int below  = pal_y + 16 * pal_sw + 26;             /* just under the grid */

    /* Status block below the palette. */
    const char *status = g_have_frame ? "LIVE" :
                         (g_src_fd < 0 ? "NO SOURCE" : "WAITING");
    draw_text(TEXT_X + 20,  below, "STATUS", 2, white, blue_bg, 0);
    draw_text(TEXT_X + 140, below, status, 2,
              g_have_frame ? green : amber, blue_bg, 0);

    draw_text(TEXT_X + 20, below + 34,
              g_src_is_reg ? "FILE REPLAY" : "FIFO LIVE", 2, white, blue_bg, 0);
    draw_text(TEXT_X + 20, below + 62, "SRC 320x200 DST 1280x960", 2, white, blue_bg, 0);
    draw_text(TEXT_X + 20, below + 90, "FORMAT RGB565", 2, white, blue_bg, 0);

    char buf[64];
    snprintf(buf, sizeof(buf), "QFRAME %06lu", g_qframe);
    draw_text(TEXT_X + 20, TEXT_Y + TEXT_H - 110, buf, 3, green, blue_bg, 1);
    snprintf(buf, sizeof(buf), "VSYNC %06d", frame);
    draw_text(TEXT_X + 20, TEXT_Y + TEXT_H - 64, buf, 3, white, blue_bg, 1);
}

static void create_buffer(struct kms_buf *b, int w, int h)
{
    struct drm_mode_create_dumb creq;
    memset(&creq, 0, sizeof(creq));

    creq.width = w;
    creq.height = h;
    creq.bpp = 16;

    if (drmIoctl(drm_fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0)
        die("DRM_IOCTL_MODE_CREATE_DUMB");

    b->handle = creq.handle;
    b->pitch = creq.pitch;
    b->size = creq.size;

    uint32_t handles[4] = { b->handle, 0, 0, 0 };
    uint32_t pitches[4] = { b->pitch, 0, 0, 0 };
    uint32_t offsets[4] = { 0, 0, 0, 0 };

    if (drmModeAddFB2(drm_fd, w, h, DRM_FORMAT_RGB565,
                      handles, pitches, offsets, &b->fb_id, 0) < 0)
        die("drmModeAddFB2 RGB565");

    struct drm_mode_map_dumb mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.handle = b->handle;

    if (drmIoctl(drm_fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0)
        die("DRM_IOCTL_MODE_MAP_DUMB");

    b->pix = mmap(NULL, b->size, PROT_READ | PROT_WRITE,
                  MAP_SHARED, drm_fd, mreq.offset);

    if (b->pix == MAP_FAILED)
        die("mmap dumb buffer");
}

static void destroy_buffer(struct kms_buf *b)
{
    if (b->pix && b->pix != MAP_FAILED)
        munmap(b->pix, b->size);

    if (b->fb_id)
        drmModeRmFB(drm_fd, b->fb_id);

    if (b->handle) {
        struct drm_mode_destroy_dumb dreq;
        memset(&dreq, 0, sizeof(dreq));
        dreq.handle = b->handle;
        drmIoctl(drm_fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
    }
}

static void wait_for_flip(void)
{
    drmEventContext evctx;
    memset(&evctx, 0, sizeof(evctx));

    evctx.version = DRM_EVENT_CONTEXT_VERSION;
    evctx.page_flip_handler = page_flip_handler;

    while (page_flip_pending && running) {
        struct pollfd pfd;
        pfd.fd = drm_fd;
        pfd.events = POLLIN;
        pfd.revents = 0;

        int ret = poll(&pfd, 1, -1);
        if (ret < 0) {
            if (errno == EINTR)
                continue;
            die("poll");
        }

        if (pfd.revents & POLLIN) {
            if (drmHandleEvent(drm_fd, &evctx) < 0)
                die("drmHandleEvent");
        }
    }
}

/* --vga13: rebuild the latest frame straight from the core's live VGA RAM +
 * exported DAC (no P5Q1 stream). Used for DOS Quake / native mode-13h apps. */
static void poll_vga13(void)
{
    uint8_t dac[768];
    int fd = open(g_dac_path, O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, dac, 768);
        close(fd);
        if (n == 768)
            for (int i = 0; i < 256; i++)        /* DAC is 6-bit/channel -> <<2 */
                g_qlut[i] = rgb565(dac[i*3] << 2, dac[i*3+1] << 2, dac[i*3+2] << 2);
    }
    if (g_vga13_fb) {
        memcpy(g_qpix, g_vga13_fb, (size_t)QK_W * QK_H);
        g_have_frame = 1;
        g_qframe++;
    }
}

#ifndef KMSDRAW_NO_MAIN
int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--vga13")) g_vga13 = 1;       /* live mode-13h fb */
        else if (!strcmp(argv[i], "--dac") && i + 1 < argc) g_dac_path = argv[++i];
        else    g_src_path = argv[i];   /* P5Q1 source: .p5q file (replay) or FIFO */
    }
    if (g_vga13) {
        int mfd = open("/dev/mem", O_RDONLY | O_SYNC);
        if (mfd < 0) die("open /dev/mem (--vga13 needs root)");
        void *m = mmap(0, 0x100000, PROT_READ, MAP_SHARED, mfd, VEN_CARVEOUT_BASE);
        if (m == MAP_FAILED) die("mmap carveout");
        g_vga13_fb = (const uint8_t *)m + VGA13_FB_OFF;
        m_carveout = (const uint8_t *)m;   /* for the VGA text-mode renderer (0xB8000, BDA) */
        vga16_init();
        g_qw = QK_W; g_qh = QK_H; build_maps();
        fprintf(stderr, "kms-draw: --vga13 live mode-13h fb @ carveout+0x%lx, dac=%s\n",
                VGA13_FB_OFF, g_dac_path);
    }

    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGPIPE, SIG_IGN);   /* a departing FIFO producer must not kill us */

    fprintf(stderr, "kms-draw: quake source = %s\n", g_src_path);

    drm_fd = open(DEV_PATH, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0)
        die("open /dev/dri/card0");

    drmModeConnector *conn = drmModeGetConnector(drm_fd, conn_id);
    if (!conn)
        die("drmModeGetConnector");

    memset(&mode, 0, sizeof(mode));
    for (int i = 0; i < conn->count_modes; i++) {
        if (conn->modes[i].hdisplay == SCREEN_W &&
            conn->modes[i].vdisplay == SCREEN_H) {
            mode = conn->modes[i];
            break;
        }
    }

    if (!mode.clock) {
        fprintf(stderr, "1920x1080 mode not found on connector %u\n", conn_id);
        return 1;
    }

    create_buffer(&bufs[0], SCREEN_W, SCREEN_H);
    create_buffer(&bufs[1], SCREEN_W, SCREEN_H);

    int front = 0;
    int back = 1;
    int frame = 0;

    /* Initial front buffer. */
    if (g_vga13) poll_vga13(); else poll_quake_frames();
    g_fb = bufs[front].pix;
    g_stride_px = bufs[front].pitch / 2;
    draw_layout(frame++);

    if (drmModeSetCrtc(drm_fd, crtc_id, bufs[front].fb_id,
                       0, 0, &conn_id, 1, &mode) < 0)
        die("drmModeSetCrtc");

    printf("Running vsync-locked page-flip loop. Ctrl-C to exit.\n");

    while (running) {
        if (g_vga13) poll_vga13(); else poll_quake_frames();

        g_fb = bufs[back].pix;
        g_stride_px = bufs[back].pitch / 2;

        draw_layout(frame++);

        page_flip_pending = 1;

        if (drmModePageFlip(drm_fd, crtc_id, bufs[back].fb_id,
                            DRM_MODE_PAGE_FLIP_EVENT, NULL) < 0) {
            if (errno == EBUSY) {
                wait_for_flip();
                continue;
            }
            die("drmModePageFlip");
        }

        wait_for_flip();

        int tmp = front;
        front = back;
        back = tmp;
    }

    printf("\nExiting.\n");

    destroy_buffer(&bufs[0]);
    destroy_buffer(&bufs[1]);

    drmModeFreeConnector(conn);
    close(drm_fd);

    return 0;
}
#endif /* KMSDRAW_NO_MAIN */
