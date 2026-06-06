# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M4 regression: t_adcpair  --  ADC/SBB carry-chain correctness
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# Regression-locks the M4 adversarial-review HIGH finding: in the dual-issue
# fast path, ADC (opcode-group op2) and SBB (op3) were decoded with
# pairs_second=1, so they could issue into the V pipe. Two defects followed:
#   (1) PAIRING MISLABEL: P5 (and the p5model oracle, pclass=PU) make ADC/SBB
#       U-only-pairable; pairing them into V inflated the pairing aggregate and
#       shifted per-insn cyc vs the oracle.
#   (2) ARCH CORRUPTION: the V ALU datapath has NO carry-in forwarding, so a
#       paired add(U)/adc(V) computed the adc with the STALE architectural CF
#       instead of the carry the U add just produced -> wrong result.
# Fix: ADC/SBB are now pairs_second=0 (U-only-pairable), matching the oracle,
# which also removes the corruption (an adc/sbb can never sit in V).
#
# This program exercises exactly the add->adc / sub->sbb adjacency the bug hit,
# building 64-bit add/sub out of 32-bit pieces. The low half sets CF; the high
# half's ADC/SBB MUST consume that freshly-produced CF (not a stale one). Every
# flag/register checked here is DEFINED (no undefined-flag ops), so the func
# comparator compares them in full and a stale-carry result FAILS the gate.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- 64-bit ADD: (eax:edx) = 0x00000001_FFFFFFFF + 0x00000002_00000001 --
    #      low:  0xFFFFFFFF + 0x00000001 = 0x1_00000000  -> low=0, CF=1
    #      high: 0x00000001 + 0x00000002 + CF(=1) = 0x00000004
    movl    $0xFFFFFFFF, %eax        # low A
    movl    $0x00000001, %edx        # high A
    movl    $0x00000001, %ebx        # low B
    movl    $0x00000002, %ecx        # high B
    addl    %ebx, %eax               # eax = 0, CF = 1  (the carry producer)
    adcl    %ecx, %edx               # edx = 1 + 2 + 1 = 4  (consumes fresh CF)
    # expect: eax=0x00000000, edx=0x00000004

    # ---- a SECOND add->adc adjacency, this time NO carry out of the low add --
    #      low:  0x00000010 + 0x00000020 = 0x00000030  -> CF=0
    #      high: 0x00000005 + 0x00000006 + CF(=0) = 0x0000000B
    movl    $0x00000010, %eax
    movl    $0x00000005, %edx
    movl    $0x00000020, %ebx
    movl    $0x00000006, %ecx
    addl    %ebx, %eax               # eax = 0x30, CF = 0
    adcl    %ecx, %edx               # edx = 5 + 6 + 0 = 0x0B
    # expect: eax=0x00000030, edx=0x0000000B

    # ---- 64-bit SUB: (esi:edi) = 0x00000003_00000000 - 0x00000001_00000001 --
    #      low:  0x00000000 - 0x00000001 = 0xFFFFFFFF, borrow -> CF=1
    #      high: 0x00000003 - 0x00000001 - CF(=1) = 0x00000001
    movl    $0x00000000, %esi        # low A
    movl    $0x00000003, %edi        # high A
    movl    $0x00000001, %ebx        # low B
    movl    $0x00000001, %ecx        # high B
    subl    %ebx, %esi               # esi = 0xFFFFFFFF, CF = 1 (borrow producer)
    sbbl    %ecx, %edi               # edi = 3 - 1 - 1 = 1  (consumes fresh borrow)
    # expect: esi=0xFFFFFFFF, edi=0x00000001

    # ---- imm forms (0x83 /2 = adc, /3 = sbb): add->adc and sub->sbb ---------
    movl    $0xFFFFFFFF, %eax
    movl    $0x00000007, %edx
    addl    $0x00000001, %eax        # eax = 0, CF = 1
    adcl    $0x00000000, %edx        # edx = 7 + 0 + 1 = 8

    movl    $0x00000000, %esi
    movl    $0x0000000A, %edi
    subl    $0x00000001, %esi        # esi = 0xFFFFFFFF, CF = 1
    sbbl    $0x00000000, %edi        # edi = 0x0A - 0 - 1 = 9

    # ---- a long ripple: three add->adc stages, each carry feeding the next --
    movl    $0xFFFFFFFF, %eax
    movl    $0xFFFFFFFF, %ebx
    movl    $0xFFFFFFFF, %ecx
    addl    $0x00000001, %eax        # eax=0, CF=1
    adcl    $0x00000000, %ebx        # ebx=0, CF=1 (0xFFFFFFFF+0+1 wraps)
    adcl    $0x00000000, %ecx        # ecx=0, CF=1
    adcl    $0x00000000, %edx        # edx picks up the top carry
    # (edx was 8 from above; +0+CF(1) = 9)

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                 # __NR_exit
    xorl    %ebx, %ebx               # status = 0
    int     $0x80                    # halt
