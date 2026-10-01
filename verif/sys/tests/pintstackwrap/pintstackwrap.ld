/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
ENTRY(_reset)
IMAGE_BASE = 0x000F0000;
SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }
    .text32 : { . = ALIGN(16); *(.text32) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    _pm32_off = ABSOLUTE(pm32_entry - IMAGE_BASE);
    _frame_handler_off = ABSOLUTE(frame_handler - IMAGE_BASE);
    _frame_gate_low = ABSOLUTE(_frame_handler_off | 0x00080000);
    _int3_end_off = ABSOLUTE(int3_end - IMAGE_BASE);
    expected_frame_ip = ABSOLUTE(_int3_end_off);
    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
