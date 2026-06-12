// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/fb_vnc.c — minimal RFB 3.3 server for the Ventium mode-13h
// framebuffer (F3/F4 "the screen reaches a VNC client").
//
// Dependency-free (no libvncserver): a single-client TCP server on :5900 that
// speaks RFB 003.003 with security type None and ONLY Raw encoding. The frame
// source is the core's VGA VRAM window inside the PS-DDR carveout: core-physical
// 0xA0000 lands at carveout+0xA0000 (the carveout is the core's whole x86
// physical space, fpga/KV260_SOC_DESIGN.md — NB the deployed bitstream must be
// built with REMAP_BASE=0x4000_0000 for this to hold on real DDR). Mode 13h:
// 320x200, 1 byte/pixel, palettized.
//
// Palette: if ven_soc_app --dos is running it exports the live VGA DAC (the
// guest's writes to 0x3C8/0x3C9, served by the sw/ps_periph/ven_vgaregs.c model)
// to /dev/shm/ven_vga_dac (768 bytes, 6-bit R,G,B per entry); we re-read it
// every frame. Otherwise a built-in approximation of the IBM VGA default
// palette is used (entries 0-31 exact: EGA colors + gray ramp; the 32-247 hue
// cube is the standard 3-value x 3-saturation x 24-hue construction).
//
// Frame pacing: updates are only sent in response to FramebufferUpdateRequest
// (per RFB), throttled to --fps (default 10).
//
// Usage (run as root on the Kria, needs /dev/mem):
//   ven_fb_vnc [--port 5900] [--fps 10] [--dac /dev/shm/ven_vga_dac]
//
// NOTE: structurally verified + compile-tested only — no board is attached, so
// this has never served a real client from real PL-written DDR.

#define _POSIX_C_SOURCE 200809L   // clock_gettime under -std=c11

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include "ven_soc_regs.h"

#define FB_W      320
#define FB_H      200
#define FB_BYTES  (FB_W * FB_H)
#define FB_OFF    0x000A0000UL          // mode-13h VRAM, core-physical

static volatile const uint8_t *g_fb;    // mmap'd carveout + 0xA0000
static uint8_t  g_pal[768];             // 8-bit R,G,B per entry
static uint32_t g_lut[256];             // palette -> client pixel value
static const char *g_dac_path = "/dev/shm/ven_vga_dac";

// ---- client pixel format (RFB SetPixelFormat) -------------------------------
typedef struct {
    uint8_t  bpp, depth, big_endian, true_colour;
    uint16_t rmax, gmax, bmax;
    uint8_t  rsh, gsh, bsh;
} pixfmt_t;

static pixfmt_t g_pf;   // current client format (starts at our ServerInit format)

static void pf_default(pixfmt_t* p) {
    p->bpp = 32; p->depth = 24; p->big_endian = 0; p->true_colour = 1;
    p->rmax = 255; p->gmax = 255; p->bmax = 255;
    p->rsh = 16; p->gsh = 8; p->bsh = 0;
}

// ---- default VGA palette (used until the live DAC file appears) -------------
static const uint8_t EGA16[16][3] = {   // 6-bit DAC values (exact)
    { 0, 0, 0},{ 0, 0,42},{ 0,42, 0},{ 0,42,42},{42, 0, 0},{42, 0,42},{42,21, 0},{42,42,42},
    {21,21,21},{21,21,63},{21,63,21},{21,63,63},{63,21,21},{63,21,63},{63,63,21},{63,63,63}
};
static const uint8_t GRAY16[16] = {     // 6-bit gray ramp (exact)
    0, 5, 8, 11, 14, 17, 20, 24, 28, 32, 36, 40, 45, 50, 56, 63
};

static uint8_t exp6(uint8_t v6) { return (uint8_t)((v6 << 2) | (v6 >> 4)); }

