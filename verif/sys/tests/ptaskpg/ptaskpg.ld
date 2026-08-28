/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium REVIEW_Aug3 C-02 — linker script for the PAGED hardware task switch
 * image. Same layout strategy as ptask/ppage: a flat 64 KiB BIOS image, qemu
 * maps it so the last byte is at physical 0x000FFFFF; reset vector F000:FFF0
 * (linear 0x000FFFF0). The code window [0xF0000,0x100000) is identity-mapped
 * once paging is on; every task-switch object lives in the non-identity
 * 4 MiB linear window (see ptaskpg.S for the full map).
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
