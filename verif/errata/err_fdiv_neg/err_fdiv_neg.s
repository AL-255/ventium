# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M6 errata test: err_fdiv_neg -- FDIV erratum NEGATIVE controls (Err 23)
# =============================================================================
# Spec: pentium-spec-update-242480-022.pdf doc p.78, Erratum 23. This test is the
# HONESTY guard for the FDIV model: it proves the errata model injects a flaw ONLY
# for the published table vector, and NEVER fabricates an Intel-undocumented
# quotient for any other operand -- even one whose divisor hits the documented SRT
# trigger pattern. Both divides below MUST give a bit-identical result with the
# errata flag ON and OFF (== QEMU/M3 clean).
#
#   st1 = 7654321.0 / 3145727.0
#         The divisor 3145727.0 normalizes to 1.0111111... -> it HITS the
#         documented missing-PLA trigger (srt_flaw_divisor==1), but this exact
#         operand PAIR has NO published flawed result, so it is NOT in the table.
#         Expected: clean quotient, ON == OFF (no fabricated value).
#
#   st0 = 4195835.0 / 3.0
#         The divisor 3.0 = 1.1000... does NOT hit any trigger pattern.
#         Expected: clean quotient, ON == OFF.
#
# SELF-CHECK (verif/errata/run-m6.sh): trace st0 (non-trigger) and st1 (trigger-
# divisor-but-not-published) must each be EQUAL with --errata 0x1 and without it.
#
# Freestanding 32-bit i386 (P5). Ends with _exit(0) (int 0x80).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- st1: triggering-divisor (3145727.0) but NOT the published pair -------
    fldl    div_trig            # st0 = 3145727.0 (triggering divisor)
    fldl    dvd_trig            # st0 = 7654321.0  st1 = 3145727.0
    fdiv    %st(1), %st(0)      # st0 = 7654321.0 / 3145727.0
    fstp    %st(1)              # drop the divisor; quotient stays as the lone st0

    # move that quotient to st1 by pushing the next computation on top
    # ---- st0: non-triggering divisor (3.0) ------------------------------------
    fldl    div_clean           # st0 = 3.0          st1 = (trigger quotient)
    fldl    dvd_clean           # st0 = 4195835.0    st1 = 3.0   st2 = (trig q)
    fdiv    %st(1), %st(0)      # st0 = 4195835.0 / 3.0
    fstp    %st(1)              # drop 3.0 -> st0 = clean quotient, st1 = trig quotient

    # clean exit (st0 = non-trigger quotient, st1 = trigger-divisor quotient)
    movl    $1, %eax            # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 8
dvd_trig:   .double 7654321.0
div_trig:   .double 3145727.0
dvd_clean:  .double 4195835.0
div_clean:  .double 3.0
