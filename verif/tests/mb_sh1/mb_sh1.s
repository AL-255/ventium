# mb_sh1 — AP-500 shift-by-1 (D1 /4../7) fast-path pairing microbenchmark
# (review Action 6, batch 3). Each SHL/SHR/SAR r/m32,1 (D1 — the x+x/halve idiom)
# is U (PU: leads a pair) interleaved with an independent `mov reg,reg` (V): with
# D1 now fast-pathed they PAIR (~50%, matching p5model); before batch 3 they fell
# to the slow FSM (~0% pairing).
    .text
    .globl _start
_start:
    movl    $400, %ecx
    movl    $0x12345678, %esi
    movl    $0x0F0F0F0F, %ebx
    movl    $0x33333333, %edx
.Lrep:
    shll    $1, %ebx
    movl    %esi, %eax
    shrl    $1, %edx
    movl    %esi, %edi
    sarl    $1, %ebx
    movl    %esi, %ebp
    shll    $1, %edx
    movl    %esi, %eax
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