static void build_default_palette(void) {
    int i, vg, sg;
    int p = 0;
    for (i = 0; i < 16; i++) {          // 0-15: EGA colors
        g_pal[p++] = exp6(EGA16[i][0]);
        g_pal[p++] = exp6(EGA16[i][1]);
        g_pal[p++] = exp6(EGA16[i][2]);
    }
    for (i = 0; i < 16; i++) {          // 16-31: gray ramp
        g_pal[p++] = exp6(GRAY16[i]);
        g_pal[p++] = exp6(GRAY16[i]);
        g_pal[p++] = exp6(GRAY16[i]);
    }
    // 32-247: 3 value groups (peak 63/28/16) x 3 saturation floors x 24-hue
    // wheel — the standard IBM construction (approximate rounding; any real
    // mode-13h program reloads the DAC, which we then serve live instead).
    {
        static const int peak[3] = {63, 28, 16};
        for (vg = 0; vg < 3; vg++) {
            int P = peak[vg];
            int flo[3];
            flo[0] = 0; flo[1] = (P + 1) / 2; flo[2] = (P * 5 + 3) / 7;
            for (sg = 0; sg < 3; sg++) {
                int m = flo[sg];
                int q1 = m + (int)(((P - m) * 1 + 2) / 4);
                int q2 = m + (int)(((P - m) * 2) / 4);
                int q3 = m + (int)(((P - m) * 3) / 4);
                // 24-entry hue wheel: B -> M -> R -> Y -> G -> C -> B
                int wheel[24][3];
                int k;
                static const int seq[24][3] = {
                    // indices into {m, q1, q2, q3, P} per channel (r,g,b)
                    {0,0,4},{1,0,4},{2,0,4},{3,0,4}, {4,0,4},{4,0,3},{4,0,2},{4,0,1},
                    {4,0,0},{4,1,0},{4,2,0},{4,3,0}, {4,4,0},{3,4,0},{2,4,0},{1,4,0},
                    {0,4,0},{0,4,1},{0,4,2},{0,4,3}, {0,4,4},{0,3,4},{0,2,4},{0,1,4}
                };
                int lvl[5];
                lvl[0] = m; lvl[1] = q1; lvl[2] = q2; lvl[3] = q3; lvl[4] = P;
                for (k = 0; k < 24; k++) {
                    wheel[k][0] = lvl[seq[k][0]];
                    wheel[k][1] = lvl[seq[k][1]];
                    wheel[k][2] = lvl[seq[k][2]];
                }
                for (k = 0; k < 24; k++) {
                    g_pal[p++] = exp6((uint8_t)wheel[k][0]);
                    g_pal[p++] = exp6((uint8_t)wheel[k][1]);
                    g_pal[p++] = exp6((uint8_t)wheel[k][2]);
                }
            }
        }
    }
    while (p < 768) g_pal[p++] = 0;     // 248-255: black
}

// re-read the live DAC export if present (768 bytes of 6-bit values).
static void refresh_palette(void) {
    uint8_t raw[768];
    int i;
    int fd = open(g_dac_path, O_RDONLY);
    if (fd >= 0) {
        ssize_t r = read(fd, raw, sizeof(raw));
        close(fd);
        if (r == (ssize_t)sizeof(raw))
            for (i = 0; i < 768; i++) g_pal[i] = exp6((uint8_t)(raw[i] & 0x3F));
    }
    // rebuild the index -> client-pixel LUT
    for (i = 0; i < 256; i++) {
        uint32_t r8 = g_pal[i * 3 + 0], g8 = g_pal[i * 3 + 1], b8 = g_pal[i * 3 + 2];
        uint32_t pr = (r8 * g_pf.rmax + 127) / 255;
        uint32_t pg = (g8 * g_pf.gmax + 127) / 255;
        uint32_t pb = (b8 * g_pf.bmax + 127) / 255;
        g_lut[i] = (pr << g_pf.rsh) | (pg << g_pf.gsh) | (pb << g_pf.bsh);
    }
}

