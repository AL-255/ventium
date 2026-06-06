# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M6 errata test: err_fist -- FIST/FISTP overflow undetected (Erratum 20)
# =============================================================================
# Spec: pentium-spec-update-242480-022.pdf doc p.75, "Overflow Undetected on Some
# Numbers on FIST". For FIST[P] m16int / m32int (NOT m64), in 'nearest' or 'up'
# rounding, a POSITIVE operand just above the destination's signed max (with the
# documented bit pattern) fails to flag integer overflow:
#   ACTUAL (P5)  : stores ZERO to memory, IE (invalid-op) NOT set.
#   EXPECTED     : stores the integer-indefinite (0x80000000) and sets IE.
#
# Test operand: 4294967295.5 = 2^32 - 0.5  (unbiased exp 31, top 33 significand
# bits = 1 -> the documented 32-bit/nearest affected operand). Default control
# word 0x037F = round-nearest-even (an affected mode). Rounds to 2^32, which
# overflows signed int32.
#
# SELF-CHECK (verif/errata/run-m6.sh), via the trace (memory is not traced, so we
# read the stored dword back into EAX and snapshot the FPU status word into the
# DX:AX pair through FNSTSW):
#   errata ON  : EAX == 0x00000000 (buggy zero), status-word IE bit (bit0) == 0.
#   errata OFF : EAX == 0x80000000 (integer-indefinite), status-word IE bit == 1.
#
# Freestanding 32-bit i386 (P5). Ends with _exit(0) (int 0x80).
# =============================================================================

    .text
    .globl  _start
_start:
    fninit                      # clean FPU state, cw = 0x037F (round-nearest)
    fldl    operand             # st0 = 4294967295.5 (the affected 32-bit operand)
    fistpl  outdword            # FISTP m32: store st0 as int32 -> outdword (pops)

    # Bring the stored dword into EAX so the trace captures the result.
    movl    outdword, %eax      # EAX = stored int32 (0 buggy / 0x80000000 clean)

    # Snapshot the FPU status word into AX-of-EDX so the trace captures the IE
    # bit (bit0). Use a separate register: store AX via FNSTSW then move to EDX.
    fnstsw  %ax                 # AX = FPU status word (overwrites AX; EAX hi kept)
    movzwl  %ax, %edx           # EDX = status word (IE = bit0)

    # Re-load the result so EAX holds it again at the FINAL retire (FNSTSW clobbers
    # AX above). EAX[31:0] = stored value; EDX[15:0] = status word.
    movl    outdword, %eax      # EAX = stored int32 (final witness)

    # clean exit
    movl    %eax, %esi          # ESI = result witness (EAX about to be clobbered)
    movl    %edx, %edi          # EDI = status-word witness
    movl    $1, %eax            # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 8
operand:    .double 4294967295.5
    .align 4
outdword:   .long 0
