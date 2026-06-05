# mb_imul2 — 2-operand IMUL r32,r/m32,imm occupancy microbenchmark (occ=10).
# Validates the K_IMUL2 arm carries the same P5 multiply occupancy as 1-op MUL.
    .text
    .globl _start
_start:
    movl    $400, %ecx
.Lrep:
    movl    $0x00C0FFEE, %eax
    imul    $7, %eax, %eax      # IMUL r32, r/m32, imm8
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
