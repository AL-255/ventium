# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_unary  --  NEG/NOT/INC/DEC/XCHG/CDQ/CWDE/BSWAP (unary misc)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Covers (docs/m2-isa-spec.md "Sign/zero extend, misc unary"):
#   * NEG  r/m32 (F7 /3) , NEG r/m8 (F6 /3)
#   * NOT  r/m32 (F7 /2) , NOT r/m8 (F6 /2)
#   * INC/DEC r/m32 (FF /0,/1) , INC/DEC r/m8 (FE /0,/1)   [reg + memory]
#   * XCHG r/m32,r32 (87 /r) [reg-reg + memory] , XCHG eAX,r32 (90+r)
#   * CDQ (99) , CWDE (98)
#   * BSWAP r32 (0F C8+r)
#
# EFLAGS NOTES (no new masking entries needed for this bucket):
#   - NEG: CF=0 iff operand was 0 else CF=1; OF/SF/ZF/AF/PF all DEFINED.
#          NEG(INT_MIN) overflows -> result=INT_MIN, OF=1, CF=1 (defined).
#   - NOT: affects NO flags.
#   - INC/DEC: OF/SF/ZF/AF/PF defined, CF *preserved* (DEFINED behaviour).
#   - XCHG / CDQ / CWDE / BSWAP: affect NO flags.
# All flags here are architecturally defined, so no EFLAGS_UNDEFINED additions.
# (CDQ also appears in t_div; CWDE/BSWAP are exercised only here.)
#
# Edge operands: 0, 1, 0x7fffffff, 0x80000000, 0xffffffff. CF-preserve across
# INC/DEC is checked by setting CF (via stc-equivalent: a sub that borrows) then
# doing INC and proving CF survives. Deterministic. Ends _exit(0).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- NOT r/m32 (no flags) : bitwise complement -------------------------
    movl    $0x00000000, %eax
    notl    %eax                    # eax = 0xffffffff  (F7 /2)
    notl    %eax                    # eax = 0x00000000  (involutive)
    movl    $0x0f0f0f0f, %ecx
    notl    %ecx                    # ecx = 0xf0f0f0f0
    # eax=0 ecx=0xf0f0f0f0

    # ---- NEG r/m32 : two's complement, flags DEFINED -----------------------
    movl    $0x00000001, %edx
    negl    %edx                    # edx = 0xffffffff (-1) ; CF=1 OF=0 SF=1
    movl    $0x00000000, %ebx
    negl    %ebx                    # ebx = 0 ; CF=0 ZF=1 (the only CF=0 case)
    movl    $0x80000000, %esi
    negl    %esi                    # esi = 0x80000000 (INT_MIN) ; OF=1 CF=1 SF=1
    movl    $0x7fffffff, %edi
    negl    %edi                    # edi = 0x80000001 ; CF=1 OF=0 SF=1
    # edx=0xffffffff ebx=0 esi=0x80000000 edi=0x80000001

    # ---- NEG/NOT 8-bit forms (partial reg: write [7:0], preserve [31:8]) ---
    movl    $0xaabbcc01, %eax       # AL=0x01
    negb    %al                     # AL = 0xff ; high bytes 0xaabbcc preserved
                                    # -> eax = 0xaabbccff  (F6 /3)
    movl    $0x11223344, %ecx       # CL=0x44
    notb    %cl                     # CL = 0xbb ; eax-style preserve -> 0x112233bb
    # eax=0xaabbccff ecx=0x112233bb

    # ---- INC / DEC r/m32 (FF /0,/1) : CF preserved -------------------------
    # First make CF=1 with a borrowing SUB, then INC must NOT clear it.
    movl    $0x00000000, %ebx
    subl    $0x00000001, %ebx       # ebx=0xffffffff, CF=1 (borrow)
    movl    $0x0000007f, %ebx
    incl    %ebx                    # ebx=0x80 ; OF/SF/ZF set per result, CF=1 kept
    decl    %ebx                    # ebx=0x7f ; CF still 1
    # ebx=0x7f  (CF preserved through inc/dec)

    # INC overflow edge: INT_MAX -> INT_MIN sets OF, SF
    movl    $0x7fffffff, %edx
    incl    %edx                    # edx=0x80000000 ; OF=1 SF=1
    # DEC to zero sets ZF
    movl    $0x00000001, %esi
    decl    %esi                    # esi=0 ; ZF=1
    # edx=0x80000000 esi=0

    # ---- INC / DEC r/m8 (FE /0,/1) : partial reg --------------------------
    movl    $0x9999990f, %eax       # AL=0x0f
    incb    %al                     # AL=0x10 -> eax=0x99999910
    decb    %al                     # AL=0x0f -> eax=0x9999990f
    # eax=0x9999990f

    # ---- INC / DEC of a MEMORY operand (FF /0, FF /1 disp32) ---------------
    movl    $0x00000041, m_cnt      # mem = 0x41
    incl    m_cnt                   # mem = 0x42
    incl    m_cnt                   # mem = 0x43
    decl    m_cnt                   # mem = 0x42
    movl    m_cnt, %ebp             # ebp = 0x42
    # ebp=0x42

    # ---- XCHG r/m32, r32 (87 /r) : register-register ----------------------
    movl    $0xdead0001, %ecx
    movl    $0xbeef0002, %edx
    xchgl   %ecx, %edx              # ecx=0xbeef0002 edx=0xdead0001 (no flags)
    # ecx=0xbeef0002 edx=0xdead0001

    # ---- XCHG eAX, r32 (90+r) : the single-byte accumulator form ----------
    movl    $0x11111111, %eax
    movl    $0x22222222, %esi
    xchgl   %esi, %eax              # eax=0x22222222 esi=0x11111111 (91: xchg eax,ecx? no -> 96)
    # eax=0x22222222 esi=0x11111111

    # ---- XCHG with a MEMORY operand (87 /r, mod=00 disp32) ----------------
    movl    $0x0badf00d, m_swap
    movl    $0xfeedface, %edi
    xchgl   %edi, m_swap            # edi=0x0badf00d , mem=0xfeedface
    movl    m_swap, %ebx            # ebx=0xfeedface
    # edi=0x0badf00d ebx=0xfeedface

    # ---- CWDE (98) : sign-extend AX into EAX -------------------------------
    movl    $0x1234fedc, %eax       # AX=0xfedc (bit15 set, negative word)
    cwde                            # EAX = 0xfffffedc (sign-extend AX) ; no flags
    # eax=0xfffffedc

    # ---- CDQ (99) : sign-extend EAX into EDX:EAX ---------------------------
    movl    $0x80000000, %eax       # negative dword
    cltd                            # (CDQ) EDX = 0xffffffff ; EAX unchanged ; no flags
    # eax=0x80000000 edx=0xffffffff
    movl    $0x7fffffff, %eax       # positive dword
    cltd                            # EDX = 0x00000000
    # eax=0x7fffffff edx=0

    # ---- BSWAP r32 (0F C8+r) : byte-reverse, no flags ----------------------
    movl    $0x11223344, %ecx
    bswap   %ecx                    # ecx = 0x44332211
    movl    $0xaabbccdd, %esi
    bswap   %esi                    # esi = 0xddccbbaa
    # ecx=0x44332211 esi=0xddccbbaa

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    .data
    .align 4
m_cnt:   .long 0x00000000
m_swap:  .long 0x00000000
