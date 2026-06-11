/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M9 — linker script for the boot-firmware STUB (-bios image).
 *
 * Same flat 64 KiB -bios layout as pide.ld: qemu-system-i386 -bios maps the image
 * so its last byte is at physical 0x000FFFFF; the reset vector is CS:EIP=F000:FFF0
 * (linear 0x000FFFF0). So:
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) lands at linear 0x000FFFF0 (image off 0xFFF0)
 *   - .text16 (16-bit entry) + the 32-bit body sit early in the image.
 *
 * The stub is firmware: it boots real->protected, sets nIEN, reads the BOOT SECTOR
 * (disk LBA0) from the IDE primary master via synchronous PIO into RAM at 0x8000,
 * and far-jumps into it. The boot sector then executes from RAM. NO paging.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : { *(.text16) }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    far_target_off = ABSOLUTE(far_target - IMAGE_BASE);

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
