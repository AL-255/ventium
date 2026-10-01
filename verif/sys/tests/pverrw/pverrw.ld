/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
ENTRY(_reset)
IMAGE_BASE = 0x000f0000;
SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    real_ud_handler_off = DEFINED(real_ud_handler) ? ABSOLUTE(real_ud_handler - IMAGE_BASE) : 0;
    real_r_off = DEFINED(real_r) ? ABSOLUTE(real_r - IMAGE_BASE) : 0;
    real_w66_off = DEFINED(real_w66) ? ABSOLUTE(real_w66 - IMAGE_BASE) : 0;
    real_mem_r_off = DEFINED(real_mem_r) ? ABSOLUTE(real_mem_r - IMAGE_BASE) : 0;
    real_mem_w67_off = DEFINED(real_mem_w67) ? ABSOLUTE(real_mem_w67 - IMAGE_BASE) : 0;
    pm16_entry_off = DEFINED(pm16_entry) ? ABSOLUTE(pm16_entry - IMAGE_BASE) : 0;
    .text32 : { . = ALIGN(16); *(.text32) *(.text) *(.rodata*) *(.data*) }
    ASSERT(. <= IMAGE_BASE + 0xfff0, "fixture overlaps reset vector")
    . = IMAGE_BASE + 0xfff0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) *(.bss) }
}
