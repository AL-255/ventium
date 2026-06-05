# =============================================================================
# Ventium review-response: t_bcd  --  BCD / ASCII-adjust instruction coverage
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# Closes the REVIEW_Jun5.md "full integer ISA" HALT gap: AAA(0x37) AAS(0x3F)
# DAA(0x27) DAS(0x2F) AAM(0xD4 ib) AAD(0xD5 ib) — previously d_unknown->HALT,
# now executed in S_EXEC matching QEMU helper_aaa/aas/daa/das/aam/aad EXACTLY.
#
# Differential vs qemu-i386: QEMU is the oracle, so this program need only
# EXERCISE diverse inputs; the comparator grades every retired instruction
# (full GPRs + the DEFINED EFLAGS — the architecturally-undefined flags
# OF/[SF/ZF/PF for AAA/AAS]/[CF/AF for AAM/AAD] are removed by
# tracefmt.eflags_undefined_mask). The inputs deliberately hit every code path:
#   * AL low-nibble <=9 and >9; AF=0 and AF=1 (set via a real ADD/SUB);
#   * AAA/AAS icarry (AL>0xF9 / AL<6) feeding the AH +/-1 by 2;
#   * DAA/DAS high adjust (old_AL>0x99) and CF-in (stc);
#   * AAM/AAD base 10, base 16, and a non-standard base 7.
# AAM with base 0 (a #DE this core defers, like native DIV-by-zero) is NOT used.
# =============================================================================

    .text
    .globl _start
_start:
    # ===================== AAA (0x37) =====================
    movl    $0x00000005, %eax
    clc
    aaa                                  # low<=9, AF=0 -> no adjust
    movl    $0x0000000c, %eax
    clc
    aaa                                  # low>9 -> adjust, CF=AF=1
    movl    $0x000000ff, %eax
    clc
    aaa                                  # AL>0xF9 -> icarry, AH += 2
    movl    $0x000020ff, %eax
    clc
    aaa                                  # icarry with nonzero AH
    movb    $0x09, %al
    addb    $0x08, %al                   # AL=0x11, AF=1
    aaa                                  # AF=1 forces adjust (low<=9)
    movb    $0x28, %al
    addb    $0x19, %al                   # AL=0x41, AF=1
    aaa

    # ===================== AAS (0x3F) =====================
    movl    $0x00000205, %eax
    clc
    aas                                  # low<=9 -> no adjust
    movl    $0x0000020a, %eax
    clc
    aas                                  # low>9 -> AH -= 1, CF=AF=1
    movl    $0x00000003, %eax
    clc
    aas                                  # AL<6 -> icarry path on adjust? (low<=9 here)
    movb    $0x10, %al
    subb    $0x01, %al                   # AL=0x0F, AF=1
    aas
    movl    $0x00000100, %eax
    movb    $0x02, %al
    aas                                  # AL=2 (<6), low<=9 -> no adjust

    # ===================== DAA (0x27) =====================
    movb    $0x00, %al
    clc
    daa                                  # zero -> ZF
    movb    $0x1a, %al
    clc
    daa                                  # low>9 -> +6
    movb    $0x9a, %al
    clc
    daa                                  # low>9 AND old_al>0x99 -> +6 then +0x60
    movb    $0xa0, %al
    clc
    daa                                  # old_al>0x99 -> +0x60
    movb    $0x15, %al
    addb    $0x06, %al                   # AL=0x1b, AF=1
    daa
    movb    $0x99, %al
    stc
    daa                                  # CF-in -> +0x60
    movb    $0x99, %al
    addb    $0x99, %al                   # AL=0x32, CF=1, AF=1
    daa

    # ===================== DAS (0x2F) =====================
    movb    $0x00, %al
    clc
    das
    movb    $0x1a, %al
    clc
    das                                  # low>9 -> -6
    movb    $0xff, %al
    clc
    das                                  # low>9 + old_al>0x99 -> -6 then -0x60
    movb    $0x9a, %al
    clc
    das
    movb    $0x20, %al
    subb    $0x01, %al                   # AL=0x1f, AF=1
    das
    movb    $0x05, %al
    stc
    das                                  # CF-in + low<=9

    # ===================== AAM (0xD4 ib) =====================
    movb    $0x00, %al
    aam     $0x0a                        # 0 -> AH=0 AL=0 (ZF)
    movb    $0x09, %al
    aam     $0x0a                        # 9 -> AH=0 AL=9
    movb    $0x0f, %al
    aam     $0x0a                        # 15 -> AH=1 AL=5
    movb    $0x63, %al
    aam     $0x0a                        # 99 -> AH=9 AL=9
    movb    $0xff, %al
    aam     $0x10                        # base 16: AH=15 AL=15
    movb    $0x50, %al
    aam     $0x07                        # base 7: 80 -> AH=11 AL=3

    # ===================== AAD (0xD5 ib) =====================
    xorl    %eax, %eax
    aad     $0x0a                        # AH=0 AL=0 -> 0
    movw    $0x0105, %ax
    aad     $0x0a                        # AH=1 AL=5 -> 15 (0x0F)
    movw    $0x0909, %ax
    aad     $0x0a                        # 99 -> 0x63
    movw    $0x0f0f, %ax
    aad     $0x10                        # base 16: 0xFF
    movw    $0x0306, %ax
    aad     $0x07                        # base 7: 3*7+6 = 27 = 0x1B

    # ===================== clean exit =====================
    movl    $1, %eax                     # __NR_exit
    xorl    %ebx, %ebx                   # status 0
    int     $0x80                        # halt
