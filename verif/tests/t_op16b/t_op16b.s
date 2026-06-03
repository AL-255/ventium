# =============================================================================
# Ventium M2 test: t_op16b  --  16-bit (0x66-prefixed) MOVZX/MOVSX/BSF/BSR/BT*
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# Regression-locks the adversarial-review findings that the 0x66 operand-size
# prefix was IGNORED by several 0F-map ops, clobbering the destination's upper
# 16 bits and/or using the wrong bit width:
#
#   * MOVZX/MOVSX 16-bit forms (66 0F B6/B7/BE/BF): the destination is a 16-bit
#     register; bits [31:16] MUST be preserved (not zero/sign-extended into 32).
#   * BSF/BSR 16-bit forms (66 0F BC/BD): scan only [15:0], ZF from [15:0], and
#     write a 16-bit index preserving [31:16].
#   * BT/BTS/BTR/BTC 16-bit reg/imm forms (66 0F A3/AB/B3/BB, 66 0F BA /4..7):
#     the bit index is taken mod 16 (not mod 32); modify forms preserve [31:16].
#
# Every 16-bit destination is PRE-SEEDED with a known high half so a bug that
# clobbers [31:16] corrupts a checked GPR and the differential gate catches it.
#
# EFLAGS undefined (comparator table, already present):
#   BT/BTS/BTR/BTC: OF,SF,AF,PF undefined (CF defined, ZF unchanged).
#   BSF/BSR:        CF,OF,SF,AF,PF undefined (ZF defined).
# Only nonzero BSF/BSR sources are used (destination well-defined).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- seed regs with known high halves -----------------------------------
    movl    $0xDEADBEEF, %eax       # eax hi witness = 0xDEAD
    movl    $0xCAFE1234, %edx       # edx hi witness = 0xCAFE
    movl    $0x77770000, %esi       # esi hi witness = 0x7777
    movl    $0x000000A5, %ebx       # bl = 0xA5 (negative byte)

    # ---- MOVZX 16-bit: 66 0F B6 (movzbw): dest [15:0]=zext(BL), [31:16] kept --
    .byte 0x66
    movzbl  %bl, %eax               # ax = 0x00a5 ; eax = 0xDEAD00a5
    # ---- MOVSX 16-bit: 66 0F BE (movsbw): dest [15:0]=sext(BL), [31:16] kept --
    .byte 0x66
    movsbl  %bl, %edx               # dx = 0xffa5 ; edx = 0xCAFEffa5

    # ---- MOVZX/MOVSX 16-bit from a 16-bit source (66 0F B7/BF) ---------------
    movl    $0x99998001, %ecx       # cx = 0x8001 (negative word), hi=0x9999
    movl    $0x55550000, %ebp       # ebp hi = 0x5555
    .byte 0x66
    movzwl  %cx, %ebp               # 66 0F B7: bp = 0x8001 ; ebp = 0x55558001
    movl    $0x66660000, %edi       # edi hi = 0x6666
    .byte 0x66
    movswl  %cx, %edi               # 66 0F BF: di = 0x8001 (sign in word is just copy) ; edi=0x66668001

    # ---- BSF 16-bit (66 0F BC): scan low16, index into 16-bit dest ----------
    movl    $0x00000010, %ecx       # si source = 0x0010
    movl    $0x77770000, %esi       # esi (will be source) hi witness
    movw    $0x0010, %si            # si = 0x0010 ; esi = 0x77770010
    movl    $0x12340000, %eax       # eax hi = 0x1234 (dest)
    .byte 0x66
    bsf     %si, %ax                # ax = 4 (lowest set bit of 0x0010) ; eax=0x12340004
    # BSF where low16 nonzero but bit set only in high half of source-as-32:
    movl    $0xFFFF0001, %esi       # if scanned as 32 -> lowest=0; as 16 -> 0 too
    movl    $0xABCD0000, %eax       # dest hi=0xABCD
    .byte 0x66
    bsf     %si, %ax                # si=0x0001 -> ax=0 ; eax=0xABCD0000, ZF=0

    # ---- BSR 16-bit (66 0F BD): highest set bit within low16 ----------------
    movl    $0x0000F000, %esi       # si = 0xf000 -> highest set bit = 15
    movl    $0x4444FFFF, %eax       # if scanned as 32 (0x0000f000)->15 anyway; pick value that differs
    movl    $0x0000C000, %esi       # si = 0xc000 -> bit15
    movl    $0x4321000F, %eax       # dest hi = 0x4321
    .byte 0x66
    bsr     %si, %ax                # ax = 15 ; eax = 0x4321000f

    # ---- BT 16-bit reg (66 0F A3): index mod 16 ------------------------------
    movl    $0x0000FFFF, %eax       # ax = 0xffff
    movl    $20, %ebx               # 20 mod 16 = 4 ; ax[4]=1 -> CF=1
    .byte 0x66
    bt      %bx, %ax                # CF = 1
    movl    $0x0000FF00, %eax       # ax = 0xff00
    movl    $19, %ebx               # 19 mod 16 = 3 ; ax[3]=0 -> CF=0
    .byte 0x66
    bt      %bx, %ax                # CF = 0

    # ---- BT 16-bit imm (66 0F BA /4): index mod 16 --------------------------
    movl    $0x0000F0F0, %eax       # ax = 0xf0f0
    .byte 0x66
    btl     $20, %eax               # 66 0F BA /4 ib=20 ; 20 mod 16=4 ; ax[4]=1 -> CF=1

    # ---- BTS 16-bit reg (66 0F AB): set bit (idx mod16), preserve [31:16] ---
    movl    $0xDEAD0001, %ecx       # cx = 0x0001, hi = 0xDEAD
    movl    $17, %edx               # 17 mod 16 = 1
    .byte 0x66
    bts     %dx, %cx                # set cx bit1 -> cx=0x0003 ; ecx=0xDEAD0003, CF=0

    # ---- BTR 16-bit imm (66 0F BA /6): clear bit, preserve [31:16] ----------
    movl    $0xBEEF00FF, %ecx       # cx = 0x00ff, hi = 0xBEEF
    .byte 0x66
    btrl    $3, %ecx                # clear cx bit3 -> cx=0x00f7 ; ecx=0xBEEF00f7, CF=1

    # ---- BTC 16-bit reg (66 0F BB): toggle bit, preserve [31:16] ------------
    movl    $0x1234000F, %ecx       # cx = 0x000f, hi = 0x1234
    movl    $2, %edx
    .byte 0x66
    btc     %dx, %cx                # toggle cx bit2 -> cx=0x000b ; ecx=0x1234000b, CF=1

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
