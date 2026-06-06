# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_mixed  --  randomized-but-deterministic broad ISA mix
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000 \
#       -o t_mixed.elf t_mixed.s
#
# Goal: a single hand-authored "fuzz-like" sequence that stresses MANY M2
# instruction groups back-to-back over EDGE operand values, so cross-group
# datapath/flag bugs surface in the differential gate. It is deterministic
# (fixed seeds, no input) and NON-FAULTING (safe shift counts; no div; bsf/bsr
# only on nonzero sources so the destination stays defined).
#
# Edge operands swept: 0, 1, 0x7fffffff, 0x80000000, 0xffffffff; shift counts
# 0 / 1 / 31 / 32(&0x1f->0); both DF directions (CLD/STD); 8/16/32 operand sizes.
#
# Groups exercised (docs/m2-isa-spec.md):
#   shifts/rotates (D1/D3/C1, SHLD/SHRD), MUL/IMUL (F7,0F AF,69/6B), MOVZX/MOVSX,
#   NEG/NOT, INC/DEC r/m, CDQ/CWDE/CBW, XCHG, SETcc, BSWAP, BT/BTS/BTR/BTC,
#   BSF/BSR, PUSH/POP imm & r/m, PUSHA/POPA, PUSHF/POPF, LAHF/SAHF, LEAVE,
#   MOVS/STOS/LODS/SCAS/CMPS + REP/REPE/REPNE, STD/CLD, LOOP/JECXZ,
#   CALL rel32 / RET, plus 16-bit (0x66) and 8-bit forms intermixed.
#
# EFLAGS-undefined masking (harness must have these in tracefmt.EFLAGS_UNDEFINED):
#   shl/shr/sar/sal, rol/ror/rcl/rcr, shld/shrd, bt/bts/btr/btc, bsf/bsr,
#   mul/imul.  (See report.) We mask, never rely on, those undefined bits.
# =============================================================================

    .text
    .globl  _start
