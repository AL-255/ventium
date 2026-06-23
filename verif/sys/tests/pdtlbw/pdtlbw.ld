/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium task #102 — linker script for the data-store-under-paging micro-TLB
 * regression image.  Flat 64 KiB BIOS image, identical layout strategy to
 * ppage.ld: the image is mapped so its last byte is at physical 0x000FFFFF; the
 * reset vector is CS:EIP=F000:FFF0 (linear 0x000FFFF0).  Code lives in the
 * 0x000Fxxxx window; the FULL identity map of [0,4MiB) (PT0) keeps EIP valid
 * across CR0.PG 0->1.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;

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
