# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_shift  --  SHL/SHR/SAR/SAL by 1, imm8, CL; count masking
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -nostdlib -static -Wl,-Ttext=0x08048000
#
# Bucket: shifts. Covers the D0/D1/D2/D3 and C0/C1 group, /4 SHL /5 SHR
# /6 SAL(=SHL) /7 SAR. Forms: by 1 (D1/r), by imm8 (C1/r ib), by CL (D3/r),
# plus 8-bit (D0/C0) variants. Count is masked to 5 bits (& 0x1f) on 386+;
# count == 0 leaves ALL flags unchanged (verified explicitly below).
#
# EFLAGS undefined after these ops (must be masked by the comparator table):
#   SHL/SHR/SAR: OF undefined for count != 1, AF always undefined.
#   For count == 0 no flags change at all (we test that the *result* is
#   unchanged AND we anchor flags by re-establishing them with a defined op).
# So this program is diff-clean iff the comparator masks OF+AF for shl/shr/sar.
#
# Operand edge values exercised: 0, 1, 0x7fffffff, 0x80000000, 0xffffffff.
# Shift counts exercised: 0, 1, 5, 31, 32 (-> &0x1f -> 0, no-op), 33 (-> 1).
# Both register-destination and (no memory shift here to keep it simple).
# =============================================================================

    .text
    .globl  _start
_start:

    # ---- SHL by 1 (D1 /4) over edge values ----------------------------------
    movl    $0x00000001, %eax
    shll    $1, %eax                # eax = 0x00000002  (CF=0, OF=0 since count==1)

    movl    $0x80000000, %eax
    shll    $1, %eax                # eax = 0, CF=1, OF=1 (count==1, OF defined)

    movl    $0x40000000, %eax
    shll    $1, %eax                # eax = 0x80000000, CF=0, OF=1 (sign change)

    # ---- SHL by imm8 = 5 (C1 /4 ib): OF undefined since count != 1 ----------
    movl    $0x0000000f, %eax
    shll    $5, %eax                # eax = 0x000001e0 (OF undefined, count!=1)

    # ---- SHL by imm8 = 32 -> masked to 0 -> NO-OP, flags UNCHANGED ----------
    # Establish a known flag state with a defined op first, then shift-by-32
    # must leave both the value AND the flags exactly as they were.
    movl    $0x12345678, %eax
    addl    $0, %eax                # defined flags: ZF=0,SF=0,CF=0,OF=0,PF,...
    shll    $32, %eax               # 32 & 0x1f == 0  -> no change to eax or flags

    # ---- SHL by imm8 = 33 -> masked to 1 ------------------------------------
    movl    $0x00000001, %eax
    shll    $33, %eax               # 33 & 0x1f == 1 -> eax = 0x00000002

    # ---- SHL by CL (D3 /4) --------------------------------------------------
    movl    $0x00000003, %eax
    movl    $4, %ecx
    shll    %cl, %eax               # eax = 0x00000030

    movl    $0xffffffff, %eax
    movl    $31, %ecx
    shll    %cl, %eax               # eax = 0x80000000, CF=1

    movl    $0xcafebabe, %eax
    movl    $32, %ecx               # CL=32 -> &0x1f -> 0 -> no-op
    movl    $0xdeadbeef, %ebx
    testl   %ebx, %ebx              # defined flag anchor (ZF=0,SF=1,CF=0,OF=0)
    shll    %cl, %eax               # no change to eax/flags

    movl    $0x00000001, %eax
    movl    $33, %ecx               # CL=33 -> &0x1f -> 1
    shll    %cl, %eax               # eax = 0x00000002

    # ---- SHR by 1 / imm / CL (D1 /5, C1 /5, D3 /5) --------------------------
    movl    $0xffffffff, %eax
    shrl    $1, %eax                # eax = 0x7fffffff, CF=1, OF=0 (count==1)

    movl    $0x80000000, %eax
    shrl    $1, %eax                # eax = 0x40000000, CF=0, OF=1 (MSB shifted)

    movl    $0xfedcba98, %eax
    shrl    $5, %eax                # eax = 0x07f6e5d4 (OF undefined)

    movl    $0x80000000, %eax
    shrl    $31, %eax               # eax = 0x00000001, CF=0

    movl    $0x80000000, %eax
    movl    $4, %ecx
    shrl    %cl, %eax               # eax = 0x08000000

    # SHR count == 0 via CL: result and flags unchanged
    movl    $0x0000abcd, %eax
    movl    $0, %ecx
    cmpl    $0x1234, %eax           # defined flag anchor
    shrl    %cl, %eax               # CL==0 -> no change at all

    # ---- SAR by 1 / imm / CL (D1 /7, C1 /7, D3 /7) --------------------------
    movl    $0xffffffff, %eax
    sarl    $1, %eax                # eax = 0xffffffff (arithmetic, sign keeps), CF=1

    movl    $0x80000000, %eax
    sarl    $1, %eax                # eax = 0xc0000000, CF=0

    movl    $0x7fffffff, %eax
    sarl    $5, %eax                # eax = 0x03ffffff (OF undefined)

    movl    $0x80000000, %eax
    sarl    $31, %eax               # eax = 0xffffffff (all sign bits)

    movl    $0x7fffffff, %eax
    movl    $31, %ecx
    sarl    %cl, %eax               # eax = 0x00000000

    movl    $0xfff00000, %eax
    movl    $8, %ecx
    sarl    %cl, %eax               # eax = 0xfffff000

    # ---- SAL (== SHL, /6 alias decodes to SHL) ------------------------------
    movl    $0x00000005, %eax
    sall    $2, %eax                # eax = 0x00000014

    # ---- 8-bit shifts (D0/C0/D2): partial-register preserved-bits -----------
    # Writing AL updates [7:0] and PRESERVES [31:8]. Flags on the 8-bit result.
    movl    $0xaabbcc81, %eax       # AL=0x81
    shlb    $1, %al                 # AL = 0x02, CF=1, OF=1 (bit7->bit8). [31:8]=0xaabbcc
    movl    $0xaabbcc80, %eax       # AL=0x80
    sarb    $1, %al                 # AL = 0xc0 (sign). [31:8] preserved
    movl    $0x11223340, %eax       # AL=0x40
    movb    $2, %cl
    shlb    %cl, %al                # AL = 0x00, CF=1 (0x40<<2). [31:8] preserved

    # (SHLD/SHRD live in the sibling program t_shld — same shift datapath, but
    #  a distinct opcode group 0F A4/A5/AC/AD, kept separate for size/clarity.)

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