_start:
    # =========================================================================
    # SECTION A — shifts & rotates over edge values and edge counts
    # =========================================================================
    movl    $0x80000001, %eax       # MSB+LSB set
    shll    $1, %eax                # by 1: eax=0x00000002, CF=1, OF defined
    movl    $0x80000000, %eax
    shrl    $1, %eax                # eax=0x40000000, CF=0
    movl    $0x80000000, %eax
    sarl    $1, %eax                # arith: eax=0xc0000000
    movl    $0x00000001, %eax
    shll    $31, %eax               # count 31: eax=0x80000000 (max in-range)
    movl    $0xdeadbeef, %eax
    movl    $32, %ecx               # shift count 32 -> &0x1f = 0 -> NO change
    shll    %cl, %eax               # eax stays 0xdeadbeef, FLAGS UNCHANGED
    movl    $0xffffffff, %eax
    movl    $0, %ecx
    shrl    %cl, %eax               # count 0 -> NO change, flags unchanged
    movl    $0x12345678, %eax
    roll    $1, %eax                # rotate: eax=0x2468acf0, CF=0
    movl    $0x80000001, %eax
    rorl    $1, %eax                # eax=0xc0000000, CF=1
    # SHLD / SHRD (double-precision shift)
    movl    $0x12345678, %eax
    movl    $0x9abcdef0, %edx
    shldl   $8, %edx, %eax          # eax = (eax<<8)|(edx>>24) = 0x3456789a
    movl    $0x12345678, %eax
    movl    $0x9abcdef0, %edx
    shrdl   $8, %edx, %eax          # eax = (eax>>8)|(edx<<24) = 0xf0123456

    # =========================================================================
    # SECTION B — multiply (EDX:EAX) over edge values; no divide (fault-safe)
    # =========================================================================
    movl    $0xffffffff, %eax       # -1 unsigned = 0xffffffff
    movl    $0x00000002, %ecx
    mull    %ecx                    # EDX:EAX = 0xffffffff*2 = 0x1_fffffffe
                                    # eax=0xfffffffe edx=0x00000001
    movl    $0x7fffffff, %eax       # INT_MAX
    movl    $0x00000002, %ecx
    imull   %ecx                    # signed: EDX:EAX = 0xfffffffe (0x0_fffffffe)
    movl    $0xffffffff, %eax       # -1 signed
    imull   $0x10, %eax, %ebx       # IMUL r32,r/m32,imm8 (6B): ebx = -16 = 0xfffffff0
    movl    $0x00010000, %eax
    movl    $0x00000003, %edx
    imull   %edx, %eax              # 0F AF: eax = 0x00030000 (two-operand imul)

    # =========================================================================
    # SECTION C — extend / unary / misc
    # =========================================================================
    movl    $0x000000ff, %eax
    movzbl  %al, %ebx               # ebx = 0x000000ff
    movsbl  %al, %esi               # esi = 0xffffffff (sign extend 0xff)
    movw    $0x8000, %ax
    movzwl  %ax, %edi               # edi = 0x00008000
    movl    $0x00000001, %edx
    negl    %edx                    # edx = 0xffffffff (CF=1)
    notl    %edx                    # edx = 0x00000000
    movl    $0x7fffffff, %edx
    incl    %edx                    # edx = 0x80000000 (OF=1, SF=1)
    decl    %edx                    # edx = 0x7fffffff (OF=1)
    movl    $0xffffffff, %eax       # CDQ over sign: edx:eax sign-extend eax
    cltd                            # CDQ (99): eax=0xffffffff -> edx=0xffffffff
    movw    $0x8001, %ax
    cwtl                            # CWDE (98): eax = sign-extend ax = 0xffff8001
    movl    $0x12345678, %eax
    bswapl  %eax                    # BSWAP: eax = 0x78563412

    # =========================================================================
    # SECTION D — bit tests & scans (sources nonzero so dest stays defined)
    # =========================================================================
    movl    $0x00010000, %eax       # single bit at position 16
    btl     $16, %eax               # BT: CF = bit16 = 1, eax unchanged
    btsl    $0, %eax                # BTS: set bit0 -> eax=0x00010001, CF=old(0)
    btrl    $16, %eax               # BTR: clear bit16 -> eax=0x00000001, CF=old(1)
    btcl    $4, %eax                # BTC: toggle bit4 -> eax=0x00000011, CF=old(0)
    movl    $0x00010000, %eax
    bsfl    %eax, %ecx              # BSF: ecx=16 (lowest set bit), ZF=0
    bsrl    %eax, %edx              # BSR: edx=16 (highest set bit), ZF=0
    # SETcc: capture a condition into a byte register
    movl    $0x00000005, %eax
    cmpl    $0x00000005, %eax       # ZF=1
    sete    %bl                     # BL = 1 (zero flag set)
    cmpl    $0x00000006, %eax       # eax(5) < 6 -> below/less
    setl    %bh                     # BH = 1 (signed less)

    # =========================================================================
    # SECTION E — stack: push/pop imm & r/m, pusha/popa, pushf/popf, lahf/sahf
    # =========================================================================
    pushl   $0x7fffffff             # PUSH imm32 (68)
    pushl   $0x12                   # PUSH imm8  (6A, sign-extended)
    popl    %eax                    # eax = 0x00000012
    popl    %ecx                    # ecx = 0x7fffffff
    movl    $0xcafebabe, %edx
    pushl   %edx                    # PUSH r/m32 (50+r)
    popl    %esi                    # esi = 0xcafebabe
    # pusha/popa round-trip: popa must restore exactly what pusha saved
    movl    $0x11111111, %eax
    movl    $0x22222222, %ecx
    pushal                          # PUSHA (60)
    movl    $0xdeadbeef, %eax       # clobber
    movl    $0xdeadbeef, %ecx       # clobber
    popal                           # POPA (61): eax/ecx restored (ESP slot skipped)
    # pushf/popf: read flags, modify a safe bit (CF) via stack, restore
    pushfl                          # PUSHF (9C)
    popl    %ebx                    # ebx = current eflags image
    pushl   %ebx                    # push it back
    popfl                           # POPF (9D): flags restored (IOPL/VM unaffected at CPL3)
    # lahf/sahf round-trip on the low byte of flags
    lahf                            # LAHF (9F): AH = low 8 status flags
    sahf                            # SAHF (9E): restore them from AH

    # =========================================================================
    # SECTION F — string ops with REP and BOTH DF directions
    # =========================================================================
    # forward copy (CLD): 4 dwords src -> dst
    cld                             # DF=0 (forward)
    leal    src, %esi               # ESI = &src
    leal    dst, %edi               # EDI = &dst
    movl    $4, %ecx                # 4 elements
    rep movsl                       # REP MOVSD (F3 A5): copy 4 dwords forward
    # STOS: fill 4 dwords of dst2 with EAX, forward
    movl    $0xa5a5a5a5, %eax
    leal    dst2, %edi
    movl    $4, %ecx
    rep stosl                       # REP STOSD (F3 AB)
    # LODS one element (reads [ESI], advances ESI)
    leal    src, %esi
    lodsl                           # EAX = src[0], ESI += 4
    # SCAS: scan dst2 for EAX (which is now src[0], not 0xa5..), REPNE
    movl    $0xa5a5a5a5, %eax       # value that IS present in dst2
    leal    dst2, %edi
    movl    $4, %ecx
    repne scasl                     # REPNE SCASD (F2 AF): stops at first match
    # CMPS: compare src vs dst (just copied -> equal), REPE, forward
    leal    src, %esi
    leal    dst, %edi
    movl    $4, %ecx
    repe cmpsl                      # REPE CMPSD (F3 A7): all equal -> ecx=0, ZF=1
    # backward direction (STD): copy with DF=1 then restore DF
    std                             # DF=1 (backward)
    leal    src+12, %esi            # point at last dword
    leal    dst3+12, %edi
    movl    $4, %ecx
    rep movsl                       # REP MOVSD backward
    cld                             # restore DF=0

    # =========================================================================
    # SECTION G — control flow: LOOP, JECXZ, CALL/RET
    # =========================================================================
    # LOOP: sum 5+4+3+2+1 = 15 into ebp using ECX as counter
    movl    $0, %ebp
    movl    $5, %ecx
