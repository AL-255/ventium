/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
ENTRY(_reset)
IMAGE_BASE = 0x000f0000;
SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    .text32 : { . = ALIGN(16); *(.text32) *(.text) *(.rodata*) *(.data*) }
    ASSERT(. <= IMAGE_BASE + 0xfff0, "RF completion probe overlaps reset vector")
    . = IMAGE_BASE + 0xfff0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
