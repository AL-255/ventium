# mb_mul — MUL r/m32 occupancy microbenchmark (p5model occ=10, NP, U-pipe held).
# The native `*` is the bit-exact result; the modeled 10-cycle non-pipelined
# occupancy is the fidelity target (was 1-cycle / +7 before the review-response).
    .text
    .globl _start
_start:
    movl    $400, %ecx
.Lrep:
    movl    $0x00C0FFEE, %eax
    movl    $0x00000007, %ebx
    mull    %ebx                # EDX:EAX = EAX * EBX (unsigned)
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
