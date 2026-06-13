/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Linker script for mairq.bin — same flat 64 KiB -bios layout as psocfw.ld.
 * Image base linear 0x000F0000; reset stub at 0x000FFFF0 (image off 0xFFF0);
 * .text16 (entry + IRQ0 handler) early in the image. irq0_off / _start16_off are
 * the in-segment (F000) offsets the code far-references.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : { *(.text16) }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    irq0_off     = ABSOLUTE(irq0 - IMAGE_BASE);

    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
