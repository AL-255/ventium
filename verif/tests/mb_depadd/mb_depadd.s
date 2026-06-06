# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M4 cycle microbench: mb_depadd
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (ported from ventium-refs/.../tools/microbench.c "depadd"):
#   A chain of `add $1,%eax`. Every add reads AND writes %eax, so each one has a
#   RAW dependency on its predecessor. The P5 U/V pairing checker forbids a RAW/WAW
#   pair (can_pair: v->reads & wU), so the second add can NEVER issue into the V
#   pipe — the stream runs strictly one-add-per-clock through the U pipe.
#   Result: CPI ~ 1.0, pairing < 2%.
#
# STRUCTURE — why a hot LOOP, not one giant straight-line .rept:
#   The P5 cycle model (default) charges an 8-cycle cold-miss the first time each
#   32-byte I-cache line is fetched. A 3000-long straight-line .rept touches ~280
#   never-reused lines, so cold misses would dominate and inflate CPI to ~1.75.
#   The reference microbench.c avoids this by unrolling a SMALL body inside a loop
#   so the body stays resident in the 8 KB L1 I-cache and the cold-miss cost is a
#   one-time amortised constant. We mirror that: a 200-add body (resident in L1)
#   run 16 times => ~3216 retired adds, I-cache warm after the first pass, so CPI
#   converges to the true dependent-chain value ~1.0.
#
#   The loop back-edge (`dec %ecx; jnz`) is a predictable counted branch the BTB
#   learns immediately, so it adds negligible cycles and does not perturb CPI.
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $16, %ecx               # ecx = outer iteration count
.Lrep:
    xorl    %eax, %eax              # eax = 0 (reset chain each pass)
    .rept   200
    addl    $1, %eax                # eax += 1 ; RAW on eax => cannot pair => 1 cyc each
    .endr
    decl    %ecx                    # ecx-- (predictable back-edge)
    jnz     .Lrep
    # ~3200 dependent adds executed; I-cache warm; CPI ~ 1.0

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
