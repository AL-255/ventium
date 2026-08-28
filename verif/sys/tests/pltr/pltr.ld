/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium REVIEW_Aug3 H-11b — linker script for the bare-metal LTR busy-bit +
 * null-LLDT image. Identical layout strategy to ptask: a flat 64 KiB BIOS
 * image, qemu maps it so the last byte is at physical 0x000FFFFF, the reset
 * vector is CS:EIP=F000:FFF0 (linear 0x000FFFF0). The GDT (0x500) / IDT
 * (0x1000) / markers (0x2000) / TSS (0x3000) / page tables (0x11000/0x12000) /
 * the CPL0 stack (0x90000) all live in low RAM, distinct from the 0x000Fxxxx
 * image window.
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
