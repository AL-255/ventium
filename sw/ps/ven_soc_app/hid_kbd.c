// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/hid_kbd.c — USB HID keyboard -> set-1 scancodes -> i8042 (F3).
//
// The board path of the keystroke injection the cosim TB does with sc1_of()
// (verif/tb/tb_soc.cpp): a real USB keyboard arrives via the Kria Ubuntu kernel
// as a Linux evdev device; we translate EV_KEY events into AT set-1 make/break
// sequences and feed the PS-placed i8042 C model (sw/ps_periph/ven_i8042.c).
//
// Translation is a happy historical accident: Linux KEY_* codes 1..88 for the
// main key block ARE the set-1 make codes (KEY_ESC=0x01, KEY_A=0x1E,
// KEY_SPACE=0x39, KEY_F11=0x57 ...), so the main map is the identity. The gray
// keys (arrows / Ins / Del / keypad-enter / right Ctrl/Alt / Win keys) are
// E0-prefixed, and Pause is the 6-byte E1 sequence. Break = make | 0x80 (with
// the same E0 prefix). Complete enough for a DOS shell + full typing; exotic
// keys (multimedia, Japanese) are dropped.
//
// NOTE: structurally verified only — no board is attached; the evdev path has
// not been exercised against real hardware.

#include "hid_kbd.h"

#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/input.h>

// the i8042 model's injection hook (sw/ps_periph/ven_i8042.c)
int ven_i8042_kbd_inject(ven_periph_t* p, uint8_t sc);

static int g_fd = -1;

// ---- scancode FIFO (the PS/2 device queue the C model deliberately omits) ---
#define KFIFO_SZ 1024
static uint8_t  g_fifo[KFIFO_SZ];
static unsigned g_head = 0, g_tail = 0;   // tail=write, head=read

static int fifo_n(void) { return (int)((g_tail - g_head) & (KFIFO_SZ - 1)); }
static int fifo_push(uint8_t b) {
    if (fifo_n() >= KFIFO_SZ - 1) return 0;     // overflow: drop (typist > guest)
    g_fifo[g_tail & (KFIFO_SZ - 1)] = b;
    g_tail++;
    return 1;
}

// ---- Linux keycode -> set-1 -------------------------------------------------
// 0 = unmapped. Codes 1..88 map to themselves except the gaps noted below.
static int keycode_is_plain(uint16_t code) {
    if (code >= 1 && code <= 83) return 1;      // ESC..KPDOT — identity block
    if (code == KEY_102ND)       return 0;      // 86 -> 0x56, but handled below
    if (code == KEY_F11 || code == KEY_F12) return 1;  // 87/88 = 0x57/0x58
    return 0;
}

// E0-prefixed gray keys: Linux keycode -> set-1 base code.
static uint8_t sc1_ext_of(uint16_t code) {
    switch (code) {
        case KEY_KPENTER:   return 0x1C;
        case KEY_RIGHTCTRL: return 0x1D;
        case KEY_KPSLASH:   return 0x35;
        case KEY_SYSRQ:     return 0x37;   // PrtScr (simplified: no E0 2A shift wrap)
        case KEY_RIGHTALT:  return 0x38;
        case KEY_HOME:      return 0x47;
        case KEY_UP:        return 0x48;
        case KEY_PAGEUP:    return 0x49;
        case KEY_LEFT:      return 0x4B;
        case KEY_RIGHT:     return 0x4D;
        case KEY_END:       return 0x4F;
        case KEY_DOWN:      return 0x50;
        case KEY_PAGEDOWN:  return 0x51;
        case KEY_INSERT:    return 0x52;
        case KEY_DELETE:    return 0x53;
        case KEY_LEFTMETA:  return 0x5B;
        case KEY_RIGHTMETA: return 0x5C;
        case KEY_COMPOSE:   return 0x5D;
        default:            return 0;
    }
}

