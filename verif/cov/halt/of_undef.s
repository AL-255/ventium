# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# HALT-arm coverage: 0F FF (undefined 0F opcode) -> 0F-group default d_unknown.
    .text
    .globl _start
_start:
    .byte 0x0f, 0xff
    hlt
