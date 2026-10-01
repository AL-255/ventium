# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Memory BT/BTS/BTR/BTC register offsets are signed BIT-STRING offsets,
# not register-style modulo offsets. No OS, snapshot or Win95 dependency.
# Immediate forms below are raw bytes so GAS cannot fold a large immediate
# into the displacement and accidentally conceal an RTL immediate-form bug.
# Address-size wrapping and precise faults are covered by sys/tests/pbitmem.

    .text
    .globl _start
_start:
    # First retirement fixes ESP in both producers; do not inherit Linux's
    # loader-dependent stack. Seed all GPRs and defined flags before the cases.
    movl $stack_top, %esp
    movl $0, %eax
    movl $0, %ecx
    movl $0, %edx
    movl $0, %ebx
    movl $0, %ebp
    movl $0, %esi
    movl $0, %edi
    pushl $0x202
    popfl

    # The exact pair-of-ports shape motivating the regression: indices
    # 32/33 and 160/161 address bytes base+4 and base+20, not base+0.
    movl $32, %edx
    btsl %edx, bits32
    jc fail
    movl $33, %edx
    btsl %edx, bits32
    jc fail
    movl $160, %edx
    btsl %edx, bits32
    jc fail
    movl $161, %edx
    btsl %edx, bits32
    jc fail
    cmpl $0, bits32
    jne fail
    cmpl $3, bits32+4
    jne fail
    cmpl $3, bits32+20
    jne fail

    # Positive op32 offsets and defined CF for all four operations.
    movl $40, %edx
    btl %edx, bits32
    jc fail
    btsl %edx, bits32
    jc fail
    btl %edx, bits32
    jnc fail
    btrl %edx, bits32
    jnc fail
    cmpl $3, bits32+4
    jne fail
    movl $63, %edx
    btcl %edx, bits32
    jc fail
    cmpl $0x80000003, bits32+4
    jne fail
    btcl %edx, bits32
    jnc fail
    cmpl $3, bits32+4
    jne fail

    # Signed negative op32 indices use arithmetic, not logical, shifts.
    movl $-1, %edx
    btl %edx, bits32
    jc fail
    btsl %edx, bits32
    jc fail
    btl %edx, bits32
    jnc fail
    cmpl $0x80000000, bits32-4
    jne fail
    btrl %edx, bits32
    jnc fail
    btcl %edx, bits32
    jc fail
    btcl %edx, bits32
    jnc fail
    cmpl $0, bits32-4
    jne fail
    movl $-33, %edx
    btsl %edx, bits32
    jc fail
    cmpl $0x80000000, bits32-8
    jne fail
    cmpl $0, bits32
    jne fail

    # op16 uses SIGNED low16 index; stale high16 must not affect the EA.
    movl $0x98760010, %edx
    btsw %dx, bits16
    jc fail
    movl $0x87650011, %edx
    btsw %dx, bits16
    jc fail
    cmpw $0, bits16
    jne fail
    cmpw $3, bits16+2
    jne fail
    movl $0x1234FFFF, %edx
    btw %dx, bits16
    jc fail
    btsw %dx, bits16
    jc fail
    btw %dx, bits16
    jnc fail
    cmpw $0x8000, bits16-2
    jne fail
    btrw %dx, bits16
    jnc fail
    btcw %dx, bits16
    jc fail
    btcw %dx, bits16
    jnc fail
    cmpw $0, bits16-2
    jne fail
    movl $0x5678FFEF, %edx         # low16 -17 => previous-previous word
    btsw %dx, bits16
    jc fail
    cmpw $0x8000, bits16-4
    jne fail
    cmpw $0, bits16
    jne fail

    # Memory immediate A0h remains modulo32; /4..7 must not adjust EA.
    movl $bits32, %esi
    .byte 0x0F,0xBA,0x2E,0xA0      # BTS dword [ESI], imm8 A0h
    jc fail
    .byte 0x0F,0xBA,0x26,0xA0      # BT
    jnc fail
    .byte 0x0F,0xBA,0x36,0xA0      # BTR
    jnc fail
    .byte 0x0F,0xBA,0x3E,0xA0      # BTC
    jc fail
    .byte 0x0F,0xBA,0x3E,0xA0
    jnc fail
    cmpl $0, bits32
    jne fail
    cmpl $3, bits32+4
    jne fail
    cmpl $3, bits32+20
    jne fail
    movl $bits16, %esi
    .byte 0x66,0x0F,0xBA,0x2E,0x20 # BTS word [ESI], imm8 20h => bit0
    jc fail
    cmpw $1, bits16
    jne fail
    cmpw $3, bits16+2
    jne fail

    # Register destinations remain modulo-width with high-half preservation.
    movl $0xDEAD0001, %eax
    movl $0x12340011, %edx
    btsw %dx, %ax
    jc fail
    cmpl $0xDEAD0003, %eax
    jne fail
    movl $0x80000000, %eax
    movl $63, %edx
    btl %edx, %eax
    jnc fail

    movl $0x600DB173, %edi
    xorl %ebx, %ebx
    jmp finish
fail:
    movl $1, %ebx
finish:
    movl $1, %eax
    int $0x80

    .data
    .balign 4
    .long 0,0
bits32:
    .long 0,0,0,0,0,0,0
    .balign 2
    .word 0,0
bits16:
    .word 0,0,0,0
    .balign 16
    .space 256,0
stack_top:
