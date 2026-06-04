# =============================================================================
# Ventium M5 regression: mb_jmppair   (unconditional short JMP V-pairing)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# REGRESSION for M5 adversarial finding [med] (unconditional short JMP, opcode EB,
# never filled the V slot). The oracle classifies JMP as pclass=PV /
# pairs_second=true (verif/qemu-plugins/p5trace.c:271-273): a `<UV op>; jmp` group
# pairs (mov in U, jmp in V). M4 set pairs_second=0 for EB, so the RTL paired
# essentially nothing in such groups (e.g. the p2align `mov; jmp` filler), costing
# an extra clock per group. M5 makes EB pairs_second=1 (V-only-pairable, like Jcc)
# and charges an unconditional-jmp mispredict as 3 (not the V-cond 4).
#
# STRUCTURE: a counted hot loop whose body is a chain of `mov reg,imm ; jmp .+0`
# (a jmp to the very next instruction, so it is a no-op redirect that the BTB
# learns to predict-taken after pass 1). Each (mov,jmp) must PAIR (mov U, jmp V).
# The jmp target is the fall-through, so there is no I$ pressure; the loop is L1-
# resident and CPI converges to the paired throughput. If the jmp does not pair
# the group costs an extra clock and the abs-cyc diverges from the oracle.
# =============================================================================
    .text
    .globl  _start
_start:
    movl    $200, %ecx              # outer iterations
.Lrep:
    .rept   12
    movl    $1, %eax                # U: simple MOV (UV-pairable)
    jmp     1f                      # V: short JMP to the next insn (V-pairable)
1:
    .endr
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80
