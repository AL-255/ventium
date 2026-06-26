/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — linker script for the bare-metal HARDWARE-TASK-SWITCH-INTO-V86 image.
 *
 * Flat 64 KiB BIOS image (same strategy as ptaskcpl / pv86).  qemu-system-i386
 * -bios maps it so the last byte is at physical 0x000FFFFF; the reset vector is
 * CS:EIP=F000:FFF0 (linear 0x000FFFF0).  So:
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) must land at linear 0x000FFFF0, image
 *     offset 0xFFF0
 *   - .text16 (the 16-bit entry) + the 32-bit body + the #GP monitor sit early in
 *     the image, all within the 0xF000 real-mode segment, all in flat code
 *     segments (base 0) so the IDT gate offset ($gp_handler) is a full 0x000Fxxxx
 *     linear address.
 *
 * The V86 task code (.text_v86) runs at linear 0x00020000 (segment 0x2000:0000 in
 * V86 sel<<4 addressing) so the V86 task runs with CS=0x2000 / offset 0.  Because
 * 0x00020000 is BELOW IMAGE_BASE, the bytes live HIGH in the BIOS image (their
 * LMA) and pm32_entry copies the blob to linear 0x00020000 before the task switch.
 *
 * NO paging (linear == physical); the GDT (0x500) / IDT (0x1000) / TSS (0x3000,
 * 0x4000) / V86 task (0x20000) / sentinel (0x25930) / stacks (0x88000 / 0x90000)
 * all live in low RAM, distinct from the 0x000Fxxxx image window.
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

    /* The V86 task body, assembled as 16-bit code, runs at linear 0x00020000
     * (V86 segment 0x2000, offset 0).  VMA at the RUN-TIME base; LMA kept HIGH
     * (right after .text32) so the bytes live in the 64 KiB image. */
    V86_RUN_BASE = 0x00020000;
    _v86_lma = . ;
    .text_v86 V86_RUN_BASE : AT (_v86_lma) {
        _v86_blob_start = . ;
        *(.text_v86)
        _v86_blob_end = . ;
    }
    _v86_blob_len = ABSOLUTE(_v86_blob_end - _v86_blob_start);
    . = _v86_lma + SIZEOF(.text_v86);

    . = IMAGE_BASE + 0xFFF0;
    /* Pin the reset stub's LOAD address (LMA) to image offset 0xFFF0 explicitly so
     * the preceding .text_v86 AT(_v86_lma) does not leave .reset with an
     * out-of-image LMA (which objcopy -O binary would truncate off). */
    .reset (IMAGE_BASE + 0xFFF0) : AT (IMAGE_BASE + 0xFFF0) {
        *(.reset)
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
