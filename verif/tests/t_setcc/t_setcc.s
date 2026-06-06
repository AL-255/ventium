# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_setcc  --  SETcc r/m8 across conditions (+ partial reg)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -nostdlib -static -Wl,-Ttext=0x08048000
#
# Bucket: setcc. SETcc = 0F 90+cc, writes 0x01 (cond true) or 0x00 (false) to
# an 8-bit r/m destination. SETcc reads EFLAGS and DOES NOT MODIFY ANY FLAGS,
# so NO eflags masking is needed for this program (no undefined bits) -- the
# only correctness risk is partial-register semantics: the byte write must
# leave the rest of the destination register intact.
#
# Partial-register coverage:
#   * SETcc AL  -> bits [7:0] set, [31:8] preserved.
#   * SETcc AH/BH/CH/DH -> bits [15:8] set, others preserved.
#   * SETcc to a memory byte.
# We seed each target register with a recognizable pattern (0xnn......) before
# the byte write so a too-wide write (e.g. zeroing the upper bytes) diverges.
#
# Conditions exercised (tttn decode), each after a cmp/test that makes the
# answer deterministic; both the TRUE and FALSE arm of several pairs:
#   sete/setz, setne/setnz (ZF)
#   setl/setge (SF^OF, signed),  setg/setle (ZF|(SF^OF), signed)
#   setb/setc/setnae, setae/setnc/setnb (CF, unsigned)
#   seta/setnbe, setbe/setna (CF|ZF, unsigned)
#   sets, setns (SF),  seto, setno (OF),  setp/setpe, setnp/setpo (PF)
# =============================================================================

    .text
    .globl  _start
_start:

    # =====================================================================
    # ZF group: sete / setne after an equal compare (ZF=1)
    # =====================================================================
    movl    $0xaaaaaa00, %eax       # AL target, [31:8]=0xaaaaaa
    movl    $0x11111111, %ecx
    cmpl    %ecx, %ecx              # equal -> ZF=1
    sete    %al                     # AL = 1  (eax = 0xaaaaaa01)
    setne   %ah                     # AH = 0  (eax = 0xaaaa0001)  ZF=1 -> ne false

    # =====================================================================
    # ZF group: not equal (ZF=0)
    # =====================================================================
    movl    $0xbbbbbb00, %ebx       # BL/BH targets
    movl    $0x00000001, %ecx
    movl    $0x00000002, %edx
    cmpl    %edx, %ecx              # 1 - 2 -> ZF=0
    sete    %bl                     # BL = 0 (ebx = 0xbbbbbb00)
    setne   %bh                     # BH = 1 (ebx = 0xbbbb0100)

    # =====================================================================
    # signed group: setl / setge with operands that overflow
    # cmp 0x7fffffff, 0x80000000 : signed +max - (-min) overflows
    #   signed: +max >= -min TRUE  -> setge true, setl false
    # =====================================================================
    movl    $0xcccccc00, %eax       # reuse AL/AH
    movl    $0x7fffffff, %ecx
    movl    $0x80000000, %edx
    cmpl    %edx, %ecx              # signed: SF^OF = 0 -> ge
    setl    %al                     # AL = 0 (eax = 0xcccccc00)
    setge   %ah                     # AH = 1 (eax = 0xcccc0100)

    # signed group: setg / setle with 5 vs 3 (5 > 3)
    movl    $0xdddddd00, %ebx
    movl    $5, %ecx
    cmpl    $3, %ecx                # 5 - 3 : ZF=0,SF=0,OF=0 -> g true, le false
    setg    %bl                     # BL = 1 (ebx = 0xdddddd01)
    setle   %bh                     # BH = 0 (ebx = 0xdddd0001)

    # =====================================================================
    # unsigned group: setb / setae on the overflow pair
    # unsigned: 0x7fffffff < 0x80000000 -> CF=1 -> setb true, setae false
    # =====================================================================
    movl    $0xeeeeee00, %eax
    movl    $0x7fffffff, %ecx
    movl    $0x80000000, %edx
    cmpl    %edx, %ecx              # CF=1
    setb    %al                     # AL = 1 (eax = 0xeeeeee01)
    setae   %ah                     # AH = 0 (eax = 0xeeee0001)

    # unsigned group: seta / setbe ; 0x80000000 > 0x7fffffff -> CF=0,ZF=0
    movl    $0x11223300, %ebx
    cmpl    %ecx, %edx              # 0x80000000 - 0x7fffffff : CF=0,ZF=0 -> a true
    seta    %bl                     # BL = 1 (ebx = 0x11223301)
    setbe   %bh                     # BH = 0 (ebx = 0x11220001)

    # =====================================================================
    # SF group: sets / setns after a subtraction yielding a negative result
    # =====================================================================
    movl    $0x44556600, %ecx       # CL/CH targets
    movl    $0x00000001, %eax
    cmpl    $0x00000002, %eax       # 1 - 2 = -1 -> SF=1
    sets    %cl                     # CL = 1 (ecx = 0x44556601)
    setns   %ch                     # CH = 0 (ecx = 0x44550001)

    # =====================================================================
    # OF group: seto / setno after a signed overflow
    # 0x7fffffff + 1 -> 0x80000000 : OF=1
    # =====================================================================
    movl    $0x778899aa, %edx       # DL/DH targets (note: low byte will change)
    movl    $0x7fffffff, %eax
    addl    $1, %eax                # OF=1, SF=1
    seto    %dl                     # DL = 1 (edx = 0x77889901)
    setno   %dh                     # DH = 0 (edx = 0x77880001)

    # OF group false: 1 + 1 -> no overflow
    movl    $0x99aabb00, %eax
    movl    $0x00000001, %ecx
    addl    $1, %ecx                # OF=0
    seto    %al                     # AL = 0 (eax = 0x99aabb00)
    setno   %ah                     # AH = 1 (eax = 0x99aa0100)

    # =====================================================================
    # PF group: setp / setnp ; result 0x00 has even parity -> PF=1
    # =====================================================================
    movl    $0x66778800, %ebx
    movl    $0x000000ff, %eax
    andl    $0x0000000f, %eax       # result 0x0f : 4 one-bits -> even parity PF=1
    setp    %bl                     # BL = 1 (ebx = 0x66778801)
    setnp   %bh                     # BH = 0 (ebx = 0x66770001)

    # PF false: result 0x07 (3 one-bits -> odd parity -> PF=0)
    movl    $0x32104500, %ecx
    movl    $0x00000007, %eax
    andl    $0x0000000f, %eax       # 0x07 -> odd parity PF=0
    setp    %cl                     # CL = 0 (ecx = 0x32104500)
    setnp   %ch                     # CH = 1 (ecx = 0x32100100)

    # =====================================================================
    # test-based condition + SETcc to MEMORY (r/m8, mod=00 disp32)
    # =====================================================================
    movl    $0x00000000, %eax
    testl   %eax, %eax              # ZF=1
    sete    flag_byte               # mem[flag_byte] = 1
    setne   flag_byte2              # mem[flag_byte2] = 0
    movzbl  flag_byte, %esi         # esi = 1
    movzbl  flag_byte2, %edi        # edi = 0

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt

    .data
    .align 4
flag_byte:  .byte 0xff              # overwritten by sete
flag_byte2: .byte 0xff              # overwritten by setne
            .byte 0x00
            .byte 0x00
