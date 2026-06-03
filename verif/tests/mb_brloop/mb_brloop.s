# =============================================================================
# Ventium M4 cycle microbench: mb_brloop
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (ported from ventium-refs/.../tools/microbench.c "brloop"):
#   One predictable backward conditional branch: a counted loop.
#       mov $N, %ecx
#     1: dec %ecx
#       jnz 1b
#   The `jnz` is taken N-1 times and falls through once per loop entry. The P5
#   256-entry 4-way BTB + 2-bit saturating predictor learns "taken" after the
#   first taken resolution and predicts every subsequent back-edge correctly; the
#   only mispredict is the single loop-exit fall-through. With a large trip count
#   the mispredict rate is far below the 2% gate.
#
#   We run the loop OUTER times with a large inner trip count INNER. Total branch
#   count ~= OUTER*INNER, of which only OUTER are loop-exit mispredicts (plus a
#   couple of one-time BTB-warmup mispredicts), so mispredict% ~= 1/INNER << 2%.
#
#   OUTER=4, INNER=750 => ~3000 jnz executions, ~3000*3 + overhead retired insns.
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $4, %edx                # edx = OUTER loop count
.Louter:
    movl    $750, %ecx              # ecx = INNER trip count
.Linner:
    decl    %ecx                    # ecx-- (ZF set when ecx reaches 0)
    jnz     .Linner                 # predictable backward branch: taken 749/750
    decl    %edx                    # outer counter--
    jnz     .Louter                 # outer back-edge (also predictable)

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
