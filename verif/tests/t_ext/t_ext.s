# =============================================================================
# Ventium M2 test: t_ext  --  MOVZX / MOVSX coverage (sign/zero extend)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Covers (docs/m2-isa-spec.md "Sign/zero extend"):
#   * MOVZX r32, r/m8   (0F B6 /r)
#   * MOVZX r32, r/m16  (0F B7 /r)
#   * MOVSX r32, r/m8   (0F BE /r)
#   * MOVSX r32, r/m16  (0F BF /r)
# Sources: 8/16-bit registers (low byte AL/.., high byte AH/.., word AX/..) AND
# memory bytes/words (AGU path). Destinations are full 32-bit regs (no undefined
# destination). MOVZX/MOVSX affect NO flags, so nothing to mask.
#
# Edge byte values:  0x00, 0x01, 0x7f, 0x80, 0xff
# Edge word values:  0x0000, 0x7fff, 0x8000, 0xffff
# For each we check that zero-extend pads with 0 and sign-extend replicates the
# top bit (byte bit7 / word bit15). High-bit-set sources make ZX vs SX diverge,
# so a decoder that confuses B6/BE (or B7/BF) is caught immediately.
#
# Deterministic. Ends _exit(0).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- MOVZX r32, r8 : zero-extend a byte register -----------------------
    # source byte 0xff in AL ; preserve a poison pattern in the high bytes of
    # the *source* reg to prove the extend reads only [7:0].
    movl    $0xdeadbe80, %eax       # AL=0x80 (bit7 set), high bytes = poison
    movzbl  %al, %ecx               # ecx = 0x00000080  (0F B6)
    movsbl  %al, %edx               # edx = 0xffffff80  (0F BE: sign of bit7)
    # ecx=0x00000080 edx=0xffffff80

    # ---- MOVZX/MOVSX from the HIGH byte register (AH) ----------------------
    movl    $0x0000ff00, %eax       # AH=0xff
    movzbl  %ah, %esi               # esi = 0x000000ff (0F B6 /r, rm=AH)
    movsbl  %ah, %edi               # edi = 0xffffffff (0F BE: sign of 0xff)
    # esi=0x000000ff edi=0xffffffff

    # ---- MOVZX/MOVSX r32, r16 : word register source -----------------------
    movl    $0xcafe8000, %eax       # AX=0x8000 (bit15 set), high half = poison
    movzwl  %ax, %ebx               # ebx = 0x00008000 (0F B7)
    movswl  %ax, %ebp               # ebp = 0xffff8000 (0F BF: sign of bit15)
    # ebx=0x00008000 ebp=0xffff8000

    # positive word: 0x7fff -> both extends agree (top bit clear)
    movl    $0x12347fff, %eax       # AX=0x7fff
    movzwl  %ax, %ecx               # ecx = 0x00007fff
    movswl  %ax, %edx               # edx = 0x00007fff (bit15 clear)
    # ecx=0x00007fff edx=0x00007fff

    # ---- MOVZX/MOVSX from MEMORY byte source (0F B6/BE, mod=00 disp32) ------
    movzbl  b_80, %esi              # esi = 0x00000080
    movsbl  b_80, %edi              # edi = 0xffffff80
    movzbl  b_7f, %ebx              # ebx = 0x0000007f
    movsbl  b_7f, %ebp              # ebp = 0x0000007f (bit7 clear: same)
    # esi=0x00000080 edi=0xffffff80 ebx=0x0000007f ebp=0x0000007f

    # ---- MOVZX/MOVSX from MEMORY word source (0F B7/BF) --------------------
    movzwl  w_ffff, %ecx            # ecx = 0x0000ffff
    movswl  w_ffff, %edx            # edx = 0xffffffff (bit15 set)
    movzwl  w_0000, %esi            # esi = 0x00000000
    movswl  w_0000, %edi            # edi = 0x00000000
    # ecx=0x0000ffff edx=0xffffffff esi=0 edi=0

    # ---- byte source 0x00 and 0x01 (smallest magnitudes) -------------------
    movl    $0x00000001, %eax       # AL=0x01
    movzbl  %al, %ebx               # ebx = 0x00000001
    movsbl  %al, %ebp               # ebp = 0x00000001
    # ebx=1 ebp=1

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    .data
    .align 4
b_80:   .byte 0x80
b_7f:   .byte 0x7f
        .align 2
w_ffff: .word 0xffff
w_8000: .word 0x8000
w_0000: .word 0x0000
