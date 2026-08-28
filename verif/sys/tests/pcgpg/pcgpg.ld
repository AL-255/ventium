/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium REVIEW1_Aug3 R2-C04 — linker script for the bare-metal
 * cross-privilege paged call-gate parameter-copy image. Identical layout strategy to
 * piretgp0/pcpl: a flat 64 KiB BIOS image, qemu maps it so the last byte is
 * at physical 0x000FFFFF, the reset vector is CS:EIP=F000:FFF0 (linear
 * 0x000FFFF0). Paging identity-maps the low 1 MiB, so the 0x000Fxxxx image
 * window, the GDT (0x500) / IDT (0x1000) / TSS (0x3000), the page tables
 * (0x10000/0x11000) and the stacks (0x70000 / 0x80000+0x81000 / 0x90000) are
 * all linear==physical.
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
