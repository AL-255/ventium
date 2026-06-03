# =============================================================================
# Ventium M2 test: t_rep -- REP / REPE / REPNE prefixed string ops
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Built like the M1 corpus:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m2-isa-spec.md "String ops + REP"): exercise the REP family across ECX
# counts (including the ECX==0 degenerate case) and the REPE/REPNE early-exit
# conditions, in both DF directions.
#
# *** REP single-step GRANULARITY (verified against the QEMU golden) ***
# QEMU's gdbstub single-step under `-one-insn-per-tb` emits ONE retire record
# PER REP ITERATION: the REP instruction's PC stays CONSTANT across iterations,
# ECX is decremented by one each record, the embedded string op executes once
# (ESI/EDI advance by the operand size, and SCAS/CMPS update flags), and the
# instruction "retires" repeatedly until the terminating condition. Sequence for
# `mov $4,%ecx ; rep movsl` is:
#     n   : (mov retires, ECX=4)
#     n+1 : pc=REP, ECX=3, one element moved
#     n+2 : pc=REP, ECX=2
#     n+3 : pc=REP, ECX=1
#     n+4 : pc=REP, ECX=0   (last element moved)
#     n+5 : pc=next-insn
# For ECX==0 there is EXACTLY ONE record at the REP PC that moves nothing and
# just advances EIP (ECX stays 0, ESI/EDI unchanged). REPE stops when ZF==0
# (after decrementing ECX & comparing); REPNE stops when ZF==1; both also stop
# when ECX reaches 0. The Ventium core MUST reproduce this exact granularity
# (one architectural retire per iteration, same EIP) to be diff-clean.
#
# All flags here are well-defined (SCAS/CMPS set the standard arithmetic flags;
# MOVS/STOS/LODS set none), so NO EFLAGS-undefined mask is needed.
# =============================================================================

    .text
    .globl  _start
_start:
    cld                             # DF=0 -> increment

    # ---- Phase 1: REP MOVSD, ECX=4 (full forward dword copy) ----------------
    leal    src, %esi
    leal    dst, %edi
    movl    $4, %ecx
    rep movsl                       # 4 iterations: dst[0..3]=src[0..3]; ECX->0
    # esi=&src+16, edi=&dst+16, ECX=0

    # ---- Phase 2: REP with ECX==0 (degenerate: ONE no-op record) ------------
    leal    src, %esi
    leal    dst2, %edi
    xorl    %ecx, %ecx              # ECX=0
    rep movsl                       # no element moved; esi/edi unchanged; EIP++
    # (single retire record at the REP PC per the granularity note)

    # ---- Phase 3: REP STOSB fill, ECX=8 (byte granularity) ------------------
    leal    fill, %edi
    movb    $0xAB, %al
    movl    $8, %ecx
    rep stosb                       # fill[0..7] = 0xAB ; ECX->0 ; 8 iterations

    # ---- Phase 4: REP STOSD fill, ECX=3 (dword) -----------------------------
    leal    dfill, %edi
    movl    $0xCAFE1234, %eax
    movl    $3, %ecx
    rep stosl                       # dfill[0..2] = 0xCAFE1234 ; 3 iterations

    # ---- Phase 5: REPNE SCASB — search for 0x07 in {1..8}, ECX=8 -----------
    # scans forward; stops EARLY when [EDI]==AL (ZF becomes 1). Finds 0x07 at
    # index 6, so it runs 7 iterations (ECX 8->1) then stops on the match.
    leal    seq, %edi
    movb    $0x07, %al
    movl    $8, %ecx
    repne scasb                     # early exit on match; ZF=1; ECX=1

    # ---- Phase 6: REPNE SCASB — value NOT present (runs to ECX==0) ----------
    leal    seq, %edi
    movb    $0x55, %al              # not in {1..8}
    movl    $8, %ecx
    repne scasb                     # no match: full 8 iterations; ECX=0; ZF=0

    # ---- Phase 7: REPE CMPSB — equal prefix then mismatch -------------------
    # compares eqa vs eqb; first 3 bytes equal, 4th differs -> REPE stops when
    # ZF becomes 0 after the mismatch. Runs 4 iterations (ECX 6->2).
    leal    eqa, %esi
    leal    eqb, %edi
    movl    $6, %ecx
    repe cmpsb                      # stop on first mismatch; ZF=0

    # ---- Phase 8: REPE CMPSB — fully equal buffers (runs to ECX==0) ---------
    leal    eqa, %esi
    leal    eqa, %edi               # compare against itself: always equal
    movl    $6, %ecx
    repe cmpsb                      # never mismatches: full 6 iterations; ZF=1

    # ---- Phase 9: REVERSE direction REP MOVSD (STD, DF=1) -------------------
    std                             # DF=1 -> decrement
    leal    src+12, %esi            # last element
    leal    dst3+12, %edi
    movl    $4, %ecx
    rep movsl                       # copies backwards; 4 iterations; ECX->0
    cld                             # restore DF=0 before exit

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    # In-image RW data buffers.
    # =========================================================================
    .data
    .align 4
src:    .long 0x11111111, 0x22222222, 0x33333333, 0x44444444
dst:    .long 0, 0, 0, 0
dst2:   .long 0, 0, 0, 0
dst3:   .long 0, 0, 0, 0
fill:   .byte 0,0,0,0,0,0,0,0
dfill:  .long 0, 0, 0
seq:    .byte 1,2,3,4,5,6,7,8
eqa:    .byte 0x10, 0x20, 0x30, 0x40, 0x50, 0x60
eqb:    .byte 0x10, 0x20, 0x30, 0x99, 0x50, 0x60
