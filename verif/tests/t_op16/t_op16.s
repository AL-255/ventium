# =============================================================================
# Ventium M2 test: t_op16  --  16-bit operand-size prefix (0x66) coverage
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,-Ttext=0x08048000 -o t_op16.elf t_op16.s
#
# Goal: exercise the 0x66 operand-size prefix on ALU / MOV / INC/DEC / shift,
# proving partial-register semantics (writing AX/CX/... updates [15:0] and
# PRESERVES [31:16]) and that flags are computed on the 16-bit result
# (SF = bit15, ZF on the low 16, CF/OF on 16-bit boundary, PF on low byte).
#
# Every 16-bit destination register is PRE-SEEDED with a known high half
# (0xAAAA0000-style) BEFORE the 16-bit write, so a bug that clobbers [31:16]
# (e.g. zero-extending or sign-extending the 16-bit result into the full 32)
# corrupts a checked GPR and the differential gate catches it.
#
# Spec refs (docs/m2-isa-spec.md):
#   * 0x66 operand-size: 32-bit default -> 16-bit operand; preserve [31:16].
#   * Shifts D1/D3/C1 group, count & 0x1f, count==0 => no flag change.
#   * EFLAGS undefined masking applies to shifts (OF for count!=1, AF).
# Uses 16-bit forms of: mov, add, sub, adc, sbb, and, or, xor, cmp, test,
#   inc, dec, neg, not, shl, shr, sar, rol (by 1 / by imm / by CL).
# NO div/idiv (faulting). No undefined-DESTINATION ops.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- seed full 32-bit regs with known high halves -----------------------
    movl    $0xAAAA1234, %eax       # eax hi = 0xAAAA
    movl    $0xBBBB0010, %ecx       # ecx hi = 0xBBBB  (also CL=0x10 shift seed)
    movl    $0xCCCC00FF, %edx       # edx hi = 0xCCCC
    movl    $0xDDDD8000, %ebx       # ebx hi = 0xDDDD  (bx = 0x8000 sign bit set)
    movl    $0xEEEE7FFF, %esi       # esi hi = 0xEEEE  (si = 0x7fff max pos)
    movl    $0xFFFFFFFF, %edi       # edi hi = 0xFFFF  (di = 0xffff = -1)
    movl    $0x99990000, %ebp       # ebp hi = 0x9999  (bp = 0)

    # ---- 16-bit MOV imm: must preserve [31:16] ------------------------------
    movw    $0x00CD, %ax            # ax = 0x00cd ; eax must be 0xAAAA00cd
    movw    $0x0001, %bp            # bp = 0x0001 ; ebp must be 0x99990001

    # ---- 16-bit ADD reg,reg: flags on 16-bit, hi preserved ------------------
    addw    %si, %bx                # bx = 0x8000 + 0x7fff = 0xffff (no carry/of)
                                    # ebx must be 0xDDDDffff
    # ---- 16-bit ADD that carries out of bit15 (CF set, wraps low16) ---------
    movw    $0xFFFF, %ax            # ax = 0xffff (eax = 0xAAAAffff)
    addw    $0x0002, %ax            # ax = 0x0001 (CF=1, wrap) ; eax=0xAAAA0001

    # ---- 16-bit ADC / SBB (carry chain on 16-bit) ---------------------------
    movw    $0x0000, %cx            # cx = 0 (ecx = 0xBBBB0000)
    adcw    $0x0010, %cx            # cx = 0x0010 + CF(1) = 0x0011 ; ecx=0xBBBB0011
    sbbw    $0x0001, %cx            # cx = 0x0011 - 0x0001 - CF(0) = 0x0010

    # ---- 16-bit SUB producing zero (ZF=1) -----------------------------------
    movw    $0x1234, %ax            # ax = 0x1234
    subw    $0x1234, %ax            # ax = 0 (ZF=1) ; eax = 0xAAAA0000

    # ---- 16-bit logicals: AND/OR/XOR (CF=OF=0) ------------------------------
    movw    $0x0F0F, %ax            # eax = 0xAAAA0f0f
    andw    $0x00FF, %ax            # ax = 0x000f ; eax = 0xAAAA000f
    orw     $0x0F00, %ax            # ax = 0x0f0f ; eax = 0xAAAA0f0f
    xorw    $0xFFFF, %ax            # ax = 0xf0f0 ; eax = 0xAAAAf0f0

    # ---- 16-bit CMP / TEST (flags only, no dest write) ----------------------
    cmpw    $0xf0f0, %ax            # equal -> ZF=1, hi unchanged
    testw   %ax, %ax                # SF from bit15 (0xf0f0 -> SF=1), CF=OF=0

    # ---- 16-bit INC / DEC (CF preserved, OF/SF/ZF/AF/PF on 16-bit) ----------
    movw    $0x7FFF, %dx            # dx = 0x7fff (edx = 0xCCCC7fff)
    incw    %dx                     # dx = 0x8000 (OF=1, SF=1) ; edx = 0xCCCC8000
    decw    %dx                     # dx = 0x7fff (OF=1) ; edx = 0xCCCC7fff

    # ---- 16-bit NEG / NOT ----------------------------------------------------
    movw    $0x0001, %dx            # dx = 1 (edx = 0xCCCC0001)
    negw    %dx                     # dx = 0xffff (CF=1) ; edx = 0xCCCCffff
    notw    %dx                     # dx = 0x0000 ; edx = 0xCCCC0000

    # ---- 16-bit shifts: by 1, by imm8, by CL (count masked &0x1f) -----------
    movw    $0x8001, %ax            # ax = 0x8001 (eax = 0xAAAA8001)
    shlw    $1, %ax                 # ax = 0x0002 (CF=1 from bit15, OF defined) ; eax=0xAAAA0002
    movw    $0x8000, %ax            # ax = 0x8000
    shrw    $1, %ax                 # ax = 0x4000 (CF=0) ; eax=0xAAAA4000
    movw    $0x8000, %ax            # ax = 0x8000
    sarw    $1, %ax                 # ax = 0xc000 (arith, sign in) ; eax=0xAAAAc000
    movw    $0x0001, %ax            # ax = 1
    shlw    $4, %ax                 # ax = 0x10, by imm (OF undefined, masked)
    # shift by CL: CL currently = ecx low byte = 0x11 -> &0x1f = 0x11 = 17
    movb    $0x04, %cl              # set CL = 4 (cl write preserves ecx[31:8])
    movw    $0x00F0, %ax            # ax = 0x00f0
    shlw    %cl, %ax                # ax = 0x0f00 (shift by CL=4)
    # shift by CL count==0 => NO flag change (must match QEMU exactly)
    xorb    %cl, %cl               # CL = 0
    movw    $0x1248, %ax           # ax = 0x1248
    shrw    %cl, %ax               # count 0: ax unchanged, flags unchanged

    # ---- 16-bit ROL by 1 (affects only CF/OF) --------------------------------
    movw    $0x8001, %dx           # dx = 0x8001 (edx = 0xCCCC8001)
    rolw    $1, %dx                # dx = 0x0003 (CF=1, OF defined) ; edx=0xCCCC0003

    # ---- fold a couple of values into low halves so a bug is observable -----
    movw    $0x00AB, %si           # esi = 0xEEEE00ab
    movw    $0xCD00, %di           # edi = 0xFFFFcd00

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
