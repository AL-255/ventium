# =============================================================================
# Ventium M3 x87 test: tx_fchs_fabs_special -- FCHS/FABS on Inf/NaN (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# CORRECTNESS regression for REVIEW_Jun5.md Limit #2: FCHS and FABS are IN SCOPE
# (Tier-1, m3-fpu-spec.md "Sign/abs: FABS, FCHS") and must operate on +Inf/-Inf/
# NaN by touching the SIGN BIT (bit 79) ONLY -- never the exponent or mantissa,
# and never quieting/normalizing the value. This is a true differential vs QEMU:
# st0 (the full 80-bit floatx80) is trace-compared bit-exact each step.
#
# Why it MUST already pass (verified against the RTL, no RTL change needed):
#   rtl/core/core.sv:4011  FX_FABS: fp_top_data = {1'b0,  st0[78:0]}  (clear  s)
#   rtl/core/core.sv:4012  FX_FCHS: fp_top_data = {~st0[79], st0[78:0]} (toggle s)
# Both are pure bit ops on bit 79 with bits 78:0 passed through verbatim, with NO
# operand-class gating in the D9 E0 / D9 E1 decode (core.sv:1875-1876), so they
# decode+execute (do NOT HALT) for inf/NaN and match QEMU's helper_fchs /
# helper_fabs (target/i386/fpu_helper.c), which likewise only flip/clear the sign.
# FLD m80 (FLDT) pushes the operand verbatim (core.sv:3985) so an SNaN is loaded
# WITHOUT being quieted -- letting us prove FCHS/FABS preserve the SNaN payload.
#
# floatx80 canonical layout: bit79=sign, bits78:64=exp(bias 16383), bits63:0=man
# (explicit integer bit at 63). Operands/expected st0 (compared bit-exact):
#   +Inf   = 0x7fff 8000000000000000      -Inf   = 0xffff 8000000000000000
#   +QNaN  = 0x7fff c000000000000000      -QNaN  = 0xffff c000000000000000
#   +SNaN  = 0x7fff 8000000000000001      -SNaN  = 0xffff 8000000000000001
# FABS clears bit79 -> always the +form; FCHS toggles bit79.
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    fnclex

    # 1. FABS(+Inf) -> +Inf   (sign already 0; st0 unchanged = 0x7fff8000..0)
    fldt    pinf80
    fabs
    fstp    %st(0)

    # 2. FCHS(+Inf) -> -Inf   (sign 0->1; st0 = 0xffff8000..0)
    fldt    pinf80
    fchs
    fstp    %st(0)

    # 3. FABS(-Inf) -> +Inf   (sign 1->0; st0 = 0x7fff8000..0)
    fldt    ninf80
    fabs
    fstp    %st(0)

    # 4. FCHS(-Inf) -> +Inf   (sign 1->0; st0 = 0x7fff8000..0)
    fldt    ninf80
    fchs
    fstp    %st(0)

    # 5. FABS(+QNaN) -> +QNaN  (unchanged = 0x7fffc000..0; payload preserved)
    fldt    pqnan80
    fabs
    fstp    %st(0)

    # 6. FCHS(+QNaN) -> -QNaN  (sign 0->1 = 0xffffc000..0; payload preserved)
    fldt    pqnan80
    fchs
    fstp    %st(0)

    # 7. FABS(-QNaN) -> +QNaN  (sign 1->0 = 0x7fffc000..0)
    fldt    nqnan80
    fabs
    fstp    %st(0)

    # 8. FCHS(-QNaN) -> +QNaN  (sign 1->0 = 0x7fffc000..0)
    fldt    nqnan80
    fchs
    fstp    %st(0)

    # 9. FABS(+SNaN) -> +SNaN  (unchanged 0x7fff8000..01; SNaN NOT quieted by FABS)
    fldt    psnan80
    fabs
    fstp    %st(0)

    # 10. FCHS(+SNaN) -> -SNaN (sign 0->1 = 0xffff8000..01; SNaN payload preserved)
    fldt    psnan80
    fchs
    fstp    %st(0)

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 16
# floatx80 stored little-endian: .quad mantissa (bits63:0) then .word sign|exp.
pinf80:  .quad 0x8000000000000000      # +Inf : exp all-ones, integer bit set
         .word 0x7fff
         .word 0
ninf80:  .quad 0x8000000000000000      # -Inf
         .word 0xffff
         .word 0
pqnan80: .quad 0xc000000000000000      # +QNaN: exp all-ones, bit63=1, bit62=1
         .word 0x7fff
         .word 0
nqnan80: .quad 0xc000000000000000      # -QNaN
         .word 0xffff
         .word 0
psnan80: .quad 0x8000000000000001      # +SNaN: exp all-ones, bit62=0, low bit set
         .word 0x7fff
         .word 0
