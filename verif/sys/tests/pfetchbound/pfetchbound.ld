/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
ENTRY(_reset)
IMAGE_BASE = 0x000F0000;
SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    .text32 : { . = ALIGN(16); *(.text32) *(.text) *(.rodata*) *(.data*) }
    ASSERT(. < IMAGE_BASE + 0x8000, "kernel scaffolding overlaps user code")
    . = IMAGE_BASE + 0x8000;
    .user_safe : { *(.user_safe) }
    ASSERT(user_safe == 0xF8000, "safe CALL target moved")
    . = IMAGE_BASE + 0x9000;
    .user_test : { *(.user_test) }
    ASSERT(user_entry == user_entry_physical, "user boundary entry moved")
    ASSERT(user_entry_end <= 0xFA000, "page-one bytes crossed the boundary")
    . = IMAGE_BASE + 0xA000;
    .user_tail : { *(.user_tail) }
    ASSERT(user_tail == 0xFA000, "essential-byte second page moved")
    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
