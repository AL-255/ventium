# =============================================================================
# Ventium M5 cycle microbench: mb_faddchain   (GATED FP-latency band)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (the headline NEW M5 gated band — docs/m5-cycle-spec.md §3):
#   A DEPENDENT chain of `fadd %st(1),%st`. Every fadd reads st(0) (the running
#   sum) and writes st(0), so each one is RAW-dependent on its predecessor through
#   the x87 top-of-stack. The P5 `fadd` has LATENCY 3 / THROUGHPUT 1
#   (docs/p5-timing-model.md): the result of one fadd is not ready for 3 clocks,
#   and because the next fadd needs that result it cannot start until then. The
#   chain therefore CANNOT overlap and runs at exactly one fadd per 3 clocks =>
#   CPI ~ 3.0. This is the cycle signature of the FP *latency* (vs throughput),
#   and is what M5 makes emergent in the RTL (M4 only serialized FP).
#
#   In the p5model timing core (verif/qemu-plugins/p5trace.c) fadd is
#   fp_role=3 (reads AND writes the single top-of-stack readiness slot `fp_ready`,
#   occ=1, lat=3). Each fadd's issue is pushed to prev_issue+3 by the fp_ready
#   read, so grp_cycle advances by 3 per fadd => steady-state per-fadd cost 3.
#
# STRUCTURE — hot LOOP, not one giant straight-line .rept (see mb_depadd.s):
#   The cycle model charges an 8-cycle cold I-cache miss the first time each 32-byte
#   line is fetched. A 3000-long straight-line body touches ~190 never-reused lines,
#   so cold misses would inflate CPI. We mirror the reference: a small unrolled body
#   (250 fadds = 1250 bytes, ~40 lines, resident in the 8 KB / 256-line L1 I-cache)
#   run 12 times => 3000 dependent fadds, I-cache warm after pass 1, so CPI converges
#   to the true latency-bound value ~3.0. The two `fld1` seed st(0)=st(1)=1.0 once
#   per pass (negligible). The counted `dec %ecx; jnz` back-edge is predicted by the
#   BTB immediately and adds negligible cycles; it does not perturb CPI.
#
#   This is x87 FP and therefore P5 (isa_verify treats x87 as in-scope P5 ISA).
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $12, %ecx               # ecx = outer iteration count
.Lrep:
    fld1                            # st(0) = 1.0  (the running accumulator)
    fld1                            # st(0) = 1.0, st(1) = 1.0 (the addend)
    .rept   250
    fadd    %st(1), %st             # st(0) += st(1)  ; RAW on st(0) => 3-cyc latency, no overlap
    .endr
    fstp    %st(0)                  # pop accumulator (keep the x87 stack bounded each pass)
    fstp    %st(0)                  # pop addend
    decl    %ecx                    # ecx-- (predictable back-edge)
    jnz     .Lrep
    # ~3000 dependent fadds executed; I-cache warm; CPI ~ 3.0 (FP latency 3).

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
