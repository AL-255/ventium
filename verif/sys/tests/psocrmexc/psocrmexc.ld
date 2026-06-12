/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium F3 — linker script for psocrmexc (real-mode #DE -bios firmware). Flat
 * 64 KiB -bios image: last byte at physical 0x000FFFFF, reset vector F000:FFF0.
 * Image base linear = 0x000F0000. handler/_start16 offsets are exported as
 * ABSOLUTE(label - IMAGE_BASE) so the 16-bit movw $imm forms get the in-segment
 * offset (CS=0xF000), not the full linear address (avoids R_386_16 truncation).
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : { *(.text16) }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    handler_off  = ABSOLUTE(handler  - IMAGE_BASE);

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
