/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — linker script for the far-indirect CALL/JMP firmware (-bios image).
 *
 * Same flat 64 KiB -bios layout as psocfarcall.ld: qemu-system-i386 -bios maps the
 * image so its last byte is at physical 0x000FFFFF; the reset vector is
 * CS:EIP=F000:FFF0 (linear 0x000FFFF0). So:
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) lands at linear 0x000FFFF0 (image off 0xFFF0)
 *   - .text16 sits early in the image.
 *
 * The *_off symbols are segment-F000 offsets (sym - IMAGE_BASE) used as 16-bit
 * immediates / table entries / disp16 fields in the .S. NO paging, pure real mode.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : { *(.text16) }

    _start16_off  = ABSOLUTE(_start16  - IMAGE_BASE);
    calleeA_off   = ABSOLUTE(calleeA   - IMAGE_BASE);
    calleeB_off   = ABSOLUTE(calleeB   - IMAGE_BASE);
    calleeC_off   = ABSOLUTE(calleeC   - IMAGE_BASE);
    calleeD_off   = ABSOLUTE(calleeD   - IMAGE_BASE);
    calleeEo_off  = ABSOLUTE(calleeEo  - IMAGE_BASE);
    calleeEi_off  = ABSOLUTE(calleeEi  - IMAGE_BASE);
    landF_off     = ABSOLUTE(landF     - IMAGE_BASE);
    landG_off     = ABSOLUTE(landG     - IMAGE_BASE);
    done_off      = ABSOLUTE(done      - IMAGE_BASE);
    ftabA_off     = ABSOLUTE(ftabA     - IMAGE_BASE);
    ftabC_off     = ABSOLUTE(ftabC     - IMAGE_BASE);
    ftabD_off     = ABSOLUTE(ftabD     - IMAGE_BASE);
    ftabE_off     = ABSOLUTE(ftabE     - IMAGE_BASE);
    ftabEi_off    = ABSOLUTE(ftabEi    - IMAGE_BASE);
    jtabF_off     = ABSOLUTE(jtabF     - IMAGE_BASE);

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