// translate one EV_KEY event into FIFO bytes. value: 0=release 1=press 2=repeat.
static int queue_key(uint16_t code, int32_t value) {
    int n = 0;
    uint8_t sc;

    if (code == KEY_PAUSE) {
        // Pause/Break: make-only 6-byte sequence, no break code.
        if (value == 1) {
            n += fifo_push(0xE1); n += fifo_push(0x1D); n += fifo_push(0x45);
            n += fifo_push(0xE1); n += fifo_push(0x9D); n += fifo_push(0xC5);
        }
        return n;
    }
    if (keycode_is_plain(code)) {
        sc = (uint8_t)code;                      // identity block
    } else if (code == KEY_102ND) {
        sc = 0x56;                               // ISO key left of Z
    } else {
        uint8_t ext = sc1_ext_of(code);
        if (ext == 0) return 0;                  // unmapped: drop
        if (value == 2) {                        // typematic repeat = another make
            n += fifo_push(0xE0); n += fifo_push(ext);
            return n;
        }
        n += fifo_push(0xE0);
        n += fifo_push(value ? ext : (uint8_t)(ext | 0x80));
        return n;
    }
    if (value == 2) { n += fifo_push(sc); return n; }      // repeat = make
    n += fifo_push(value ? sc : (uint8_t)(sc | 0x80));
    return n;
}

// ---- evdev open / poll ------------------------------------------------------

static int looks_like_keyboard(int fd) {
    unsigned long evbits[(EV_MAX / (8 * sizeof(long))) + 1];
    unsigned long keybits[(KEY_MAX / (8 * sizeof(long))) + 1];
    memset(evbits, 0, sizeof(evbits));
    memset(keybits, 0, sizeof(keybits));
    if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits) < 0) return 0;
    if (!(evbits[EV_KEY / (8 * sizeof(long))] &
          (1ul << (EV_KEY % (8 * sizeof(long)))))) return 0;
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) < 0) return 0;
    // a keyboard has letters: require KEY_A and KEY_ENTER
    #define HASKEY(b, k) ((b)[(k) / (8 * sizeof(long))] & (1ul << ((k) % (8 * sizeof(long)))))
    return HASKEY(keybits, KEY_A) && HASKEY(keybits, KEY_ENTER);
    #undef HASKEY
}

int hid_kbd_open(const char* dev_path) {
    char path[64];
    char name[128];
    int i, fd;

    if (dev_path) {
        fd = open(dev_path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) { perror(dev_path); return -1; }
        g_fd = fd;
    } else {
        for (i = 0; i < 32; i++) {
            snprintf(path, sizeof(path), "/dev/input/event%d", i);
            fd = open(path, O_RDONLY | O_NONBLOCK);
            if (fd < 0) continue;
            if (looks_like_keyboard(fd)) { g_fd = fd; break; }
            close(fd);
        }
        if (g_fd < 0) {
            fprintf(stderr, "hid_kbd: no evdev keyboard found\n");
            return -1;
        }
    }
    // steal the keystrokes from the Linux console (best effort)
    if (ioctl(g_fd, EVIOCGRAB, (void*)1) < 0)
        fprintf(stderr, "hid_kbd: EVIOCGRAB failed (console will also see keys)\n");
    name[0] = 0;
    if (ioctl(g_fd, EVIOCGNAME(sizeof(name)), name) >= 0)
        fprintf(stderr, "hid_kbd: using \"%s\"\n", name);
    return 0;
}

void hid_kbd_close(void) {
    if (g_fd >= 0) { ioctl(g_fd, EVIOCGRAB, (void*)0); close(g_fd); g_fd = -1; }
}

int hid_kbd_poll(void) {
    struct input_event ev[32];
    ssize_t r;
    int i, queued = 0;
    if (g_fd < 0) return 0;
    for (;;) {
        r = read(g_fd, ev, sizeof(ev));
        if (r <= 0) break;                               // EAGAIN / no events
        for (i = 0; i < (int)(r / (ssize_t)sizeof(ev[0])); i++)
            if (ev[i].type == EV_KEY)
                queued += queue_key(ev[i].code, ev[i].value);
        if (r < (ssize_t)sizeof(ev)) break;
    }
    return queued;
}

int hid_kbd_pump(ven_periph_t* i8042) {
    uint8_t b;
    if (fifo_n() == 0) return 0;
    b = g_fifo[g_head & (KFIFO_SZ - 1)];
    if (!ven_i8042_kbd_inject(i8042, b)) return 0;       // OBF busy: retry later
    g_head++;
    return 1;
}
