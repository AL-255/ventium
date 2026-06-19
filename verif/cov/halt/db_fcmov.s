# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# HALT-arm coverage: db_fcmov -> d_unknown -> S_HALT (decode_stages default arm).
    .text
    .globl _start
_start:
    .byte 0xdb, 0xc0
    hlt
