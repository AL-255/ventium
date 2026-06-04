# =============================================================================
# Ventium M5 cycle microbench: mb_fpindep   (FP latency-vs-throughput, INFO)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (the latency-vs-throughput contrast — docs/m5-cycle-spec.md §3):
#   mb_faddchain showed FP *latency*: a dependent fadd chain serializes at CPI ~3.0
#   (lat 3). This kernel shows FP *throughput*: `fadd` has THROUGHPUT 1 — a new fadd
#   can ENTER the FP pipe every clock; only a CONSUMER that needs the result must
#   wait the full 3-cycle latency. We expose that by interleaving each dependent
#   fadd with two INDEPENDENT integer adds (different GP regs, no FP dependency).
#   The integer adds issue/pair into the U/V pipes *during* the fadd's 3-cycle
#   latency window — work that would otherwise be a stall bubble. The FP throughput
#   of 1 means the FP unit is not the bottleneck, so the stream retires at
#   CPI ~ 1.0 — far below the dependent chain's ~3.0. Same fadd opcode, same FP
#   latency; the difference is purely overlap, i.e. THROUGHPUT vs LATENCY.
#
#   In the p5model timing core (verif/qemu-plugins/p5trace.c): the fadd (fp_role=3,
#   occ=1, lat=3) still advances fp_ready by 3, but the two `add` (UV-pairable,
#   independent dest regs, 8-bit imm, no disp) issue in the U/V pipes inside that
#   window, so total cycles track the integer throughput, not the FP latency.
#
# STRUCTURE — hot loop (see mb_faddchain.s / mb_depadd.s for the I-cache rationale):
#   body = 250 (fadd + add eax + add ebx) triples (resident in the 8 KB L1 I-cache)
#   run 4 times => 250*3*4 = 3000 FP/int insns, I-cache warm after pass 1. The xors
#   reset the independent integer accumulators each pass; the two fld1 seed st(0)/
#   st(1); the counted back-edge is predicted. CPI converges to ~1.0.
#
#   This is x87 FP and therefore P5 (isa_verify treats x87 as in-scope P5 ISA).
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $4, %ecx                # ecx = outer iteration count
.Lrep:
    fld1                            # st(0) = 1.0 (FP accumulator)
    fld1                            # st(0) = 1.0, st(1) = 1.0 (FP addend)
    xorl    %eax, %eax              # eax = 0 (independent integer accumulator)
    xorl    %ebx, %ebx              # ebx = 0 (independent integer accumulator)
    .rept   250
    fadd    %st(1), %st             # FP: st(0) += st(1)  (lat 3, tput 1)
    addl    $1, %eax                # U pipe: independent of FP and of ebx
    addl    $1, %ebx                # V pipe: independent of FP and of eax (pairs)
    .endr
    fstp    %st(0)                  # pop accumulator (keep the x87 stack bounded)
    fstp    %st(0)                  # pop addend
    decl    %ecx                    # ecx-- (predictable back-edge)
    jnz     .Lrep
    # ~3000 insns; FP latency fully hidden by independent integer work; CPI ~ 1.0.

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
