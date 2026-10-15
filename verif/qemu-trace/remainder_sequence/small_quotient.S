/* FPREM1(1.5,2) must select Q=1 and return -0.5, not the dividend. */
    .text
    .globl _start
_start:
    xor %ebp,%ebp
    mov $1,%esi
    mov $2,%edi
    fninit
    fldt divisor
    fldt dividend
    fprem1
    fnstsw %ax
    and $0x4700,%eax
    cmp $0x0200,%eax
    jne bad
    fstpt result
    cmpl $0,result
    jne bad
    cmpl $0x80000000,result+4
    jne bad
    cmpw $0xbffe,result+8
    jne bad
    inc %ebp
    xor %ebx,%ebx
    jmp exit
bad:
    mov $1,%ebx
exit:
    mov $1,%eax
    int $0x80
    .data
    .balign 16
divisor: .quad 0x8000000000000000; .short 0x4000
dividend: .quad 0xc000000000000000; .short 0x3fff
result: .space 10
    .section .note.GNU-stack,"",@progbits
