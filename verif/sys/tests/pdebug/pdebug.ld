/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.6 — linker script for the bare-metal DEBUG-REGISTER / #DB image.
 *
 * Identical layout strategy to the M2S.3 pfault / M2S.5 psmm images: a flat
 * 64 KiB BIOS image.  qemu-system-i386 -bios maps it so the last byte is at
 * physical 0x000FFFFF and the whole image is aliased at the top of the 32-bit
 * space; the reset vector is CS:EIP=F000:FFF0 (linear 0x000FFFF0).  So:
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) must land at linear 0x000FFFF0, i.e. image
 *     offset 0xFFF0
 *   - .text16 (the 16-bit entry) + the 32-bit body + the #DB handler sit early in
 *     the image, all within the 0xF000 real-mode segment so `ljmp $0xF000,$off`
 *     reaches them, and all in the flat 32-bit code segment (base 0) so the IDT
 *     gate offset ($db_handler) is a full 0x000Fxxxx linear address.
 *
 * NO paging in pdebug (CR0.PG stays 0) — debug registers / #DB are orthogonal to
 * paging and keeping it off shortens the single-stepped golden (like psmm).
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;   /* linear base of a 64 KiB -bios image */

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);

    .text32 : {
        . = ALIGN(16);
        *(.text32)
        *(.text)
        *(.rodata*)
        *(.data*)
    }

    . = IMAGE_BASE + 0xFFF0;
    .reset : {
        *(.reset)
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
