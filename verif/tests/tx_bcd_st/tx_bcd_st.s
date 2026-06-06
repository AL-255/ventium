# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M10 x87 test: tx_bcd_st -- FBSTP packed-BCD store + pop (DF /6)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m3-fpu-spec.md, formerly "DEFERRED -- loud HALT"): FBSTP rounds st0 to an
# integer (per the control-word RC), encodes it as an 80-bit packed-BCD integer
# (18 digits + sign byte), stores 10 bytes to memory, and pops. Memory is NOT
# gate-compared, so each result is READ BACK into a GPR (eax/edx/ecx live-graded)
# so QEMU and the RTL must agree on the exact BCD bytes. fstat (with IE) is graded
# directly, so the overflow->BCD-indefinite+IE path is checked too.
#
# Cases: +42, -42 (sign byte), 2.5/3.5 (round-to-nearest-even -> 2 / 4), and a
# >1e18 value (BCD overflow -> the indefinite image + IE). All exact-int / classic
# round-to-even inputs, no ambiguity.
#
# Packed-BCD read-back: movl out+0 -> low 4 bytes, movl out+4 -> next 4, movzwl
# out+8 -> byte8 (digits 16-17) + byte9 (sign in bit7).
#
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    fninit                          # clean x87 state

    # ---- A: +42 ------------------------------------------------------------
    fildl   seed42                  # st0 = +42
    fbstp   out_a                   # BCD(+42) -> out_a, pop
    movl    out_a,   %eax           # eax = 0x00000042
    movl    out_a+4, %edx           # edx = 0
    movzwl  out_a+8, %ecx           # ecx = 0x0000

    # ---- B: -42 (sign byte 0x80) -------------------------------------------
    fildl   seed_neg42              # st0 = -42
    fbstp   out_b                   # BCD(-42) -> out_b, pop
    movl    out_b,   %eax           # eax = 0x00000042
    movl    out_b+4, %edx           # edx = 0
    movzwl  out_b+8, %ecx           # ecx = 0x8000 (byte9 sign)

    # ---- C: 2.5 -> round-to-nearest-even -> 2 ------------------------------
    fldl    f2_5                    # st0 = 2.5
    fbstp   out_c                   # BCD(2) -> out_c, pop
    movl    out_c,   %eax           # eax = 0x00000002

    # ---- D: 3.5 -> round-to-nearest-even -> 4 ------------------------------
    fldl    f3_5                    # st0 = 3.5
    fbstp   out_d                   # BCD(4) -> out_d, pop
    movl    out_d,   %eax           # eax = 0x00000004

    # ---- E: 5e18 (>1e18) -> BCD overflow -> indefinite image + IE ----------
    fnclex                          # clear status so IE is attributable
    fildll  seed_big                # st0 = 5_000_000_000_000_000_000 (exact int64)
    fbstp   out_e                   # overflow -> BCD-indefinite, IE set, pop
    movl    out_e,   %eax           # eax = indefinite low  (oracle-pinned)
    movl    out_e+4, %edx           # edx = indefinite mid
    movzwl  out_e+8, %ecx           # ecx = indefinite high (+ sign)
    # fstat.IE is now set and is graded directly vs QEMU

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80                   # halt

    # =========================================================================
    .data
    .align 16
seed42:     .long  42
seed_neg42: .long  -42
f2_5:       .double 2.5
f3_5:       .double 3.5
seed_big:   .quad  5000000000000000000

out_a:      .byte 0,0,0,0,0,0,0,0,0,0
out_b:      .byte 0,0,0,0,0,0,0,0,0,0
out_c:      .byte 0,0,0,0,0,0,0,0,0,0
out_d:      .byte 0,0,0,0,0,0,0,0,0,0
out_e:      .byte 0,0,0,0,0,0,0,0,0,0
