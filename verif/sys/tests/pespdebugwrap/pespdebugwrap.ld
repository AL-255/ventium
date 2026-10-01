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
    _db_handler_off = ABSOLUTE(db_handler - IMAGE_BASE);
    _db_gate_low = ABSOLUTE(_db_handler_off | 0x00080000);
    _tested_end_off = ABSOLUTE(tested_end - IMAGE_BASE);
    expected_frame_ip = ABSOLUTE(_tested_end_off);
    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
