# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M6 errata test: err_moffs -- MOV moffs A2/A3 fails to pair (Erratum 59)
# =============================================================================
# Spec: pentium-spec-update-242480-022.pdf doc p.99, "Short Form of MOV EAX/AX/AL
# May Not Pair". The MOV-to-memory-offset short forms (opcodes A2/A3) ARE UV-
# pairable, but the P5 instruction unit FALSELY detects an EAX dependency and
# does NOT pair them when the FOLLOWING instruction uses EAX (as source, base/
# index, or destination). Documented example:
#   A3 <abs32>   MOV [mem], EAX   -> u-pipe
#   A1 <abs32>   MOV EAX, [mem]   -> does NOT go into v-pipe (false dependency)
#
# This is a CYCLE (pairing) erratum -- verified through the cycle trace. We place
# an A3 store immediately before a pairable EAX-referencing MOV (89 /r: mov
# %eax,%ebx, which reads EAX). The clean (errata-off) P5 model PAIRS them (the V
# member shows pipe=V/paired=1); the buggy stepping does NOT (the follower
# retires as its own U, pipe=U/paired=0).
#
# SELF-CHECK (verif/errata/run-m6.sh, --cycle):
#   errata OFF : the EAX-using MOV after the A3 store is PAIRED (a V retirement).
#   errata ON  : that MOV is NOT paired (no V retirement after the A3 store).
#
# A control pair of two plain register MOVs (which always pair) frames the test so
# the harness can confirm pairing is otherwise working.
#
# Freestanding 32-bit i386 (P5). Run in --cycle mode.
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $0x11111111, %eax       # seed EAX

    # ---- control: two register MOVs that ALWAYS pair (sanity for the harness) -
    movl    %eax, %ecx              # 89 C1  (reads EAX, writes ECX)  -> U
    movl    %edx, %ebp              # 89 D5  (reads EDX, writes EBP)  -> V (pairs)

    # ---- the erratum site: A3 moffs store, then an EAX-referencing MOV --------
    .byte 0xa3                      # MOV [dwordslot], EAX  (A3 absolute store) -> U
    .long   dwordslot
    movl    %eax, %ebx              # 89 C3  (reads EAX, writes EBX)
                                    #   clean: pairs into V ; buggy: stays own U

    # ---- a few independent ops so the trace has clean tail records ------------
    movl    %esi, %edi              # 89 F7  -> U
    nop                             # 90     -> V (pairs)

    # clean exit
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 4
dwordslot:  .long 0
