# =============================================================================
# Ventium M2 test: t_carry  --  STC / CLC / CMC (the carry-flag trio)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# Regression-locks the adversarial-review finding that STC (0xF9), CLC (0xF8)
# and CMC (0xF5) were NOT decoded by the one-byte opcode map and fell through
# to the default arm (d_unknown -> HALT). They are part of the user-mode integer
# ISA (CLD/STD were implemented; the CF trio was missing). A program doing
# `stc; adc ...` would halt mid-stream.
#
# Semantics:
#   STC -> CF=1, CLC -> CF=0, CMC -> CF=^CF; NO other flags change.
# We prove the CF value both directly (eflags compare) and by consuming it with
# ADC/RCL so a wrong CF corrupts a checked register. All flags here are defined.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- direct STC/CLC/CMC sequence (eflags CF observed each step) ---------
    clc                             # CF = 0
    stc                             # CF = 1
    cmc                             # CF = 0 (toggle)
    cmc                             # CF = 1 (toggle)
    clc                             # CF = 0
    stc                             # CF = 1
    cmc                             # CF = 0

    # ---- STC then ADC: CF=1 must be added in --------------------------------
    movl    $0x00000010, %eax       # eax = 0x10
    stc                             # CF = 1
    adcl    $0x00000000, %eax       # eax = 0x11 (CF folded in), CF=0 after

    # ---- CLC then ADC: CF=0, no extra added ---------------------------------
    movl    $0x00000020, %ecx       # ecx = 0x20
    clc                             # CF = 0
    adcl    $0x00000001, %ecx       # ecx = 0x21

    # ---- STC then RCL by 1: CF rotated into bit0 ----------------------------
    movl    $0x00000000, %edx       # edx = 0
    stc                             # CF = 1
    rcll    $1, %edx                # edx = 0x00000001 (CF -> bit0), new CF=0

    # ---- CMC chained with arithmetic-set CF ---------------------------------
    movl    $0xFFFFFFFF, %ebx
    addl    $0x00000001, %ebx       # ebx = 0, CF=1 (carry out)
    cmc                             # CF = 0 (toggle the arithmetic carry)
    movl    $0x00000005, %esi
    adcl    $0x00000000, %esi       # esi = 0x05 (CF was 0)

    # ---- CLC/STC do not disturb ZF/SF/OF/PF set by a prior op ---------------
    movl    $0x00000000, %edi
    addl    $0x00000000, %edi       # ZF=1, SF=0, OF=0, CF=0
    stc                             # only CF flips to 1; ZF must stay 1
    clc                             # only CF flips to 0; ZF must stay 1

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
