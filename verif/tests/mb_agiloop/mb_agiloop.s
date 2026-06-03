# =============================================================================
# Ventium M4 cycle microbench (INFO): mb_agiloop  --  LOOPED AGI hazard
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Regression-locks the M4 adversarial-review MED finding: a static AGI site
# inside a BACKWARD LOOP. The old RTL recorded the PC of an AGI stall in
# `agi_stalled_eip` and SUPPRESSED the stall whenever agi_stalled_eip==eip, and
# that register was set ONCE and never reset. So a looped AGI site charged its
# 1-cycle stall only on the FIRST iteration; every later iteration that genuinely
# needs the AGI stall was silently skipped -> CPI too low vs the oracle.
#
# The straight-line gate kernel mb_agi UNROLLs each AGI site to a distinct PC, so
# it masks this; a real loop exposes it. p5model charges P5_AGI_PENALTY=1 EVERY
# time reg_wcycle[base]==issue-1 (plugin/p5model.c:451), i.e. each iteration.
#
# Fix: the AGI stall now fires every time the hazard exists (the suppressor was
# removed; the double-charge across the immediately-following clock is prevented
# structurally because the stall clock clears agi_wr0/agi_wr1). This INFO kernel
# is a tight backward loop with a write-then-base-use pair in the body; the AGI
# stall must recur every iteration (the RTL final cyc tracks the golden, not a
# much-lower one-stall-only count). INFO-only (not a hard gate band): the hard
# AGI band is mb_agi.
#
#   loop body:  lea (%esi),%esi   # writes esi   (cycle T)
#               mov (%esi),%eax   # base esi, written last clock -> AGI +1
#   esi -> own code (mapped, readable in both QEMU and the flat image).
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $0x08048000, %esi       # esi = mapped, readable (own code base)
    movl    $400, %ecx              # iteration count
.Lloop:
    leal    (%esi), %esi            # writes esi this clock
    movl    (%esi), %eax            # AGI: base esi written immediately prior
    decl    %ecx                    # loop counter
    jne     .Lloop                  # backward branch (predict-taken steady state)

    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80
