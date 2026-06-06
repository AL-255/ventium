# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_div  --  DIV / IDIV coverage (divide group), SAFE divisors
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Covers (docs/m2-isa-spec.md "Multiply / divide"):
#   * DIV  r/m32 (F7 /6)  -- unsigned: EAX=quotient, EDX=remainder of EDX:EAX/src
#   * IDIV r/m32 (F7 /7)  -- signed:   EAX=quotient, EDX=remainder of EDX:EAX/src
#   Register AND memory divisors (AGU path). CDQ used to sign-extend dividends.
#
# SAFETY (no #DE): for every divide we (1) set the divisor != 0 and (2) ensure
# the quotient fits the destination. We zero EDX before each unsigned DIV (so
# the dividend is the 32-bit value in EAX, quotient always fits), and use CDQ to
# correctly sign-extend EAX into EDX before each IDIV (so EDX:EAX is the proper
# 64-bit sign extension of a 32-bit signed dividend, quotient always fits except
# the single INT_MIN/-1 overflow case which we explicitly do NOT generate).
#
# EFLAGS: DIV/IDIV leave ALL six status flags undefined (already in tracefmt
# EFLAGS_UNDEFINED["div"/"idiv"]=0x8D5); the comparator masks them. No new
# masking entries needed. We exercise edge dividends/divisors and both signs.
#
# Deterministic. Ends _exit(0).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- DIV r/m32 (unsigned) : EDX must be the high dividend (we zero it) --
    # (a) 100 / 7 = 14 rem 2
    movl    $0x00000064, %eax       # 100
    xorl    %edx, %edx              # EDX=0  (dividend = 0x00000000_00000064)
    movl    $0x00000007, %ecx
    divl    %ecx                    # EAX=14 (0x0e) EDX=2
    # eax=0x0000000e edx=0x00000002

    # (b) max-unsigned exact: 0xffffffff / 1 = 0xffffffff rem 0
    movl    $0xffffffff, %eax
    xorl    %edx, %edx
    movl    $0x00000001, %ecx
    divl    %ecx                    # EAX=0xffffffff EDX=0
    # eax=0xffffffff edx=0

    # (c) 64-bit dividend with nonzero EDX, quotient still fits in 32 bits.
    #     EDX:EAX = 0x00000001_00000000 (= 2^32) ; / 2 = 2^31 = 0x80000000 rem 0
    movl    $0x00000000, %eax
    movl    $0x00000001, %edx       # high half = 1 -> dividend = 2^32
    movl    $0x00000002, %ecx
    divl    %ecx                    # EAX=0x80000000 EDX=0  (quotient fits)
    # eax=0x80000000 edx=0

    # (d) DIV by a MEMORY divisor: 0x000003e8(=1000) / 10 = 100 rem 0
    movl    $0x000003e8, %eax
    xorl    %edx, %edx
    divl    d_ten                   # EAX=100 (0x64) EDX=0
    # eax=0x00000064 edx=0

    # (e) remainder edge: 0x7fffffff / 0x7fffffff = 1 rem 0  (INT_MAX/INT_MAX)
    movl    $0x7fffffff, %eax
    xorl    %edx, %edx
    movl    $0x7fffffff, %ecx
    divl    %ecx                    # EAX=1 EDX=0
    # eax=1 edx=0

    # ---- IDIV r/m32 (signed) : use CDQ to sign-extend EAX into EDX ----------
    # (f) (-100) / 7 = -14 rem -2   (truncation toward zero)
    movl    $0xffffff9c, %eax       # -100
    cdq                             # EDX = sign of EAX = 0xffffffff
    movl    $0x00000007, %ecx
    idivl   %ecx                    # EAX=-14=0xfffffff2 EDX=-2=0xfffffffe
    # eax=0xfffffff2 edx=0xfffffffe

    # (g) 100 / (-7) = -14 rem +2
    movl    $0x00000064, %eax       # +100
    cdq                             # EDX=0
    movl    $0xfffffff9, %ecx       # -7
    idivl   %ecx                    # EAX=-14=0xfffffff2 EDX=+2
    # eax=0xfffffff2 edx=0x00000002

    # (h) (-100) / (-7) = +14 rem -2
    movl    $0xffffff9c, %eax       # -100
    cdq                             # EDX=0xffffffff
    movl    $0xfffffff9, %ecx       # -7
    idivl   %ecx                    # EAX=+14=0x0000000e EDX=-2=0xfffffffe
    # eax=0x0000000e edx=0xfffffffe

    # (i) IDIV by MEMORY divisor: INT_MIN / 2 = -2^30 rem 0  (no overflow)
    movl    $0x80000000, %eax       # INT_MIN = -2^31
    cdq                             # EDX=0xffffffff
    idivl   d_two                   # EAX=0xc0000000 (-2^30) EDX=0
    # eax=0xc0000000 edx=0

    # (j) signed remainder follows dividend sign: (-1)/2 = 0 rem -1
    movl    $0xffffffff, %eax       # -1
    cdq                             # EDX=0xffffffff
    movl    $0x00000002, %ecx
    idivl   %ecx                    # EAX=0 EDX=-1=0xffffffff
    # eax=0 edx=0xffffffff

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    .data
    .align 4
d_ten:   .long 0x0000000a
d_two:   .long 0x00000002
