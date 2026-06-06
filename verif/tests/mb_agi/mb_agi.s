# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M4 cycle microbench: mb_agi
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# ANALYTIC P5 BEHAVIOUR (ported from ventium-refs/.../tools/microbench.c "agi"):
#   Produce an address-base register, then USE it as the base of a memory operand
#   in the immediately following instruction. The P5 address-generation interlock
#   (AGI) inserts a 1-cycle stall whenever an instruction's address base/index reg
#   was written in the *immediately preceding* core clock (AP-500). p5model fires
#   it when reg_wcycle[base] == issue-1.
#
#   The repeated body is:
#       lea (%esi), %esi        # writes %esi          (cycle T)
#       mov (%esi), %eax        # uses %esi as base    (wants cycle T+1 -> AGI +1)
#   Every `mov` reuses %esi one clock after the `lea` wrote it, so an AGI stall
#   fires on essentially every iteration. The gate requires agi_stalls to be a
#   large fraction of the instruction count (>20%); here it is ~ N/2 (one AGI per
#   lea/mov pair), i.e. ~50%.
#
#   %esi points at a small writable buffer (agibuf, .bss). The `mov` only reads it,
#   so its contents are irrelevant — but %esi must be a mapped, readable address,
#   hence a real .bss reservation that both QEMU (linux-user loader) and the
#   Verilator flat image map identically (same as t_mem's .data convention).
#
# STRUCTURE — hot loop (see mb_depadd.s for the I-cache rationale): a SMALL unrolled
#   body (150 lea/mov pairs) run 8 times keeps the body L1-resident, so the cycle
#   deltas reflect the real AGI interlock rather than one-time I-cache cold misses.
#   ~1200 pairs => ~2400 body insns; agi_stalls ~ 1200 (>20% of insns).
# =============================================================================

    .text
    .globl  _start
_start:
    leal    agibuf, %esi            # esi = &agibuf  (a mapped, readable address)
    movl    $8, %ecx                # ecx = outer iteration count
.Lrep:
    .rept   150
    leal    (%esi), %esi            # esi = esi  (writes esi this clock)
    movl    (%esi), %eax            # eax = mem[esi] ; esi just written => AGI stall
    .endr
    decl    %ecx                    # ecx-- (predictable back-edge)
    jnz     .Lrep

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80

# -----------------------------------------------------------------------------
# Writable scratch buffer (RW PT_LOAD; zero-filled). 16 longs like microbench.c.
# -----------------------------------------------------------------------------
    .bss
    .align  4
agibuf:
    .space  64
