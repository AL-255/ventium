# =============================================================================
# Ventium M12 x87 test: tx_fp_special -- special-operand arithmetic + flags
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87. gcc -m32 -march=pentium.
#
# Masked default-control (CW=0x037F, PC=11 RNE) results + the IE/ZE exception
# flags for Inf / NaN / signed-zero operands of FADD/FSUB/FMUL/FDIV/FSQRT. Each
# result lands in st0 (live-graded floatx80) and the status word is read back via
# fnstsw into %ecx (graded GPR) so both the masked default AND the flags are
# checked byte-exact vs QEMU. fnclex between cases isolates the flags.
#
# Oracle-pinned (qemu): invalid (Inf-Inf, 0/0, Inf/Inf, Inf*0, sqrt(neg)) ->
# real-indefinite 0xffffc000000000000000 + IE; finite/0 -> signed Inf + ZE;
# Inf +- finite -> signed Inf; QNaN propagates (no IE); SNaN -> QNaN + IE.
# OE/UE/DE/PC are NOT exercised here (deferred: fx80's exponent range can't
# overflow/underflow from these operands, and PC!=11 stays loud-HALT).
#
# Exit: Linux i386 _exit(0) -> int 0x80.
# =============================================================================
    .text
    .globl  _start
_start:
    fninit
    # A: +Inf + 1 -> +Inf, no flag
    fnclex ; fldt pinf ; fld1 ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # B: +Inf - +Inf -> real-indefinite, IE
    fnclex ; fldt pinf ; fldt pinf ; fsubp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # C: 1 / 0 -> +Inf, ZE
    fnclex ; fld1 ; fldz ; fdivp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # D: 0 / 0 -> real-indefinite, IE
    fnclex ; fldz ; fldz ; fdivp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # E: +Inf / +Inf -> real-indefinite, IE
    fnclex ; fldt pinf ; fldt pinf ; fdivp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # F: +Inf * 0 -> real-indefinite, IE
    fnclex ; fldt pinf ; fldz ; fmulp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # G: 3 / +Inf -> +0, no flag
    fnclex ; fldl p3 ; fldt pinf ; fdivp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # H: 2 * +Inf -> +Inf, no flag
    fnclex ; fldl p2 ; fldt pinf ; fmulp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # I: QNaN + 1 -> QNaN (propagate), no IE
    fnclex ; fldt qnan ; fld1 ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # J: SNaN + 1 -> QNaN, IE
    fnclex ; fldt snan ; fld1 ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # K: sqrt(+Inf) -> +Inf, no flag
    fnclex ; fldt pinf ; fsqrt ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # L: sqrt(-4) -> real-indefinite, IE
    fnclex ; fldl m4 ; fsqrt ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # M: sqrt(QNaN) -> QNaN (propagate), no IE
    fnclex ; fldt qnan ; fsqrt ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # N: sqrt(4) -> 2, no flag (regression on the normal sqrt path)
    fnclex ; fldl p4 ; fsqrt ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # O: -7 / 2 -> -3.5 exact, no flag (normal/normal regression)
    fnclex ; fldl m7 ; fldl p2 ; fdivp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # --- two-NaN selection (QEMU x87 pickNaN: larger 64-bit significand wins;
    #     tie -> positive sign; winner quieted iff SNaN; IE iff either SNaN) ---
    # P: QNaN(0x111) + QNaN(0x222) -> 0x...0222 (larger), no IE
    fnclex ; fldt q111 ; fldt q222 ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # Q: SNaN(0x333) + QNaN(0x111) -> 0x...0111 (the QNaN: quiet bit -> larger sig), IE
    fnclex ; fldt s333 ; fldt q111 ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # R: SNaN(0x333) + SNaN(0x7ff) -> 0x7fffe000..07ff (larger, quietized), IE
    fnclex ; fldt s333 ; fldt s7ff ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)
    # S: +QNaN(0x111) + -QNaN(0x111) (equal sig) -> +QNaN (positive wins), no IE
    fnclex ; fldt q111 ; fldt q111n ; faddp %st,%st(1) ; fnstsw %ax ; movzwl %ax,%ecx ; fstp %st(0)

    movl $1, %eax ; xorl %ebx, %ebx ; int $0x80

    .data
    .align 16
pinf: .byte 0,0,0,0,0,0,0,0x80,0xff,0x7f   # +Inf  floatx80 0x7fff8000000000000000
qnan: .byte 0,0,0,0,0,0,0,0xc0,0xff,0x7f   # +QNaN floatx80 0x7fffc000000000000000
snan: .byte 0,0,0,0,0,0,0,0xa0,0xff,0x7f   # +SNaN floatx80 0x7fffa000000000000000
p2:   .double 2.0
p3:   .double 3.0
p4:   .double 4.0
m4:   .double -4.0
m7:   .double -7.0
q111:  .byte 0x11,0x01,0,0,0,0,0,0xc0,0xff,0x7f   # +QNaN payload 0x0111
q222:  .byte 0x22,0x02,0,0,0,0,0,0xc0,0xff,0x7f   # +QNaN payload 0x0222 (larger sig)
q111n: .byte 0x11,0x01,0,0,0,0,0,0xc0,0xff,0xff   # -QNaN payload 0x0111 (sign set)
s333:  .byte 0x33,0x03,0,0,0,0,0,0xa0,0xff,0x7f   # +SNaN payload 0x0333
s7ff:  .byte 0xff,0x07,0,0,0,0,0,0xa0,0xff,0x7f   # +SNaN payload 0x07ff (larger sig)
