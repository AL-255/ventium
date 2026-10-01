/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
ENTRY(_reset)
IMAGE_BASE = 0x000F0000;
SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }
    .text32 : { . = ALIGN(16); *(.text32) }
    .textcase : { . = ALIGN(16); *(.textcase) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    _pm32_off = ABSOLUTE(pm32_entry - IMAGE_BASE);
    _fault_fail_off = ABSOLUTE(fault_fail32 - IMAGE_BASE);
    _fault_gate_low = ABSOLUTE(_fault_fail_off | 0x00080000);
    _tested_entry_off = ABSOLUTE(tested_entry - IMAGE_BASE);
    _callee_off = ABSOLUTE(callee - IMAGE_BASE);
    _call_resume_off = ABSOLUTE(call_resume - IMAGE_BASE);
    _retf_resume_off = ABSOLUTE(retf_resume - IMAGE_BASE);
    expected_frame_ip = ABSOLUTE(operation_kind ? _retf_resume_off : _call_resume_off);
    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
