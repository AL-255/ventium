# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_bound  --  BOUND r, m  (0x62)  [in-bounds paths only]
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# BOUND index, m: SIGNED check  lower <= index <= upper, where lower=[m] and
# upper=[m+w]. Out of range raises #BR (vector 5) — which under linux-user is a
# signal that ends the trace, so this test exercises ONLY the in-bounds (non-
# faulting) paths: BOUND then retires with no register/flag change, so the whole
# architectural image must stay diff-clean vs QEMU. Covers 32-bit and 16-bit
# (0x66) bounds, the lower/upper edges, and a negative-lower signed range.
# =============================================================================

    .text
    .globl  _start
_start:

    leal    bnd32, %ebx             # base of the 32-bit [lower, upper] pair

    # ---- 32-bit, comfortably inside [0x10, 0x100] ---------------------
    movl    $0x50, %eax
    bound   %eax, (%ebx)            # 0x10 <= 0x50 <= 0x100 -> OK

    # ---- 32-bit, exactly the LOWER edge (inclusive) ------------------
    movl    $0x10, %eax
    bound   %eax, (%ebx)            # index == lower -> OK

    # ---- 32-bit, exactly the UPPER edge (inclusive) ------------------
    movl    $0x100, %eax
    bound   %eax, (%ebx)            # index == upper -> OK

    # ---- 32-bit, NEGATIVE signed range [-0x80, +0x7F] ----------------
    leal    bnd32n, %ebx
    movl    $-5, %eax
    bound   %eax, (%ebx)            # -0x80 <= -5 <= 0x7F (signed) -> OK
    movl    $0x7F, %eax
    bound   %eax, (%ebx)            # upper edge -> OK

    # ---- 16-bit (0x66) inside [0x0100, 0x0F00] -----------------------
    leal    bnd16, %ebx
    movl    $0x12340200, %eax       # AX = 0x0200 (upper EAX preserved, unused)
    bound   %ax, (%ebx)             # 0x0100 <= 0x0200 <= 0x0F00 -> OK

    # ---- clean exit: Linux i386 _exit(0) -------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 4
bnd32:   .long 0x00000010, 0x00000100      # lower, upper (32-bit)
bnd32n:  .long -0x80,       0x0000007F      # negative lower (signed)
bnd16:   .short 0x0100, 0x0F00             # lower, upper (16-bit)