// ---- socket helpers ----------------------------------------------------------
static int wr_all(int fd, const void* buf, size_t n) {
    const uint8_t* b = (const uint8_t*)buf;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return -1; }
        b += r; n -= (size_t)r;
    }
    return 0;
}
static int rd_all(int fd, void* buf, size_t n) {
    uint8_t* b = (uint8_t*)buf;
    while (n) {
        ssize_t r = read(fd, b, n);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return -1; }
        b += r; n -= (size_t)r;
    }
    return 0;
}
static void put16(uint8_t* p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void put32(uint8_t* p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
static uint16_t get16(const uint8_t* p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t get32(const uint8_t* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)(ts.tv_nsec / 1000000);
}

// ---- one full-frame Raw FramebufferUpdate ------------------------------------
static int send_frame(int fd) {
    static uint8_t out[16 + FB_BYTES * 4];
    uint8_t fb[FB_BYTES];
    int bypp = g_pf.bpp / 8;
    size_t n = 0;
    int i, b;

    refresh_palette();
    memcpy(fb, (const void*)g_fb, FB_BYTES);      // snapshot the live VRAM

    out[n++] = 0;                                  // FramebufferUpdate
    out[n++] = 0;                                  // pad
    put16(out + n, 1); n += 2;                     // 1 rectangle
    put16(out + n, 0); n += 2;                     // x
    put16(out + n, 0); n += 2;                     // y
    put16(out + n, FB_W); n += 2;
    put16(out + n, FB_H); n += 2;
    put32(out + n, 0); n += 4;                     // encoding 0 = Raw

    for (i = 0; i < FB_BYTES; i++) {
        uint32_t px = g_lut[fb[i]];
        if (g_pf.big_endian)
            for (b = bypp - 1; b >= 0; b--) out[n++] = (uint8_t)(px >> (8 * b));
        else
            for (b = 0; b < bypp; b++)      out[n++] = (uint8_t)(px >> (8 * b));
    }
    return wr_all(fd, out, n);
}

// ---- per-client session -------------------------------------------------------
static int serve_client(int fd, int fps) {
    uint8_t buf[256];
    uint64_t last_frame = 0;
    int update_pending = 0;
    const uint64_t frame_ms = (fps > 0) ? (1000ull / (unsigned)fps) : 100;

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    // ---- RFB 3.3 handshake ----
    if (wr_all(fd, "RFB 003.003\n", 12)) return -1;
    if (rd_all(fd, buf, 12)) return -1;            // client version (any 3.x ok)
    put32(buf, 1);                                 // security: 1 = None
    if (wr_all(fd, buf, 4)) return -1;
    if (rd_all(fd, buf, 1)) return -1;             // ClientInit (shared flag)

    // ---- ServerInit ----
    pf_default(&g_pf);
    {
        uint8_t si[24 + 7];
        memset(si, 0, sizeof(si));
        put16(si + 0, FB_W);
        put16(si + 2, FB_H);
        si[4] = g_pf.bpp; si[5] = g_pf.depth;
        si[6] = g_pf.big_endian; si[7] = g_pf.true_colour;
        put16(si + 8,  g_pf.rmax); put16(si + 10, g_pf.gmax); put16(si + 12, g_pf.bmax);
        si[14] = g_pf.rsh; si[15] = g_pf.gsh; si[16] = g_pf.bsh;
        put32(si + 20, 7);
        memcpy(si + 24, "ventium", 7);
        if (wr_all(fd, si, sizeof(si))) return -1;
    }
    refresh_palette();

    // ---- message loop ----
    for (;;) {
        fd_set rf;
        struct timeval tv;
        int r;
        FD_ZERO(&rf);
        FD_SET(fd, &rf);
        tv.tv_sec = 0; tv.tv_usec = 20000;         // 20 ms tick
        r = select(fd + 1, &rf, 0, 0, &tv);
        if (r < 0) { if (errno == EINTR) continue; return -1; }

        if (r > 0 && FD_ISSET(fd, &rf)) {
            if (rd_all(fd, buf, 1)) return 0;      // client gone
            switch (buf[0]) {
                case 0:                            // SetPixelFormat
                    if (rd_all(fd, buf, 3 + 16)) return 0;
                    g_pf.bpp = buf[3]; g_pf.depth = buf[4];
                    g_pf.big_endian = buf[5]; g_pf.true_colour = buf[6];
                    g_pf.rmax = get16(buf + 7); g_pf.gmax = get16(buf + 9);
                    g_pf.bmax = get16(buf + 11);
                    g_pf.rsh = buf[13]; g_pf.gsh = buf[14]; g_pf.bsh = buf[15];
                    if (!g_pf.true_colour ||
                        (g_pf.bpp != 8 && g_pf.bpp != 16 && g_pf.bpp != 32)) {
                        fprintf(stderr, "fb_vnc: unsupported pixel format "
                                "(bpp=%u tc=%u) — keeping 32bpp truecolour\n",
                                g_pf.bpp, g_pf.true_colour);
                        pf_default(&g_pf);
                    }
                    refresh_palette();
                    break;
                case 2: {                          // SetEncodings (ignored: Raw only)
                    uint16_t cnt;
                    if (rd_all(fd, buf, 3)) return 0;
                    cnt = get16(buf + 1);
                    while (cnt--) if (rd_all(fd, buf, 4)) return 0;
                    break;
                }
                case 3:                            // FramebufferUpdateRequest
                    if (rd_all(fd, buf, 9)) return 0;
                    update_pending = 1;
                    break;
                case 4:                            // KeyEvent (keyboard is USB HID)
                    if (rd_all(fd, buf, 7)) return 0;
                    break;
                case 5:                            // PointerEvent
                    if (rd_all(fd, buf, 5)) return 0;
                    break;
                case 6: {                          // ClientCutText
                    uint32_t len;
                    if (rd_all(fd, buf, 7)) return 0;
                    len = get32(buf + 3);
                    while (len) {
                        size_t c = len > sizeof(buf) ? sizeof(buf) : len;
                        if (rd_all(fd, buf, c)) return 0;
                        len -= (uint32_t)c;
                    }
                    break;
                }
                default:
                    fprintf(stderr, "fb_vnc: unknown client msg %u\n", buf[0]);
                    return 0;
            }
        }

        if (update_pending && (now_ms() - last_frame) >= frame_ms) {
            if (send_frame(fd)) return 0;
            last_frame = now_ms();
            update_pending = 0;
        }
    }
}

int main(int argc, char** argv) {
    int port = 5900, fps = 10;
    int i, sfd, mfd;
    struct sockaddr_in sa;
    void* map;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dac") && i + 1 < argc) g_dac_path = argv[++i];
        else { fprintf(stderr, "usage: %s [--port N] [--fps N] [--dac path]\n", argv[0]); return 2; }
    }

    mfd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (mfd < 0) { perror("/dev/mem"); return 1; }
    // map 1 MiB of the carveout (covers core-physical 0..0xFFFFF incl. the VRAM)
    map = mmap(0, 0x100000, PROT_READ, MAP_SHARED, mfd, VEN_CARVEOUT_BASE);
    if (map == MAP_FAILED) { perror("mmap carveout"); return 1; }
    g_fb = (volatile const uint8_t*)map + FB_OFF;

    build_default_palette();

    sfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sfd < 0) { perror("socket"); return 1; }
    i = 1;
    setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &i, sizeof(i));
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons((uint16_t)port);
    if (bind(sfd, (struct sockaddr*)&sa, sizeof(sa)) < 0) { perror("bind"); return 1; }
    if (listen(sfd, 1) < 0) { perror("listen"); return 1; }
    fprintf(stderr, "fb_vnc: RFB 3.3 raw server on :%d, %d fps, fb=carveout+0x%lx "
            "(mode 13h 320x200), dac=%s\n", port, fps, (unsigned long)FB_OFF, g_dac_path);

    for (;;) {                                     // one client at a time
        int cfd = accept(sfd, 0, 0);
        if (cfd < 0) { if (errno == EINTR) continue; perror("accept"); return 1; }
        fprintf(stderr, "fb_vnc: client connected\n");
        serve_client(cfd, fps);
        close(cfd);
        fprintf(stderr, "fb_vnc: client disconnected\n");
    }
}
