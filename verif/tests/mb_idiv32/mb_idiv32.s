# mb_idiv32 — IDIV r/m32 occupancy microbenchmark (p5model occ=46, NP, U-pipe held;
# a few clocks over DIV r/m32's 41 for the sign handling). EDX:EAX / EBX signed.
    .text
    .globl _start
_start:
    movl    $400, %ecx
.Lrep:
    movl    $0x00C0FFEE, %eax
    xorl    %edx, %edx
    movl    $7, %ebx
    idivl   %ebx
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
