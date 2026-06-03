# =============================================================================
# Ventium M3 x87 test: tx_stack -- stack management ops (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m3-fpu-spec.md Tier 1 "stack management"): drive the TOP field of fstat
# across the FULL register stack (push 8 deep + wrap, then unwind to empty),
# exercising the stack-rotate and tag-clearing ops.
#
# Ops covered:
#   FXCH st(i)  (D9 C8+i)   -- swap st0 <-> st(i)
#   FINCSTP     (D9 F7)     -- TOP += 1 (no tag change)
#   FDECSTP     (D9 F6)     -- TOP -= 1
#   FFREE st(i) (DD C0+i)   -- tag st(i) empty (QEMU still reports ftag=0)
#   FNOP        (D9 D0)     -- no-op, no state change
#   FLD1 / FLDZ / FSTP      -- push/pop to move TOP (Tier 1 moves)
#
# fstat TOP convention (verified): each push decrements TOP by 1 (8->7->...->0
# ->7 wrap); each pop increments it. fctrl stays 0x037f; QEMU reports ftag=0x0000
# in all cases (abridged g-packet, even for a full or freed stack).
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- FNOP at empty stack (no-op baseline) -------------------------------
    fnop                    # nothing changes

    # ---- push 8 deep: TOP 000 -> 111 -> ... -> 000 (full wrap) --------------
    fld1                    # TOP=111 (1.0)
    fldz                    # TOP=110 (0.0)
    fld1                    # TOP=101
    fldz                    # TOP=100
    fld1                    # TOP=011
    fldz                    # TOP=010
    fld1                    # TOP=001
    fldz                    # TOP=000  -- stack now FULL (8 values)

    # ---- FXCH: swap st0 (0.0) with st(7) (a 1.0) ----------------------------
    fxch    %st(7)          # st0 becomes 1.0, st7 becomes 0.0
    fxch    %st(1)          # swap st0 <-> st1 (1.0 <-> 0.0 region)
    fxch                    # bare FXCH = FXCH st(1), swap back

    # ---- FINCSTP / FDECSTP: rotate TOP without touching tags ----------------
    fincstp                 # TOP 000 -> 001
    fincstp                 # TOP 001 -> 010
    fdecstp                 # TOP 010 -> 001
    fdecstp                 # TOP 001 -> 000

    # ---- FFREE: mark some slots empty (does not move TOP) -------------------
    ffree   %st(0)          # free current top
    ffree   %st(3)          # free a middle slot
    ffree   %st(7)          # free the bottom slot

    # ---- FNOP again, then unwind the stack to empty -------------------------
    fnop
    fstp    %st(0)          # pop  (TOP 000 -> 001)
    fstp    %st(0)          # pop
    fstp    %st(0)          # pop
    fstp    %st(0)          # pop
    fstp    %st(0)          # pop
    fstp    %st(0)          # pop
    fstp    %st(0)          # pop
    fstp    %st(0)          # pop  -> TOP back to 000, stack empty

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax        # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80           # halt
