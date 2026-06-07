# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_endbr -- CET endbr32/endbr64 + multi-byte NOP (0F 1E / 0F 1F)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -nostdlib -static -Wl,-Ttext=0x08048000
#
# Bucket: nop/decode. F3 0F 1E FB (endbr32), F3 0F 1E FA (endbr64), and 0F 1F /r
# (the canonical multi-byte NOP, every mod/SIB/disp form) are HINT-NOPs on a
# non-CET CPU. qemu (any -cpu) retires them as NOPs; the Ventium core used to
# HALT (d_unknown), stranding CET-compiled binaries (musl/libgcc emit endbr32 at
# function entries -- it hung Quake at __divmoddi4). This test executes every
# encoding INTERLEAVED with ALU ops: if the core mis-decodes the LENGTH the
# instruction stream misaligns and the differential vs qemu diverges; if it fails
# to treat them as NOPs a register/flag changes. Either way the gate catches it.
#
# Exit: Linux i386 _exit(0) -> int 0x80.
# =============================================================================
    .text
    .globl  _start
_start:
    movl    $0x11111111, %eax
    movl    $0x22222222, %ebx
    movl    $0x33333333, %ecx
    movl    $0x44444444, %edx
    movl    $0x55555555, %esi
    movl    $0x66666666, %edi

    .byte 0xf3,0x0f,0x1e,0xfb        # endbr32
    addl    $1, %eax                 # eax = 0x11111112
    .byte 0xf3,0x0f,0x1e,0xfa        # endbr64
    addl    $1, %ebx                 # ebx = 0x22222223

    .byte 0x0f,0x1f,0x00             # nop (%eax)             (mod=00 rm=000)
    xorl    %ecx, %ecx               # ecx = 0, sets ZF/PF
    .byte 0x0f,0x1f,0x40,0x00        # nop 0x0(%eax)          (mod=01 disp8)
    incl    %ecx                     # ecx = 1, clears ZF
    .byte 0x0f,0x1f,0x80,0x00,0x00,0x00,0x00   # nop 0x0(%eax) (mod=10 disp32)
    addl    %edx, %esi               # esi += edx (flags update)
    .byte 0x0f,0x1f,0x44,0x00,0x00   # nop 0x0(%eax,%eax,1)   (SIB, disp8)
    subl    $0x10, %edi
    .byte 0x66,0x0f,0x1f,0x44,0x00,0x00        # nopw 0x0(%eax,%eax,1) (66 prefix)
    shll    $1, %eax
    .byte 0x0f,0x1f,0x04,0x00        # nop (%eax,%eax,1)      (SIB, no disp)
    notl    %ebx

    # a couple of plain NOPs + an endbr at the tail, then exit
    nop
    .byte 0xf3,0x0f,0x1e,0xfb        # endbr32
    orl     %eax, %edx

    movl    $1, %eax                 # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80
