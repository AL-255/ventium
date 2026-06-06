# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 x87 test: tx_ctl -- control/status word management (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m3-fpu-spec.md Tier 1 "Status/control"): read and write the control
# word (rounding RC + precision PC bits), reinitialize the FPU, clear the
# exception flags, and store the status word both to AX and to memory.
#
# Ops covered:
#   FNSTCW m16 (D9 /7), FLDCW m16 (D9 /5)
#   FNINIT (DB E3)  -- reset control=0x037f, status=0, stack empty
#   FNCLEX (DB E2)  -- clear exception flags (and the busy bit)
#   FNSTSW AX (DF E0) and FNSTSW m16 (DD /7)
#
# Control-word values exercised (verified fctrl readback):
#   default 0x037f : RC=00 (round nearest), PC=11 (64-bit), all 6 masks set
#   0x0c7f         : RC=11 (toward zero)
#   0x0477         : RC=00, PC=10 (53-bit), with PM unmasked toggled? -- here we
#                    use only the well-defined RC/PC bits, masks stay set
#   0x0e7f         : RC=11 (toward zero) + PC=10? No -- use 0x0a7f (RC=10 up)
# We only ever load control words that QEMU echoes back verbatim in fctrl; the
# reserved bit 6 and the always-1 bit ordering follow QEMU's softfloat model.
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- read the reset/default control word --------------------------------
    fnstcw  cw_a            # cw_a = 0x037f (default after process start)

    # ---- change rounding control: RC=11 (toward zero) -> 0x0c7f -------------
    movw    $0x0c7f, %ax
    movw    %ax, scratch
    fldcw   scratch         # fctrl = 0x0c7f
    fnstcw  cw_b            # read it back (cw_b = 0x0c7f)

    # ---- change rounding control: RC=10 (toward +inf) -> 0x0a7f -------------
    movw    $0x0a7f, %ax
    movw    %ax, scratch
    fldcw   scratch         # fctrl = 0x0a7f
    fnstcw  cw_c            # cw_c = 0x0a7f

    # ---- change precision control: PC=10 (53-bit double) -> 0x027f ----------
    movw    $0x027f, %ax
    movw    %ax, scratch
    fldcw   scratch         # fctrl = 0x027f (RC=00 nearest, PC=10)
    fnstcw  cw_d            # cw_d = 0x027f

    # ---- store status word to AX and to memory ------------------------------
    fld1                    # push 1.0 so TOP is non-zero in the stored status
    fnstsw  %ax             # ax = fstat (TOP=111, no exceptions)
    fnstsw  sw_a            # also to m16
    fstp    %st(0)          # pop -> empty

    # ---- FNCLEX: clear exception flags (none set, but exercise the op) ------
    fnclex
    fnstsw  sw_b            # status after clear

    # ---- FNINIT: reinitialize -> control 0x037f, status 0, empty stack ------
    fninit
    fnstcw  cw_e            # cw_e = 0x037f (control reset)
    fnstsw  sw_c            # sw_c = 0x0000 (status reset)

    # ---- one more readback after init to confirm 0x037f sticks --------------
    fldcw   cw_e            # load the just-stored 0x037f back
    fnstcw  cw_f            # cw_f = 0x037f

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax        # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80           # halt

    # =========================================================================
    .data
    .align 4
scratch: .short 0
cw_a:    .short 0
cw_b:    .short 0
cw_c:    .short 0
cw_d:    .short 0
cw_e:    .short 0
cw_f:    .short 0
sw_a:    .short 0
sw_b:    .short 0
sw_c:    .short 0
