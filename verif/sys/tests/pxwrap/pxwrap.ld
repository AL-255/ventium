/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Linker script for the pxwrap wrapped-frame-probe regression image.
 * Same layout strategy as pxprobe: a flat 64 KiB BIOS image, the last byte
 * at physical 0x000FFFFF, reset CS:EIP = F000:FFF0 (linear 0x000FFFF0).
 * Paging identity-maps the low 1 MiB, so the image window, the GDT (0x6000)
 * / IDT (0x1000) / TSS (0x3000), the page tables (0x10000/0x11000/0x12000),
 * the CPL3 stack (0xF000), the clean CPL0 stack (0xA0000) and the wrapped
 * 16-bit stacks (0x80000..0x90FFF) are all linear==physical; the 4 GiB-wrap
 * window (0xFFFFE000/0xFFFFF000) is mapped to physical 0xB0000/0xC0000.
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

    /* The reset stub goes at the very end: image offset 0xFFF0 == linear FFFF0. */
    . = IMAGE_BASE + 0xFFF0;
    .reset : {
        *(.reset)
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