.Lloop:
    addl    %ecx, %ebp              # ebp += ecx
    loop    .Lloop                  # ECX--, jump while ECX != 0
    # JECXZ: ECX is 0 now -> branch taken
    jecxz   .Lzero                  # taken (ECX==0)
    movl    $0xbadbad00, %ebp       # must NOT execute
.Lzero:
    # CALL rel32 / RET: call a leaf that sets edx, returns
    movl    $0, %edx
    call    set_edx                 # CALL rel32 (E8)
    # edx is now 0x600d600d
    jmp     .Lafter
set_edx:
    movl    $0x600d600d, %edx
    ret                             # RET (C3)
.Lafter:

    # =========================================================================
    # SECTION H — 16/8-bit intermixed final fold over partials
    # =========================================================================
    movl    $0xAAAA0000, %eax       # hi witness
    movw    $0x00FF, %ax            # eax = 0xAAAA00ff (16-bit write)
    incw    %ax                     # eax = 0xAAAA0100 (16-bit inc, hi preserved)
    movb    $0x7f, %al              # eax = 0xAAAA017f (8-bit write)
    addb    $0x01, %al              # eax = 0xAAAA0180 (8-bit add, OF/SF)

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt

    # =========================================================================
    # RW data: string source/destination buffers (distinct .data page).
    # =========================================================================
    .data
    .align 4
src:    .long 0x11111111, 0x22222222, 0x33333333, 0x44444444
dst:    .long 0, 0, 0, 0
dst2:   .long 0, 0, 0, 0
dst3:   .long 0, 0, 0, 0
