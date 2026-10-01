/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
ENTRY(_reset)
IMAGE_BASE = 0x000F0000;
SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }
    .text32 : { . = ALIGN(16); *(.text32) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    _db_gate_low = ABSOLUTE((db_handler & 0xFFFF) | 0x00080000);
    _db_gate_high = ABSOLUTE((db_handler & 0xFFFF0000) | 0x00008F00);
    expected_frame_ip = ABSOLUTE(tested_end);
    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
