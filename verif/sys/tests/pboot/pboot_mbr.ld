/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M9 — linker for the BOOT SECTOR (pboot_mbr.bin), exactly 512 bytes.
 *
 * The firmware stub loads this at RAM 0x8000 and far-jmps to it (cs=0x08, flat
 * 32-bit). The boot-sector code is position-independent (absolute signature writes
 * + a relative hlt loop), so it is linked at origin 0 — this makes `objcopy -O
 * binary` emit exactly one 512-byte sector (linking at the 0x8000 run address would
 * make objcopy pad the 0..0x8000 gap with zeros, bloating the image). The last two
 * bytes are the boot signature 0x55 0xAA (SHORT(0xAA55) is little-endian) at offset
 * 510, so the binary is exactly one sector that drops onto disk LBA0.
 */
ENTRY(_boot)

SECTIONS
{
    . = 0;

    .boot : {
        *(.boot)
        *(.text)
        *(.rodata*)
        *(.data*)
        . = 0x1FE;                      /* pad to offset 510 */
        SHORT(0xAA55);                  /* boot signature -> bytes 0x55, 0xAA */
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
