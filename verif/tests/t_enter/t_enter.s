# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_enter  --  ENTER imm16, 0  (C8) + LEAVE round-trip
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# ENTER alloc, 0  (the nesting-level-0 form compilers emit) is:
#     push EBP;  EBP = ESP;  ESP = ESP - alloc
# i.e. one stack push followed by a frame-pointer set and a stack-allocation. It
# touches no flags. We exercise alloc = 0 / 16 / 256, fold ESP, EBP and the
# pushed value ([EBP]) into checked GPRs after each ENTER, and use the (already
# implemented) LEAVE to restore the frame between cases so ESP/EBP track QEMU
# exactly. The differential gate checks every GPR + EFLAGS after each retire.
#
# NOTE: only the level-0 32-bit form is decoded by the core; the nested form
# (level>0) and the 0x66 16-bit form intentionally raise the loud HALT, so this
# test deliberately uses level 0 only.
# =============================================================================

    .text
    .globl  _start
_start:

    movl    %esp, %esi              # esi = loader ESP (a stable marker)

    # ---- ENTER $0, $0  (no allocation) ---------------------------------
    movl    $0x11112222, %ebp       # frame-pointer marker (gets pushed)
    enter   $0, $0                  # push EBP; EBP=ESP-4; ESP=ESP-4
    movl    %ebp, %eax              # eax = new EBP (= old ESP - 4)
    movl    (%ebp), %edx            # edx = [EBP] = pushed old EBP = 0x11112222
    movl    %esp, %ecx              # ecx = ESP (= old ESP - 4 == new EBP)
    leave                           # EBP <- 0x11112222; ESP <- old ESP

    # ---- ENTER $16, $0  (allocate 16 bytes) ----------------------------
    movl    $0x33334444, %ebp
    enter   $16, $0                 # push EBP; EBP=ESP-4; ESP=ESP-4-16
    movl    %ebp, %eax              # eax = frame pointer
    movl    %esp, %ecx              # ecx = ESP (= EBP - 16)
    movl    (%ebp), %edx            # edx = pushed 0x33334444
    leave                           # restore

    # ---- ENTER $256, $0  (larger frame) --------------------------------
    movl    $0x55556666, %ebp
    enter   $256, $0                # push EBP; EBP=ESP-4; ESP=ESP-260
    movl    %ebp, %eax
    movl    %esp, %ecx
    movl    (%ebp), %edx
    leave

    # ---- clean exit: Linux i386 _exit(0) -------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
