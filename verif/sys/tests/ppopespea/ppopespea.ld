/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
ENTRY(_reset)
IMAGE_BASE = 0xF0000;
SECTIONS {
  . = IMAGE_BASE;
  .text16 : { *(.text16) }
  .text32 : { . = ALIGN(16); *(.text32) }
  .textcase : { . = ALIGN(16); *(.textcase) }
  _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
  _pm32_off = ABSOLUTE(pm32_entry - IMAGE_BASE);
  _tested_entry_off = ABSOLUTE(tested_entry - IMAGE_BASE);
  _after_retf_off = ABSOLUTE(after_retf - IMAGE_BASE);
  _tested_pop_off = ABSOLUTE(tested_pop - IMAGE_BASE);
  _fault_gate_low = ABSOLUTE((fault_fail - IMAGE_BASE) | 0x80000);
  _precision_gate_low = ABSOLUTE((fault_handler - IMAGE_BASE) | 0x80000);
  . = IMAGE_BASE + 0xFFF0;
  .reset : { *(.reset) }
  /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
