/* Copyright 2026 Ventium Contributors
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Linker script for Ventium's 64 KiB bare-metal BIOS-bootable Dhrystone 2.1
 * image:
 *   - Reset stub (.reset) lands at image offset 0xFFF0 (linear 0x000FFFF0).
 *   - 16-bit/early-32-bit bootstrap (.text16, .boot32) runs from 0x000F0000.
 *   - The 32-bit Dhrystone payload (.text, .rodata, .data) is stored at LMA
 *     _payload_lma inside the 64 KiB ROM image and copied before execution to
 *     VMA 0x00010000 in ordinary L1-cacheable low DRAM (matching z486's
 *     CODE_PHYS_BASE = 0x00010000).
 *   - .bss (including Arr_2_Glob[50][50]) lives in low DRAM immediately after
 *     .data (NOLOAD) and is zeroed by boot_bios.S before calling C code.
 */
ENTRY(_reset)

IMAGE_BASE   = 0x000F0000;
PAYLOAD_VMA  = 0x00010000;

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
        . = ALIGN(16);
        *(.boot32)
        . = ALIGN(16);
    }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    _payload_lma = ALIGN(16);

    .payload PAYLOAD_VMA : AT(_payload_lma) {
        _payload_vma_start = .;
        *(.text.entry)
        *(.text*)
        . = ALIGN(16);
        *(.rodata*)
        . = ALIGN(16);
        *(.data*)
        . = ALIGN(16);
        _payload_vma_end = .;
    }

    _payload_dwords = (_payload_vma_end - _payload_vma_start) >> 2;
    ASSERT((_payload_lma + (_payload_vma_end - _payload_vma_start)) <= (IMAGE_BASE + 0xFFE0),
           "Dhrystone payload overflows 64 KiB BIOS image")

    .bss _payload_vma_end (NOLOAD) : {
        . = ALIGN(16);
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    ASSERT(__bss_end <= 0x00068000, "Dhrystone BSS overlaps page-table/stack region")

    .reset (IMAGE_BASE + 0xFFF0) : AT(IMAGE_BASE + 0xFFF0) {
        *(.reset)
    }

    /DISCARD/ : {
        *(.note*)
        *(.comment*)
        *(.eh_frame*)
    }
}
