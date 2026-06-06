# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M5 cycle microbench: mb_dmiss   (D-cache-miss cycle check)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (the new M5 D-cache-miss cycle check — docs/m5-cycle-spec.md §4):
#   The L1 D-cache is 8 KB / 2-way / 32-byte line / 128 sets (docs/p5-timing-model.md).
#   This kernel strides a load by EXACTLY one cache line (32 bytes) through a buffer
#   far larger than the cache (32 KB = 1024 lines >> 256-line capacity), then sweeps
#   it repeatedly. Because each load touches a brand-new 32-byte line and the working
#   set (1024 lines) cannot fit in the cache (256 lines), every line is evicted long
#   before the next sweep revisits it => EVERY load misses. A D-cache read miss adds
#   the p5model penalty dmiss=8 cycles (read-allocate), charged on the instruction
#   that retires after the load (the model defers the data-stall via pending_mem_pen,
#   verif/qemu-plugins/p5trace.c). The loop body is `load; add $32,%esi; dec %ecx; jnz`
#   = 4 insns, so a near-certain 8-cycle miss per load lifts CPI well above 1
#   (to ~2.5) — the emergent signature of D-cache-miss timing.
#
# DETERMINISM:
#   * The buffer is `.p2align 5` (32-byte aligned) and the load is 4-byte aligned at
#     every stride => NO misaligned (+3) penalty, NO D-bank-conflict ambiguity: the
#     elevation is PURELY the miss penalty.
#   * `.bss` zero-initialised buffer; the loads only read (read-allocate miss path).
#   * Stride 32 == line size guarantees one fresh line per load, deterministically.
#   * 1024 lines * 2 sweeps = 2048 loads, all missing; ~8 K retired insns total —
#     a stable, miss-dominated CPI. The miss pattern is identical every sweep (the
#     working set never fits), so the per-load cost is steady-state from sweep 1.
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $2, %edx                # edx = number of full sweeps over the buffer
.Lsweep:
    leal    buf, %esi               # esi = buffer base (re-loaded each sweep)
    movl    $1024, %ecx             # 1024 lines per sweep (1024*32 = 32 KB >> 8 KB)
.Lline:
    movl    (%esi), %eax            # LOAD: new 32-byte line each iter => D-cache MISS (+8)
    addl    $32, %esi               # advance to the next cache line
    decl    %ecx                    # ecx-- (predictable back-edge)
    jnz     .Lline
    decl    %edx                    # next sweep
    jnz     .Lsweep
    # 2048 loads, ~100% D-cache miss; CPI ~ 2.5 (miss-driven, dmiss=8).

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80

    # ---- 32 KB zero buffer (>> 8 KB / 2-way D-cache) ------------------------
    .bss
    .p2align 5                      # 32-byte (cache-line) aligned => no misalign penalty
buf:
    .space  32768                   # 1024 cache lines
