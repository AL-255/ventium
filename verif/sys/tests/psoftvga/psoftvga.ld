/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Linker script for the task #99 bare-metal soft-VGA INT 10h image.
 * Flat 64 KiB -bios image: base linear 0xF0000, reset stub at offset 0xFFF0.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : { *(.text16) }

    /* segment-relative offset of _start16 inside the 0xF000 real-mode segment */
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    /* segment-relative offset of the palette table (CS=0xF000) */
    _paltab_off  = ABSOLUTE(paltab - IMAGE_BASE);

    .text32 : {
        . = ALIGN(16);
        *(.text32)
        *(.text)
        *(.rodata*)
        *(.data*)
    }

    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
