# =============================================================================
# Ventium M5 cycle microbench: mb_imiss   (I-cache-miss cycle check)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (the new M5 I-cache-miss cycle check -- docs/m5-cycle-spec.md sec 4):
#   The L1 I-cache is 8 KB / 2-way / 32-byte line / 128 sets => 256 lines capacity
#   (docs/p5-timing-model.md). This kernel's loop body is built so that EVERY
#   instruction sits on its own 32-byte cache line (forced by `.p2align 5` before
#   each insn). The body spans 400 distinct lines -- FAR more than the 256-line
#   I-cache -- so on every loop pass the early lines have already been evicted by
#   the later lines of the SAME pass (2-way LRU), and re-fetching them costs the
#   p5model penalty imiss=8 cycles. Instruction fetch therefore misses recurrently
#   (steady-state ~50%: pass 1 cold-misses all 400 lines, passes 2..5 re-miss them),
#   and each miss adds 8 cycles to the fetching instruction's cost
#   (verif/qemu-plugins/p5trace.c: !l1_access(icache) => pipe_free_at += imiss).
#   The result is CPI ~ 6.0 -- the emergent signature of I-cache-miss timing,
#   vs ~1 for an I-cache-resident loop.
#
# DETERMINISM:
#   * One instruction per 32-byte line => exactly one I-fetch (one possible miss)
#     per retired instruction; no line-straddle ambiguity, no second-line refs.
#   * The body (400 lines) deterministically exceeds the 256-line cache, so the
#     evict/re-miss pattern is fixed and reproducible across passes.
#   * No data accesses (pure `movl $imm,%reg`) => 0 D-cache traffic; the elevation
#     is PURELY I-cache miss cycles.
#   * 400 lines * 5 passes ~= 2000 body insns (4019 total incl. loop overhead) --
#     a stable, miss-dominated CPI in the few-thousand-insn range.
#
# GENERATED: the 400-line body below is mechanically emitted (each line is the
#   identical `movl $1,%eax` preceded by `.p2align 5`). It is checked in verbatim
#   so the gate builds it directly; regenerate with the loop in verif (n=400).
# =============================================================================

    .text
    .globl  _start
    .p2align 5
_start:
    movl    $5, %ecx           # ecx = loop pass count
.L:
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    movl    $1, %eax
    .p2align 5
    decl    %ecx                    # ecx-- (predictable back-edge; BTB-learned)
    jnz     .L
    # ~2000 own-line body insns over 5 passes; I-cache thrashes; CPI ~ 6.0.

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80
