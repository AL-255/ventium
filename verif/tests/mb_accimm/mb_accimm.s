# mb_accimm — AP-500 accumulator-immediate fast-path pairing microbenchmark
# (review Action 6, batch 1). Each `<ALU eAX,imm32>` (U) is interleaved with an
# independent `mov reg,reg` (V): with the accumulator short forms (05/0D/25/35..)
# now fast-pathed they PAIR (pairing% ~50, matching p5model); before the fix they
# fell to the slow FSM and serialized (~0% pairing, ~2x the cycles).
    .text
    .globl _start
_start:
    movl    $400, %ecx
    movl    $0x12345678, %esi
.Lrep:
    addl    $0x11111111, %eax
    movl    %esi, %ebx
    subl    $0x22222222, %eax
    movl    %esi, %edx
    andl    $0x7FFFFFFF, %eax
    movl    %esi, %edi
    xorl    $0x55555555, %eax
    movl    %esi, %ebp
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
