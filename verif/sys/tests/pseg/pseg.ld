/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.1 — linker script for the bare-metal SEGMENTATION-only image.
 *
 * Identical layout strategy to the M2S.0 pmode image: a flat 64 KiB BIOS image.
 * qemu-system-i386 -bios maps it so the last byte is at physical 0x000FFFFF and
 * the whole image is aliased at the top of the 32-bit space; the reset vector is
 * CS:EIP=F000:FFF0 (linear 0x000FFFF0).  So:
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) must land at linear 0x000FFFF0, i.e. image
 *     offset 0xFFF0
 *   - .text16 (the 16-bit entry) + the 32-bit body sit early in the image, all
 *     within the 0xF000 real-mode segment so `ljmp $0xF000, $off` reaches them.
 *
 * Every symbol gets a VMA in the 0x000Fxxxx window so the real-mode far-jump
 * target $_start16 resolves to a 16-bit segment-relative offset, and the
 * protected-mode flat (base 0) far-jump $0x08,$pm32_entry uses pm32_entry's full
 * 0x000Fxxxx linear address (correct: the image is aliased low, flat base 0).
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;   /* linear base of a 64 KiB -bios image */

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    /* segment-relative offset of the real-mode entry inside segment 0xF000,
     * computed at link time as an ABSOLUTE constant so the reset stub's hand
     * encoded far jump can use a 16-bit immediate that already fits. */
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

    /* discard everything else */
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
