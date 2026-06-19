# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium x87 test: tx_fp_denorm -- denormal operands + gradual underflow +
# overflow, masked default control (CW=0x037F, RNE, PC=11), vs QEMU.
# =============================================================================
# Exercises the FPU paths that were previously "Tier-3 best-effort" (denormals,
# under/overflow): denormal float32/float64 LOADS (normalized to floatx80),
# denormal floatx80 OPERANDS to add/mul/div, gradual-UNDERFLOW results (UE+PE),
# OVERFLOW-to-Inf results (OE+PE), and FST m32/m64 narrowing that under/overflows.
# Each result lands in st0 (graded floatx80) and the status word is read back via
# fnstsw into %ecx (graded GPR), so both the value AND the IE/DE/ZE/OE/UE/PE flags
# are checked byte-exact vs QEMU. fnclex isolates each case's flags.
#
# Per QEMU's x87 model: DE (denormal-operand) is NOT raised by FADD/FMUL/FDIV
# (only FXTRACT / flush-to-zero), so the denormal-operand cases set no flag unless
# the *result* rounds (PE) or under/overflows (UE/OE).
#
# Exit: Linux i386 _exit(0) -> int 0x80.
# =============================================================================
    .text
    .globl  _start
_start:
    fninit
    # A: FLD denormal float32 (1e-40) -> normalized floatx80, no flag
    fnclex ; flds dfa ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # B: FLD denormal float64 (5e-320) -> normalized floatx80, no flag
    fnclex ; fldl dfb ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # C: denormal-f80 + denormal-f80 -> smallest normal, exact (no flag)
    fnclex ; fldt dtiny ; fldt dtiny ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # D: denormal-f80 * 4.0 -> normal (exact), regression on the eff-exponent mul
    fnclex ; fldt dtiny ; fldt p4 ; fmulp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # E: smallest-normal * smallest-normal -> +0 (massive underflow): UE+PE
    fnclex ; fldt smin ; fldt smin ; fmulp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # F: huge * huge -> +Inf (overflow): OE+PE
    fnclex ; fldt big ; fldt big ; fmulp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # G: smallest-normal / huge -> underflow to 0: UE+PE
    fnclex ; fldt smin ; fldt big ; fdivp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # H: huge / smallest-normal -> overflow to Inf: OE+PE
    fnclex ; fldt big ; fldt smin ; fdivp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # I: FST m32 underflow: 1e-43 -> float32 denormal (inexact): UE+PE
    fnclex ; fldl uf ; fsts smem ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # J: FST m32 overflow: 1e40 -> float32 +Inf: OE+PE
    fnclex ; fldl of ; fsts smem ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # K: FST m64 overflow: 2^1100 (f80) -> float64 +Inf: OE+PE
    fnclex ; fldt sbig64 ; fstl smem64 ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # L: FST m64 underflow: ~2^-1049 full-mantissa (f80) -> float64 denormal: UE+PE
    fnclex ; fldt sden64 ; fstl smem64 ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # M: FXAM a denormal -> C3=1,C2=1 (classify) + sign; regression on denormal classify
    fnclex ; fldt dtiny ; fxam ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # N: denormal-f80 + 1.0 -> 1.0 with PE (the tiny addend rounds away)
    fnclex ; fldt dtiny ; fld1 ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)

    movl $1, %eax ; xorl %ebx, %ebx ; int $0x80

    .data
    .align 16
dfa:    .float  1e-40                 # float32 denormal
dfb:    .double 5e-320                # float64 denormal
uf:     .double 1e-43                 # normal f64 -> float32 denormal on store
of:     .double 1e40                  # normal f64 -> float32 overflow on store
p4:     .tfloat 4.0                   # +4.0 (floatx80)
# floatx80 little-endian (bytes 0..7 = mantissa LE, byte8/9 = exp[7:0]/[14:8]+sign):
smin:   .byte 0,0,0,0,0,0,0,0x80,0x01,0x00   # 2^-16382  (smallest normal)
big:    .byte 0,0,0,0,0,0,0,0x80,0x00,0x70   # 2^12289   (exp 0x7000)
dtiny:  .byte 0,0,0,0,0,0,0,0x40,0x00,0x00   # 2^-16383  (denormal, exp 0, bit62)
sbig64: .byte 0,0,0,0,0,0,0,0x80,0x4B,0x44   # 2^1100    (exp 0x444B; > f64 max)
sden64: .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xE6,0x3B  # ~2^-1049 full mant
smem:   .long 0
smem64: .quad 0
