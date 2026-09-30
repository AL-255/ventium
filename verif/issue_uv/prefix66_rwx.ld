/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
/* QEMU's actual-SMC fixture needs writable code and a page-congruent LOAD. */
ENTRY(_start)
PHDRS { fixture PT_LOAD FLAGS(7); }
SECTIONS {
  . = 0x08048000;
  .text : { *(.text) } :fixture
  .data : { *(.data) } :fixture
  .bss : { *(.bss) *(COMMON) } :fixture
}
