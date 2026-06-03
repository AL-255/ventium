# =============================================================================
# Ventium M3 x87 test: tx_special -- masked special-operand arithmetic (Tier 3)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Regression for adversarial-review finding [low]: with exceptions MASKED
# (default cw), the special cases QEMU handles explicitly must be reproduced
# bit-exact instead of silently mis-computing:
#   FDIV  x/0  (x finite nonzero) -> signed Inf, ZE (fstat bit2)   [helper_fdiv]
#   FDIV  0/0                     -> real-indefinite QNaN, IE (bit0)
#   FSQRT(-x) (x finite nonzero)  -> real-indefinite QNaN, IE, C2  [helper_fsqrt]
#   FSQRT(-0)                     -> -0, C2 (no IE)
# real-indefinite floatx80 = 0xffff_c000000000000000.
# st0 and fstat are trace-compared -> ZE / IE / C2 must match QEMU exactly.
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    fnclex

    # 1. 1.0 / 0.0 -> +Inf, ZE
    fldz                            # st0 = +0.0
    fld1                            # st0 = 1.0, st1 = +0.0
    fdiv    %st(1),%st(0)           # st0 = 1.0/0.0 = +Inf
    fnstsw  %ax
    fstp    %st(0)                  # pop the Inf
    fstp    %st(0)                  # pop the +0.0 -> empty

    # 2. 0.0 / 0.0 -> real-indefinite QNaN, IE
    fnclex
    fldz                            # st1-to-be = +0.0
    fldz                            # st0 = +0.0
    fdiv    %st(1),%st(0)           # 0/0 -> QNaN, IE
    fnstsw  %ax
    fstp    %st(0)
    fstp    %st(0)

    # 3. FSQRT(-4.0) -> real-indefinite QNaN, IE, C2
    fnclex
    flds    fneg4
    fsqrt
    fnstsw  %ax
    fstp    %st(0)

    # 4. FSQRT(-0.0) -> -0.0, C2 (no IE)
    fnclex
    fldz
    fchs                            # -0.0
    fsqrt
    fnstsw  %ax
    fstp    %st(0)

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 16
fneg4:  .float -4.0
