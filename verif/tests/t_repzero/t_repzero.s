# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# t_repzero -- REP string ops with ZERO count (the rep_active && cx==0 early-out
# branch in core_gpr_wb.svh:420 / core_store_useq). Covers BOTH count widths:
# ECX==0 (32-bit count) and CX==0 under a 0x67 address-size prefix (q_cnt16).
# All are user-mode-legal no-ops that retire cleanly (match QEMU).
    .text
    .globl _start
_start:
    xorl   %eax, %eax
    subl   $64, %esp
    leal   (%esp), %edi
    leal   (%esp), %esi
    # 32-bit count == 0  -> rep no-op
    xorl   %ecx, %ecx
    rep    stosb                 # ECX=0
    xorl   %ecx, %ecx
    rep    movsb                 # ECX=0
    xorl   %ecx, %ecx
    repe   cmpsb                 # ECX=0
    xorl   %ecx, %ecx
    repne  scasb                 # ECX=0
    # 16-bit count == 0 via addr-size prefix (q_cnt16): CX=0
    xorl   %ecx, %ecx
    addr16 rep stosb             # CX=0
    xorl   %ecx, %ecx
    addr16 rep movsb             # CX=0
    addl   $64, %esp
    movl   $1, %eax
    xorl   %ebx, %ebx
    int    $0x80
