# =============================================================================
# Ventium M5 regression: mb_fpocc   (FP pipe OCCUPANCY / throughput)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# REGRESSION for M5 adversarial finding [high] (FP unit OCCUPANCY/THROUGHPUT not
# modeled). The p5model oracle classifies fdiv as occ=39, fmul as occ=2: an FP op
# HOLDS the in-order pipe for `occ` clocks, so even a *following independent
# non-FP instruction* is delayed until the FP op's occupancy expires
# (verif/qemu-plugins/p5trace.c: pipe_free_at = issue + occ). M4 charged only the
# result-LATENCY consumer stall (a dependent FP op), never occupancy, so a single
# fdiv + independent integer work ran ~2x too fast vs the oracle. M5 models
# occupancy as a real pipe-hold (fp_occ), so the integer ops queue behind the
# fdiv's 39-cycle occupancy and the abs-cyc tracks the oracle.
#
# STRUCTURE: a hot loop whose body is { fld1; fld1; fdiv; fmul; 8 independent movs;
# fstp; fstp }. The fdiv (occ 39) and fmul (occ 2) dominate; the independent movs
# would issue in ~4 clocks if occupancy were ignored, but must wait behind the FP
# occupancy. The loop is small (resident in L1 I$) and counted, so I$ is warm
# after pass 1 and CPI converges to the occupancy-bound value (well above 1).
# =============================================================================
    .text
    .globl  _start
_start:
    movl    $40, %ecx               # outer iterations
.Lrep:
    fld1                            # st0 = 1.0   (occ 2)
    fld1                            # st1 = 1.0   (occ 2)
    fdiv    %st(1), %st             # st0 /= st1  (occ 39, lat 39) -> holds the pipe
    movl    $1, %eax                # 8 INDEPENDENT integer ops: must queue behind
    movl    $2, %edx                # the fdiv's 39-cycle occupancy (oracle), not
    movl    $3, %ebx                # issue immediately (the M4 bug).
    movl    $4, %esi
    movl    $5, %edi
    movl    $6, %eax
    movl    $7, %edx
    movl    $8, %ebx
    fmul    %st(1), %st             # st0 *= st1  (occ 2) -> holds pipe 2 clocks
    fstp    %st(0)                  # pop  (occ 1)
    fstp    %st(0)                  # pop  (occ 1) -> stack empty for next pass
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80
