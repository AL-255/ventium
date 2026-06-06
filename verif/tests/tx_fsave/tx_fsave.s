# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M11b x87 test: tx_fsave -- FNSAVE (108-byte state store) + FRSTOR
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87. gcc -m32 -march=pentium.
#
# FNSAVE (DD /6) writes the 28-byte env + the 8 ten-byte ST registers (logical
# order, empty->0), then reinitializes the FPU (= FNINIT). FRSTOR (DD /4) reads it
# all back, restoring CW/SW/TOP/tags + the 8 ST regs. Memory isn't gate-compared,
# so the saved env + ST0 bytes are read back into GPRs; the post-FNSAVE reinit and
# the post-FRSTOR restore are checked via live (graded) fstat/st0.
#
# Exit: Linux i386 _exit(0) -> int 0x80.
# =============================================================================
    .text
    .globl  _start
_start:
    fninit
    fildl   v0              # st0 = 17  (ST2 after the next two pushes)
    fildl   v1              # st0 = 34  (ST1)
    fildl   v2              # st0 = 51  (ST0); TOP = 5
    fnsave  area            # write 108-byte image; then FNINIT-reinit the FPU
    # saved env (pre-reinit state):
    movl    area+0,  %eax   # CW  = 0x037F
    movl    area+4,  %ecx   # SW  = 0x2800 (TOP=5)
    movl    area+8,  %edx   # FTW = 0x03FF (phys5/6/7 valid)
    # saved ST0 (= 51 = floatx80 0x4004cc00000000000000) at +28:
    movl    area+28, %ebx   # ST0 mantissa[31:0]  = 0x00000000
    movl    area+32, %esi   # ST0 mantissa[63:32] = 0xcc000000
    movzwl  area+36, %edi   # ST0 sign/exp        = 0x00004004
    # post-FNSAVE the LIVE FPU is reinitialized: SW=0x0000 (TOP=0, all empty):
    fnstsw  %ax
    movzwl  %ax, %ebp       # ebp = 0x0000

    # --- FRSTOR round-trip: CLOBBER the regs first (so the reload is observable) --
    fildl   vx              # st0 = 999 (clobbers a phys reg)
    fildl   vx              # clobber another
    fildl   vx              # clobber a third (phys5/6/7 now = 999, != saved 51/34/17)
    frstor  area            # reload CW/SW/TOP/tags + the 8 ST regs from the image
    fnstsw  %ax
    movzwl  %ax, %eax       # eax = 0x2800 (TOP=5 restored)
    fistpl  back0           # store ST0 as int, pop
    movl    back0, %ecx     # ecx = 51 (0x33) -> ST0 restored to v2 (NOT the clobber 999)

    # --- STALE empty slot: FNSAVE must dump the raw reg bytes even for empty slots
    #     (qemu do_fstt is unconditional), NOT zero them. ---
    fninit
    fldpi                   # phys7 = pi, TOP=7
    fstp    %st(0)          # pop -> phys7 EMPTY but fpr[7] keeps pi (stale); TOP=0
    fnsave  area2           # ST7 (= phys7, empty, stale pi) lands at +98
    movl    area2+98,  %esi # esi = stale pi mantissa[31:0] = 0x2168c235 (NOT 0)
    movl    area2+102, %edi # edi = stale pi mantissa[63:32] = 0xc90fdaa2

    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 16
v0:    .long 17
v1:    .long 34
v2:    .long 51
vx:    .long 999
back0: .long 0
area:  .fill 108, 1, 0
area2: .fill 108, 1, 0
