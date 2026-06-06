# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_leave16  --  0x66 (operand-size-16) LEAVE
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# Regression-locks the testable part of the adversarial-review finding that
# 16-bit-operand near CALL/RET/LEAVE ignored the 0x66 prefix. LEAVE is the
# cleanly-testable member (it does not change EIP), so we lock it here:
#
#   66 C9 (leavew): ESP <- EBP (full stack-address width); then pop a 16-bit BP
#   from [EBP], PRESERVING EBP[31:16], and adjust ESP by 2 (not 4).
#
# (The 16-bit near CALL/RET variants truncate EIP to 16 bits, which in a flat
# 32-bit program at 0x08048000 jumps to an unmapped low address and faults in
# BOTH models, so they cannot be regression-tested in a continuing program; the
# RTL now implements them faithfully — see rtl/core/intcore.sv and PROGRESS.md.)
#
# Build a frame so [EBP] holds a known dword, then issue 66 C9 and read back BP
# through a 32-bit move so a clobbered [31:16] or a wrong ESP delta is caught.
# No flags are affected by LEAVE; everything here is architecturally defined.
# =============================================================================

    .text
    .globl  _start
_start:
    movl    %esp, %ebp              # establish a base
    subl    $16, %esp               # carve a frame
    movl    %esp, %ebp              # EBP = frame base (a high address, hi16 != 0)
    movl    $0x1234ABCD, (%ebp)     # [EBP] = 0x1234ABCD ; 66-leave pops low16=0xABCD

    # ---- 66 C9 leavew : BP <- 0xABCD (preserve EBP[31:16]) ; ESP = EBP + 2 ---
    .byte 0x66
    leave                           # 66 C9

    # read back the now-modified EBP and ESP into witnesses
    movl    %ebp, %esi              # ESI = EBP after leave (hi16 = old frame hi)
    movl    %esp, %edi              # EDI = ESP after leave (= old EBP + 2)

    # ---- a second 16-bit LEAVE to confirm repeatability ---------------------
    movl    %esp, %ebp
    subl    $8, %esp
    movl    %esp, %ebp
    movl    $0xFEED5678, (%ebp)     # [EBP] = 0xFEED5678 ; pop low16 = 0x5678
    .byte 0x66
    leave                           # BP <- 0x5678 ; ESP = EBP + 2
    movl    %ebp, %edx              # EDX = EBP after second leave

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
