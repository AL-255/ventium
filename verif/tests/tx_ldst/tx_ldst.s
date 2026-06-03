# =============================================================================
# Ventium M3 x87 test: tx_ldst -- load/store/move data movement (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m3-fpu-spec.md Tier 1 "Load/store/move"): round-trip exactly-
# representable values through memory in every operand size and check both the
# 80-bit st registers and the integer/float memory images.
#
# Ops covered:
#   FLD  m32 / m64 / m80   (D9 /0, DD /0, DB /5)
#   FST  m32 / m64 + st(i) (D9 /2, DD /2, DD D0+i)
#   FSTP m32 / m64 / m80   (D9 /3, DD /3, DB /7)
#   FLD  st(i) (D9 C0+i)
#   FILD  m16 / m32 / m64  (DF /0, DB /0, DF /5)
#   FIST  m32              (DB /2)
#   FISTP m16 / m32 / m64  (DF /3, DB /3, DF /7)
#
# DETERMINISTIC, exactly-representable values only (powers of two, small
# integers): no rounding ambiguity, and the integer stores never overflow so
# fstat's IE (invalid-op, bit0) flag stays clear and predictable.
#   2.0   m32 = 0x40000000      -> floatx80 0x40008000000000000000
#   0.5   m64 = 0x3FE000...     -> floatx80 0x3ffe8000000000000000
#   0.25                        -> floatx80 0x3ffd8000000000000000
#   int16 -100, int32 70000, int64 4000000000 (all fit their store sizes here:
#         stores below use values that fit int32, so no #IE)
#
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- FLD m32 / m64, FST/FSTP through memory (float round-trip) ----------
    flds    f2_0            # st0 = 2.0   (m32 load)
    fldl    f0_5            # st0 = 0.5   (m64 load), st1 = 2.0
    fldt    f80_e0          # st0 = m80 (=4.0), st1=0.5, st2=2.0

    fstpt   out80           # store st0 (4.0) to m80 (DB /7), pop -> st0=0.5
    fstl    out64           # store st0 (0.5) to m64, no pop
    fstps   out32           # store st0 (0.5) to m32 (rounds exactly), pop -> st0=2.0
    fsts    out32b          # store st0 (2.0) to m32, no pop

    # ---- FLD st(i) / FST st(i) (register-to-register move) ------------------
    fld     %st(0)          # duplicate st0 (2.0) -> st0=st1=2.0
    fld1                    # st0 = 1.0  (st1=2.0 st2=2.0)
    fst     %st(2)          # copy st0 (1.0) into st(2), no pop
    fstp    %st(0)          # pop the 1.0
    fstp    %st(0)          # pop a 2.0
    fstp    %st(0)          # pop -> st0 holds the copied 1.0 now; pop it
    # stack empty

    # ---- FILD m16 / m32 / m64 (signed integer load) -------------------------
    filds   i16             # st0 = (double-extended) -100
    fildl   i32             # st0 = 70000
    fildll  i64             # st0 = 4000000000

    # ---- FIST / FISTP back to integer memory (values fit -> no #IE) ---------
    fistpll oi64            # store int64 4000000000, pop -> st0 = 70000
    fistl   oi32            # store int32 70000, no pop
    fistpl  oi32b           # store int32 70000, pop -> st0 = -100
    fistps  oi16            # store int16 -100, pop -> empty

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax        # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80           # halt

    # =========================================================================
    # In-image RW data: exactly-representable float constants + integer slots.
    # =========================================================================
    .data
    .align 16
f2_0:   .float  2.0                 # m32  0x40000000
f0_5:   .double 0.5                 # m64
f80_e0: .byte 0,0,0,0,0,0,0,0x80,0x01,0x40  # m80 floatx80 for +4.0
        # (mantissa MSB 0x80<<56, exp 0x4001, sign 0) = 2^(0x4001-0x3fff)*1.0 = 4.0

i16:    .short  -100
i32:    .long   70000
i64:    .quad   4000000000

out32:  .long   0
out32b: .long   0
out64:  .quad   0
out80:  .byte 0,0,0,0,0,0,0,0,0,0   # 10-byte m80 store slot

oi16:   .short  0
oi32:   .long   0
oi32b:  .long   0
oi64:   .quad   0
