# mb_nearbr — AP-500 near-branch (rel32) + TEST-reg fast-path pairing microbench
# (review Action 6, batch 4). The loop body is padded >128 bytes so the back-edge
# `jnz` is a Jcc rel32 (0F 85, now fast-pathed); inside, `test %ebx,%ebx` (85, U)
# pairs with an independent `mov` (V), and the 0F 85 back-edge (PV) fills V after
# `dec`. Before batch 4 the 85 TEST-reg + 0F 8x Jcc rel32 forms fell to the slow
# FSM (~0% pairing). 30 iterations keeps the single-step golden fast.
    .text
    .globl _start
_start:
    movl    $30, %ecx
    movl    $0x12345678, %esi
    movl    $0x0F0F0F0F, %ebx
.Lrep:
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    testl %ebx, %ebx
    movl %esi, %eax
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
