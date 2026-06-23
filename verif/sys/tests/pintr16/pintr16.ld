/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — linker script for the bare-metal 16-bit-PM INT/IRETW image.
 * Same flat 64 KiB -bios layout as pintr.ld; the extra .text16pm section holds
 * the 16-bit-protected-mode phase + handler (it links into the flat 0xF0000
 * window like the rest, since the 16-bit code segment 0x18 is base 0). */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    /* 16-bit-PM phase + handler offsets relative to the CODE16 segment base
     * (0x000F0000 == IMAGE_BASE), used by the 16-bit IDT gate + far-jumps. */
    _pm16_off = ABSOLUTE(pm16_entry - IMAGE_BASE);
    _h40_off  = ABSOLUTE(int40_handler16 - IMAGE_BASE);

    .text32 : {
        . = ALIGN(16);
        *(.text32)
        *(.text16pm)
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
