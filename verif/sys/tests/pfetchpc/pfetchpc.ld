/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
ENTRY(_reset)
IMAGE_BASE = 0x000F0000;
SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    .text32 : {
        . = ALIGN(16);
        *(.text32) *(.text) *(.rodata*) *(.data*)
    }
    ASSERT(. < IMAGE_BASE + 0x8000, "kernel scaffolding overlaps user code")

    /* These are PHYSICAL BIOS addresses, not the paged user EIPs. */
    . = IMAGE_BASE + 0x8000;
    .user_first : { *(.user_first) }
    ASSERT(user_first == 0xF8000, "first-byte physical source changed")
    ASSERT(user_first_end - user_first == 5, "first-byte MOV extent changed")

    /* C7 /0 disp32 imm32: six bytes before the boundary, four after it. */
    . = IMAGE_BASE + 0x9FFA;
    .user_cross : { *(.user_cross) }
    ASSERT(user_cross == 0xF9FFA, "essential-byte crossing source changed")
    ASSERT(user_cross_end - user_cross == 10, "crossing MOV extent changed")
    ASSERT(user_cross_end == 0xFA004, "essential immediate is not on page two")

    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
