/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M8.1 — linker script for the bare-metal ON-DIE TIMER IRQ image.
 *
 * Same flat 64 KiB -bios layout as pintr/pmode/pseg: qemu-system-i386 -bios maps
 * the image so its last byte is at physical 0x000FFFFF; the reset vector is
 * CS:EIP=F000:FFF0 (linear 0x000FFFF0). So:
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) lands at linear 0x000FFFF0 (image off 0xFFF0)
 *   - .text16 (16-bit entry) + the 32-bit body + the IRQ0 handler sit early in
 *     the image, all within the 0xF000 real-mode segment, all in the flat 32-bit
 *     code segment (base 0) so the IDT gate offset ($irq0_handler) is a full
 *     0x000Fxxxx linear address.
 *
 * NO paging in pirqsoc, so handler/gate-target linear addrs are physical; the
 * IDT (0x1000) / GDT (0x500) / vars (0x2000) / stack (0x90000) live in low RAM,
 * distinct from the 0x000Fxxxx image window.
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
