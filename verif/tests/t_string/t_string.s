# =============================================================================
# Ventium M2 test: t_string -- non-REP string primitives, both DF directions
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Built like the M1 corpus:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m2-isa-spec.md "String ops + REP"): exercise every single-step string
# primitive WITHOUT the REP prefix, so each instruction is one retire record and
# the auto-inc/dec of ESI/EDI (by operand size, in BOTH DF directions) and the
# SCAS/CMPS flag results are checked directly against QEMU.
#
# Ops covered (A4/A5 MOVS, AA/AB STOS, AC/AD LODS, AE/AF SCAS, A6/A7 CMPS) in
# both byte (b) and dword (l) forms, with CLD (0xFC, DF=0 -> increment) and
# STD (0xFD, DF=1 -> decrement). All buffers live in the in-image .data segment
# (the elf2flat blob + QEMU's loader present identical memory). No REP here:
# REP/REPE/REPNE granularity is covered by t_rep.
#
# DF hygiene: the program ends with CLD so the final architectural DF matches a
# normal return state; every STD phase is paired with a CLD before moving on.
# No faulting forms; SCAS/CMPS only set flags (well-defined), so no EFLAGS mask
# is required for this program.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- Phase 1: forward (CLD, DF=0) dword copy with MOVSD ------------------
    cld                             # DF=0 -> ESI/EDI increment
    leal    src, %esi               # source base
    leal    dst, %edi               # dest   base
    movsl                           # dst[0]=src[0]=0x11111111; esi+=4; edi+=4
    movsl                           # dst[1]=src[1]=0x22222222
    # esi=&src+8, edi=&dst+8

    # ---- Phase 2: forward byte ops: LODSB then STOSB ------------------------
    leal    src, %esi               # restart source
    lodsb                           # AL = src[0] low byte = 0x11 ; esi+=1
    leal    bbuf, %edi
    stosb                           # bbuf[0] = AL = 0x11 ; edi+=1
    lodsb                           # AL = src byte 1 = 0x11 ; esi+=1
    stosb                           # bbuf[1] = 0x11 ; edi+=1

    # ---- Phase 3: forward dword LODS/STOS -----------------------------------
    leal    src, %esi
    lodsl                           # EAX = src[0] = 0x11111111 ; esi+=4
    leal    dbuf, %edi
    stosl                           # dbuf[0] = 0x11111111 ; edi+=4

    # ---- Phase 4: SCASB (forward) — set flags from (AL - [EDI]) -------------
    leal    src, %edi               # [edi] = 0x11 (low byte of src[0])
    movb    $0x11, %al
    scasb                           # AL==mem -> ZF=1 ; edi+=1 ; flags well-defined
    movb    $0x99, %al
    leal    src, %edi
    scasb                           # 0x99 != 0x11 -> ZF=0 ; CF=1 (0x99-... borrow?)

    # ---- Phase 5: CMPSB / CMPSD (forward) — set flags from [ESI]-[EDI] ------
    leal    src, %esi
    leal    src, %edi               # compare src against itself
    cmpsb                           # equal -> ZF=1 ; esi+=1 ; edi+=1
    leal    src, %esi
    leal    cmpb2, %edi             # src[0..]=0x11.. vs cmpb2=0x12 -> differ
    cmpsb                           # 0x11 - 0x12 -> ZF=0, CF=1 (borrow)
    leal    src, %esi
    leal    src, %edi
    cmpsl                           # dword equal -> ZF=1

    # ---- Phase 6: REVERSE direction (STD, DF=1) -----------------------------
    std                             # DF=1 -> ESI/EDI decrement
    leal    src+12, %esi            # last dword of src
    leal    dst+12, %edi            # last dword of dst
    movsl                           # dst[3]=src[3]=0x44444444 ; esi-=4 ; edi-=4
    movsl                           # dst[2]=src[2]=0x33333333
    leal    src+3, %esi
    lodsb                           # AL = src byte 3 ; esi-=1
    leal    dbuf+7, %edi
    stosb                           # dbuf byte7 = AL ; edi-=1
    leal    src+12, %edi
    movl    $0x44444444, %eax
    scasl                           # AL/EAX==src[3] -> ZF=1 ; edi-=4 (reverse)
    cld                             # restore DF=0 before exit

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    # In-image RW data buffers (distinct RW PT_LOAD; spanned/zero-filled by
    # elf2flat and mapped by QEMU's loader).
    # =========================================================================
    .data
    .align 4
src:    .long 0x11111111, 0x22222222, 0x33333333, 0x44444444
dst:    .long 0, 0, 0, 0
dbuf:   .long 0, 0
bbuf:   .byte 0, 0, 0, 0
cmpb2:  .byte 0x12, 0x13, 0x14, 0x15
