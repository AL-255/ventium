# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_bit  --  BT/BTS/BTR/BTC (reg + imm8) and BSF/BSR
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -nostdlib -static -Wl,-Ttext=0x08048000
#
# Bucket: bit ops.
#   BT  0F A3 (reg) / 0F BA /4 ib (imm8)
#   BTS 0F AB (reg) / 0F BA /5 ib
#   BTR 0F B3 (reg) / 0F BA /6 ib
#   BTC 0F BB (reg) / 0F BA /7 ib
#   BSF 0F BC,  BSR 0F BD
#
# Semantics exercised:
#   * BT*  copy the selected bit into CF; BTS sets it, BTR clears it, BTC
#     complements it. For a REGISTER destination the bit index is taken
#     modulo the operand size (here mod 32), so indices > 31 wrap. For the
#     imm8 form the index is also masked mod 32 by the imm (we use imm in 0..7
#     and one >7 -> but for a register dest the imm is also taken mod 32).
#   * BT*  leave OF/SF/AF/PF UNDEFINED and ZF UNCHANGED; CF = selected bit.
#   * BSF/BSR: ZF defined (set iff src==0); dest = index of lowest/highest set
#     bit. We use ONLY nonzero sources so the destination is well-defined and
#     ZF=0; the src==0 case is omitted (dest undefined -> see report).
#
# EFLAGS undefined (comparator table must mask):
#   BT/BTS/BTR/BTC: OF,SF,AF,PF undefined (CF defined, ZF unchanged).
#   BSF/BSR:        CF,OF,SF,AF,PF undefined (ZF defined).
# Diff-clean iff the comparator masks those bits for bt*/bsf/bsr.
#
# To keep the "ZF unchanged" property of BT* trivially matched, each BT* is
# preceded (at sequence starts) by a defined-flag anchor; BT* never writes ZF,
# so as long as both models agree on the pre-state ZF the compare holds (it does,
# because the prior instruction's flags are fully defined).
# =============================================================================

    .text
    .globl  _start
_start:

    # =====================================================================
    # BT imm8 (0F BA /4 ib) -- test bits, CF = selected bit; dest unchanged
    # =====================================================================
    movl    $0x0000000a, %eax       # 0b1010: bits 1 and 3 set
    btl     $0, %eax                # bit0 = 0 -> CF=0; eax unchanged
    btl     $1, %eax                # bit1 = 1 -> CF=1
    btl     $3, %eax                # bit3 = 1 -> CF=1
    btl     $2, %eax                # bit2 = 0 -> CF=0

    movl    $0x80000000, %eax
    btl     $31, %eax               # bit31 = 1 -> CF=1

    # imm index taken mod 32 for register form: bit 32 -> bit 0
    movl    $0x00000001, %eax
    btl     $32, %eax               # 32 & 31 = 0 -> bit0 = 1 -> CF=1

    # =====================================================================
    # BT reg (0F A3) -- index in a register, taken mod 32 for reg dest
    # =====================================================================
    movl    $0x00010000, %eax       # bit16 set
    movl    $16, %ecx
    btl     %ecx, %eax              # bit16 = 1 -> CF=1
    movl    $48, %ecx               # 48 & 31 = 16 -> bit16 again
    btl     %ecx, %eax              # CF=1 (wrapped index)
    movl    $17, %ecx
    btl     %ecx, %eax              # bit17 = 0 -> CF=0

    # =====================================================================
    # BTS imm8 (0F BA /5) -- set selected bit, CF = old value
    # =====================================================================
    movl    $0x00000000, %eax
    btsl    $5, %eax                # set bit5: eax=0x20, CF=0 (was 0)
    btsl    $5, %eax                # bit5 already set: eax=0x20, CF=1
    btsl    $31, %eax               # set bit31: eax=0x80000020, CF=0

    # BTS reg
    movl    $0x00000000, %eax
    movl    $7, %edx
    btsl    %edx, %eax              # set bit7: eax=0x80, CF=0

    # =====================================================================
    # BTR imm8 (0F BA /6) -- clear selected bit, CF = old value
    # =====================================================================
    movl    $0xffffffff, %eax
    btrl    $0, %eax                # clear bit0: eax=0xfffffffe, CF=1
    btrl    $0, %eax                # already clear: eax=0xfffffffe, CF=0
    btrl    $31, %eax               # clear bit31: eax=0x7ffffffe, CF=1

    # BTR reg
    movl    $0xffffffff, %eax
    movl    $15, %ecx
    btrl    %ecx, %eax              # clear bit15: eax=0xffff7fff, CF=1

    # =====================================================================
    # BTC imm8 (0F BA /7) -- complement selected bit, CF = old value
    # =====================================================================
    movl    $0x00000000, %eax
    btcl    $10, %eax               # toggle bit10: eax=0x400, CF=0
    btcl    $10, %eax               # toggle back: eax=0, CF=1
    btcl    $31, %eax               # toggle bit31: eax=0x80000000, CF=0

    # BTC reg with wrapped index
    movl    $0x00000000, %eax
    movl    $33, %ecx               # 33 & 31 = 1 -> bit1
    btcl    %ecx, %eax              # toggle bit1: eax=0x2, CF=0

    # =====================================================================
    # BSF (0F BC) -- index of lowest set bit; nonzero sources only
    # =====================================================================
    movl    $0x00000001, %ecx
    bsfl    %ecx, %eax              # lowest set bit of 1 -> eax=0, ZF=0
    movl    $0x00000010, %ecx
    bsfl    %ecx, %eax              # lowest set bit of 0x10 -> eax=4
    movl    $0x80000000, %ecx
    bsfl    %ecx, %eax              # only bit31 set -> eax=31
    movl    $0xffff0000, %ecx
    bsfl    %ecx, %eax              # lowest set = bit16 -> eax=16

    # =====================================================================
    # BSR (0F BD) -- index of highest set bit; nonzero sources only
    # =====================================================================
    movl    $0x00000001, %ecx
    bsrl    %ecx, %eax              # highest set bit of 1 -> eax=0
    movl    $0x80000000, %ecx
    bsrl    %ecx, %eax              # highest set bit -> eax=31
    movl    $0x0000ffff, %ecx
    bsrl    %ecx, %eax              # highest set = bit15 -> eax=15
    movl    $0x12345678, %ecx
    bsrl    %ecx, %eax              # highest set = bit28 -> eax=28

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
