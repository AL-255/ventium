# =============================================================================
# Ventium M1 test: t_branch  --  Jcc condition-code coverage + sentinels
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Built like smoke:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal: drive the Jcc condition decode (tttn) across BOTH signed and unsigned
# comparisons and the equality/test forms, with a sentinel after every branch
# that must NOT execute if the condition logic is correct. Each sentinel writes
# a poison value into a checked GPR, so a wrong branch (taken-vs-not) shows up
# immediately in the differential trace. Exercises:
#   je/jne (ZF), jl/jge (SF^OF, signed), jg/jle (ZF|(SF^OF), signed),
#   jb/jae (CF, unsigned), ja/jbe (CF|ZF, unsigned), plus an unconditional jmp.
#
# Uses only the M1-implemented subset: mov r32,imm32, cmp (reg & imm forms),
# test r/m32,r32, Jcc rel8 (70+cc), jmp rel8 (EB). NO undefined-EFLAGS ops.
#
# We deliberately pick operand pairs where signed and unsigned orderings DIFFER
# (e.g. 0x7fffffff vs 0x80000000: signed +max > -min but unsigned max < ...),
# so a decoder that confuses signed/unsigned conditions diverges.
# =============================================================================

    .text
    .globl  _start
_start:
    movl    $0, %eax                # eax = pass-marker accumulator (incremented
                                    #       only on the CORRECT branch arms)

    # ---- (1) je taken on equality ------------------------------------------
    movl    $0x11111111, %ecx
    movl    $0x11111111, %edx
    cmpl    %edx, %ecx              # equal -> ZF=1
    je      .L1_ok                  # taken
    movl    $0xdead0001, %eax       # sentinel: must NOT run
.L1_ok:
    incl    %eax                    # eax = 1

    # ---- (2) jne taken on inequality ---------------------------------------
    movl    $0x00000001, %ecx
    movl    $0x00000002, %edx
    cmpl    %edx, %ecx              # 1 - 2 -> ZF=0
    jne     .L2_ok                  # taken
    movl    $0xdead0002, %eax       # sentinel: must NOT run
.L2_ok:
    incl    %eax                    # eax = 2

    # ---- (3) signed jl: 1 < 2  (taken) -------------------------------------
    movl    $0x00000001, %ecx
    cmpl    $0x00000002, %ecx       # 1 - 2 : SF=1,OF=0 -> SF^OF=1 -> jl taken
    jl      .L3_ok
    movl    $0xdead0003, %eax       # sentinel: must NOT run
.L3_ok:
    incl    %eax                    # eax = 3

    # ---- (4) signed jge with the signed/unsigned trap ----------------------
    # ecx = 0x7fffffff (= +2147483647, signed positive, unsigned large)
    # cmp against 0x80000000 sign-extended? No: use a register to avoid imm8.
    movl    $0x7fffffff, %ecx       # signed +max
    movl    $0x80000000, %edx       # signed -min (most negative)
    cmpl    %edx, %ecx              # signed: +max - (-min) overflows -> jge: NOT(SF^OF)
                                    # +max >= -min is TRUE signed -> jge taken
    jge     .L4_ok                  # taken (signed)
    movl    $0xdead0004, %eax       # sentinel: must NOT run
.L4_ok:
    incl    %eax                    # eax = 4

    # ---- (5) unsigned jb on the SAME operands (opposite outcome) -----------
    # unsigned: 0x7fffffff < 0x80000000 -> CF=1 -> jb taken
    cmpl    %edx, %ecx              # 0x7fffffff - 0x80000000 -> borrow, CF=1
    jb      .L5_ok                  # taken (unsigned below)
    movl    $0xdead0005, %eax       # sentinel: must NOT run
.L5_ok:
    incl    %eax                    # eax = 5

    # ---- (6) unsigned ja: 0x80000000 > 0x7fffffff (taken) ------------------
    cmpl    %ecx, %edx              # 0x80000000 - 0x7fffffff -> no borrow, CF=0, ZF=0
    ja      .L6_ok                  # taken (unsigned above: !CF & !ZF)
    movl    $0xdead0006, %eax       # sentinel: must NOT run
.L6_ok:
    incl    %eax                    # eax = 6

    # ---- (7) signed jg: 5 > 3 (taken) --------------------------------------
    movl    $5, %ecx
    cmpl    $3, %ecx                # 5 - 3 : ZF=0, SF=0, OF=0 -> jg taken
    jg      .L7_ok
    movl    $0xdead0007, %eax       # sentinel: must NOT run
.L7_ok:
    incl    %eax                    # eax = 7

    # ---- (8) test-based jne: nonzero AND -----------------------------------
    movl    $0x0000000c, %ecx
    testl   %ecx, %ecx              # ZF=0 (nonzero)
    jne     .L8_ok                  # taken
    movl    $0xdead0008, %eax       # sentinel: must NOT run
.L8_ok:
    incl    %eax                    # eax = 8

    # ---- (9) je NOT taken -> sentinel path must fall through correctly -----
    movl    $0x00000001, %ecx
    testl   %ecx, %ecx              # ZF=0
    je      .L9_skip                # NOT taken -> fall through
    incl    %eax                    # eax = 9  (THIS must run: branch not taken)
.L9_skip:

    # ---- (10) unconditional jmp over a poison sentinel ---------------------
    jmp     .L10_ok
    movl    $0xdead0010, %eax       # must NOT run
.L10_ok:
    incl    %eax                    # eax = 10 = 0x0a

    # eax should now be 0x0000000a if every branch decision was correct.

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall
