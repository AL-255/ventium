// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/hid_kbd.h — USB HID keyboard -> i8042 scancode feeder (F3).
//
// Opens a Linux evdev keyboard (/dev/input/event*), translates Linux keycodes
// into set-1 make/break scancode byte sequences (the language the PS-placed
// i8042 C model speaks to the guest), and pumps them into the model's output
// buffer one byte at a time (the model exposes a single OBF byte; the FIFO
// lives here). The caller (ven_soc_app --dos) then propagates the model's
// irq() level to IRQ1 of the ven_pic C model and on into the R_INTR seam.

#ifndef HID_KBD_H
#define HID_KBD_H

#include <stdint.h>
#include "../../ps_periph/ven_periph.h"

// Open the keyboard. dev_path = a specific /dev/input/eventN, or NULL to scan
// event0..31 for the first device advertising EV_KEY with letter keys. The
// device is EVIOCGRAB'd (keystrokes stop reaching the Linux console).
// Returns 0 on success, -1 if no keyboard was found.
int  hid_kbd_open(const char* dev_path);
void hid_kbd_close(void);

// Drain pending evdev events into the internal scancode FIFO (non-blocking).
// Returns the number of scancode BYTES queued by this call.
int hid_kbd_poll(void);

// Feed the FIFO head into the i8042 model if its output buffer is free
// (ven_i8042_kbd_inject). Returns 1 if a byte was injected, 0 otherwise.
int hid_kbd_pump(ven_periph_t* i8042);

#endif // HID_KBD_H
