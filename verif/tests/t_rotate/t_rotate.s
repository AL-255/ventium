# =============================================================================
# Ventium M2 test: t_rotate  --  ROL/ROR/RCL/RCR by 1, imm8, CL
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -nostdlib -static -Wl,-Ttext=0x08048000
#
# Bucket: rotates. Covers D0/D1/D2/D3 and C0/C1 group digits /0 ROL /1 ROR
# /2 RCL /3 RCR. Rotates affect ONLY CF and OF; all other flags are unchanged.
# OF is defined only for count == 1 and is UNDEFINED for count != 1.
# Count is masked to 5 bits (& 0x1f) for ROL/ROR (and for the result of RCL/RCR
# the rotate-through-carry uses a 33-bit modular count, but on P5 the count
# field itself is masked & 0x1f before the operation). count == 0 changes nothing.
#
# EFLAGS undefined after these ops (comparator table must mask):
#   ROL/ROR/RCL/RCR: OF undefined for count != 1; (CF defined).
# Diff-clean iff the comparator masks OF for rol/ror/rcl/rcr.
#
# To make the surrounding non-rotate flags deterministic and to keep ZF/SF/PF/AF
# "unchanged" trivially matched, each rotate is preceded by a defined-flag anchor
# only where a fresh sequence starts; rotates themselves never touch those bits.
#
# Edge values: 0x00000001, 0x80000000, 0xffffffff, 0x12345678; CF seeded both 0/1
# for RCL/RCR via a preceding add that produces a known carry.
# =============================================================================

    .text
    .globl  _start
_start:

    # ---- ROL by 1 (D1 /0) ---------------------------------------------------
    movl    $0x80000000, %eax
    roll    $1, %eax                # eax = 0x00000001, CF=1, OF=CF^msb=...(count==1)

    movl    $0x40000000, %eax
    roll    $1, %eax                # eax = 0x80000000, CF=0, OF=1 (msb changed)

    # ---- ROL by imm8 = 5 (C1 /0 ib) -----------------------------------------
    movl    $0x12345678, %eax
    roll    $5, %eax                # eax = (0x12345678 <<5 | >>27), OF undefined

    # ---- ROL by imm8 = 31 ---------------------------------------------------
    movl    $0x00000001, %eax
    roll    $31, %eax               # eax = 0x80000000

    # ---- ROL by imm8 = 32 -> masked to 0 -> no change (CF/OF unchanged) ------
    movl    $0xdeadbeef, %eax
    movl    $0x55555555, %ebx
    addl    %ebx, %ebx              # defines CF (0x5555..*2 has no carry -> CF=0)
    roll    $32, %eax               # 32&0x1f==0 -> eax unchanged, CF/OF unchanged

    # ---- ROL by CL (D3 /0) --------------------------------------------------
    movl    $0xff000000, %eax
    movl    $8, %ecx
    roll    %cl, %eax               # eax = 0x000000ff

    movl    $0x0000000f, %eax
    movl    $33, %ecx               # 33 & 0x1f == 1
    roll    %cl, %eax               # eax = 0x0000001e

    # ---- ROR by 1 / imm / CL (D1 /1, C1 /1, D3 /1) --------------------------
    movl    $0x00000001, %eax
    rorl    $1, %eax                # eax = 0x80000000, CF=1

    movl    $0x80000000, %eax
    rorl    $1, %eax                # eax = 0x40000000, CF=0, OF=1

    movl    $0x12345678, %eax
    rorl    $4, %eax                # eax = 0x81234567 (OF undefined)

    movl    $0xabcdef01, %eax
    movl    $16, %ecx
    rorl    %cl, %eax               # eax = 0xef01abcd

    # ROR count == 0 via CL: CF/OF unchanged (and all else)
    movl    $0xcafebabe, %eax
    movl    $0, %ecx
    rorl    %cl, %eax               # no change

    # ---- RCL by 1 (D1 /2): rotate through carry -----------------------------
    # Seed CF=1 with a carrying add, then RCL pulls CF into bit0.
    movl    $0xffffffff, %ebx
    addl    $1, %ebx                # ebx=0, CF=1
    movl    $0x00000000, %eax
    rcll    $1, %eax                # eax = 0x00000001 (CF rotated in), new CF=0

    # Seed CF=0, then RCL
    movl    $0x00000001, %ebx
    addl    $1, %ebx                # ebx=2, CF=0
    movl    $0x80000000, %eax
    rcll    $1, %eax                # eax = 0x00000000 (CF in = 0), new CF=1

    # ---- RCL by imm8 = 5 (C1 /2 ib) -----------------------------------------
    movl    $0xffffffff, %ebx
    addl    $1, %ebx                # CF=1
    movl    $0x000000f0, %eax
    rcll    $5, %eax                # 33-bit rotate-through-carry, OF undefined

    # ---- RCL by CL ----------------------------------------------------------
    movl    $0x00000001, %ebx
    addl    $1, %ebx                # CF=0
    movl    $0x00000001, %eax
    movl    $4, %ecx
    rcll    %cl, %eax               # eax = 0x00000010 (CF=0 fed in)

    # ---- RCR by 1 / imm / CL (D1 /3, C1 /3, D3 /3) --------------------------
    movl    $0xffffffff, %ebx
    addl    $1, %ebx                # CF=1
    movl    $0x00000000, %eax
    rcrl    $1, %eax                # eax = 0x80000000 (CF -> bit31), new CF=0

    movl    $0x00000001, %ebx
    addl    $1, %ebx                # CF=0
    movl    $0x00000003, %eax
    rcrl    $1, %eax                # eax = 0x00000001 (CF=0 -> bit31), new CF=1

    movl    $0xffffffff, %ebx
    addl    $1, %ebx                # CF=1
    movl    $0x12345678, %eax
    rcrl    $5, %eax                # OF undefined, 33-bit rotate

    movl    $0x00000001, %ebx
    addl    $1, %ebx                # CF=0
    movl    $0x80000000, %eax
    movl    $4, %ecx
    rcrl    %cl, %eax               # eax = 0x08000000

    # ---- 8-bit rotate (D0 /0): partial register preserved -------------------
    movl    $0x11223381, %eax       # AL=0x81
    rolb    $1, %al                 # AL = 0x03, CF=1. [31:8] preserved = 0x112233

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
