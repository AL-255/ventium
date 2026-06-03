# =============================================================================
# Ventium M2 test: t_moffs  --  MOV AL,moffs8 (0xA0) and MOV moffs8,AL (0xA2)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# Regression-locks the adversarial-review finding that only the 16/32-bit moffs
# forms (0xA1/0xA3) were decoded; the 8-bit absolute-address MOV forms 0xA0
# (load AL from [moffs]) and 0xA2 (store AL to [moffs]) fell through to the
# default decode arm and HALTed the core. GCC emits these for byte accesses to
# absolute/global symbols.
#
# The 8-bit forms are not directly emitted by the GNU assembler for these
# operands (it prefers the 8A/88 modrm encodings), so we hand-encode them with
# `.byte 0xa0/.long addr` and `.byte 0xa2/.long addr`, exactly the bytes the
# review reproduced (a0/a2 <abs32>). Both forms operate on AL only: A0 must
# preserve EAX[31:8]; A2 stores only the low byte. We also exercise the existing
# A1/A3 (32-bit) and the operand-size-prefixed A1/A3 (16-bit moffs) for contrast.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- seed a byte slot through a normal store ----------------------------
    movb    $0x5A, %cl
    movb    %cl, byteslot           # byteslot = 0x5A (via 88 /r modrm)

    # ---- MOV AL, moffs8 (A0): AL <- [byteslot], preserve EAX[31:8] ----------
    movl    $0x11223300, %eax       # EAX hi witness = 0x112233, AL = 0x00
    .byte 0xa0
    .long   byteslot                # mov byteslot, %al  -> AL=0x5A, EAX=0x1122335a

    # ---- MOV moffs8, AL (A2): [byteslot2] <- AL -----------------------------
    movb    $0x99, %al              # AL = 0x99 (EAX = 0x11223399)
    .byte 0xa2
    .long   byteslot2               # mov %al, byteslot2  -> byteslot2 = 0x99
    movb    byteslot2, %dl          # DL = 0x99 (read back via 8A /r)

    # ---- round-trip a second byte to make a store bug observable ------------
    movb    $0xC7, %al              # AL = 0xC7
    .byte 0xa2
    .long   byteslot                # store 0xC7 to byteslot (overwrite 0x5A)
    movl    $0x44556600, %ebx       # EBX hi witness
    movb    $0x00, %al              # AL = 0
    .byte 0xa0
    .long   byteslot                # AL <- 0xC7, EAX = 0x112233c7
    movb    %al, %bl                # BL = 0xC7 ; EBX = 0x445566c7

    # ---- contrast: 32-bit moffs (A1/A3) still work --------------------------
    movl    $0x0BADF00D, dwordslot  # dwordslot = 0x0BADF00D (C7 /0)
    .byte 0xa1
    .long   dwordslot               # mov dwordslot, %eax -> EAX = 0x0BADF00D
    movl    %eax, %esi              # ESI = 0x0BADF00D

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt

    .data
    .align 4
byteslot:   .byte 0
    .align 4
byteslot2:  .byte 0
    .align 4
dwordslot:  .long 0
