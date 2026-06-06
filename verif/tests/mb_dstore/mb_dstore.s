# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M5 regression: mb_dstore   (D-cache state warmed by STORES)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# REGRESSION for M5 adversarial finding [med] (D-cache state: stores and slow-path
# displacement loads bypassed the timing model). The oracle's p5_mem runs
# l1_access for EVERY memory op including STORES (read-allocate write-back:
# allocate/update LRU, no miss penalty) — verif/qemu-plugins/p5trace.c:500-510. M4
# only mutated the D-cache from the fast-path register-indirect load, so a line a
# STORE had warmed was wrongly counted as a miss by a later load (divergent miss
# sequence). M5 runs dc_access on slow-path stores AND slow-path loads.
#
# STRUCTURE: a counted loop that, each pass, STOREs to a set of cache lines and
# then re-reads them with register-indirect loads. Because the stores warm the
# lines, the reads HIT (no dmiss=8) — exactly the oracle's behaviour. If the
# stores did not warm the D-cache the reads would all miss and CPI would be far
# higher than the oracle, so the abs-cyc tracking is the regression check.
# The buffer is .bss, 32-byte aligned, small enough to stay resident in the
# 8 KB / 2-way D-cache across the loop.
# =============================================================================
    .text
    .globl  _start
_start:
    movl    $50, %ecx               # outer iterations
.Lrep:
    leal    buf, %esi               # esi = buffer base
    movl    $0x11111111, 0(%esi)    # STORE line 0  (warms it)
    movl    $0x22222222, 32(%esi)   # STORE line 1  (disp store -> slow path)
    movl    $0x33333333, 64(%esi)   # STORE line 2
    movl    $0x44444444, 96(%esi)   # STORE line 3
    movl    0(%esi),  %eax          # reg-indirect LOAD line 0 -> HIT (store warmed)
    addl    $32, %esi
    movl    (%esi),   %edx          # LOAD line 1 -> HIT
    addl    $32, %esi
    movl    (%esi),   %ebx          # LOAD line 2 -> HIT
    addl    $32, %esi
    movl    (%esi),   %edi          # LOAD line 3 -> HIT
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80
    .bss
    .p2align 5
buf:
    .space  256
