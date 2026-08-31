/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* A 64 KiB BIOS image.  The relocated client body remains in the image at
 * link time, then the 16-bit bootstrap copies it to physical 0x80000. */
ENTRY(_reset)

IMAGE_BASE = 0x000f0000;

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : { *(.text16) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);

    .client32 : {
        . = ALIGN(16);
        *(.client32)
        *(.text)
        *(.rodata*)
        *(.data*)
    }
    _pm32_payload_off = ABSOLUTE(pm32_payload - IMAGE_BASE);

    . = IMAGE_BASE + 0xfff0;
    .reset : { *(.reset) }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
