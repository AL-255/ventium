# =============================================================================
# Ventium M4 cycle microbench: mb_brrandom
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (ported from ventium-refs/.../tools/microbench.c "brrandom"):
#   A data-dependent conditional branch driven by an xorshift PRNG, so its outcome
#   is ~50% taken with NO repeating pattern. The 2-bit BTB predictor cannot learn
#   a pseudo-random sequence, so it mispredicts on roughly half the branches —
#   well above the 20% gate.
#
#   xorshift32 (Marsaglia), state in %eax, scratch in %edx, deterministic seed
#   r = 2463534242 (0x92d68ca2), exactly as microbench.c:
#       x ^= x << 13 ; x ^= x >> 17 ; x ^= x << 5
#   then a conditional branch on one PRNG bit:
#       test $0x10000,%eax ; jz 1f ; nop ; 1:
#   The body is unrolled BODY times. Because the body is unrolled (not a hot loop),
#   each `jz` is a distinct static branch executed once: the BTB sees a cold entry
#   (predict not-taken) and mispredicts whenever the branch is actually taken (the
#   tested bit is 0), i.e. ~50% of the time. Either way the aggregate is a high,
#   pattern-free mispredict rate >> 20%.
#
#   BODY=400 => 400 * 10 body insns = 4000 + overhead retired insns. The seed makes
#   the whole run deterministic (identical sequence every time, in QEMU and RTL).
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $0x92d68ca2, %eax       # eax = 2463534242  (xorshift seed)
    .rept   400
    movl    %eax, %edx              # x ^= x << 13
    shll    $13, %edx
    xorl    %edx, %eax
    movl    %eax, %edx              # x ^= x >> 17
    shrl    $17, %edx
    xorl    %edx, %eax
    movl    %eax, %edx              # x ^= x << 5
    shll    $5, %edx
    xorl    %edx, %eax
    testl   $0x10000, %eax          # test PRNG bit 16
    jz      1f                      # ~50% taken, pattern-free => high mispredict
    nop
1:
    .endr

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
