/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium REVIEW_Aug3 H-03 — linker script for the bare-metal IRET/RETF
 * error-code + outer-IRET segment-cleanup witness image. Identical layout
 * strategy to pcpl: a flat 64 KiB BIOS image, qemu maps it so the last byte
 * is at physical 0x000FFFFF, the reset vector is CS:EIP=F000:FFF0 (linear
 * 0x000FFFF0). No paging: the GDT (0x500) / IDT (0x1000) / markers (0x2000) /
 * the stacks (0x88000 / 0x90000) all live in low RAM.
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
