# mb_div16 — DIV r/m16 occupancy microbenchmark (p5model occ=25, NP, U-pipe held).
# DX:AX = 0x0000:0xC0DE / 7 -> AX=quot, DX=rem (no overflow).
    .text
    .globl _start
_start:
    movl    $400, %ecx
.Lrep:
    movl    $0x0000C0DE, %eax
    xorl    %edx, %edx
    movl    $0x07, %ebx
    divw    %bx
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
