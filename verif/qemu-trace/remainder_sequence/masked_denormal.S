/* Numeric result is unchanged, but a masked denormal operand must raise DE. */
    .text
    .globl _start
_start:
    xor %ebp,%ebp
    mov $1,%esi
    mov $2,%edi
    fninit
    fldt divisor
    fldt dividend
    fprem
    fnstsw %ax
    and $0x473f,%eax
    cmp $0x0002,%eax
    jne bad
    fstpt result
    cmpl $3,result
    jne bad
    cmpl $0,result+4
    jne bad
    cmpw $0,result+8
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
dividend: .quad 3; .short 0
result: .space 10
    .section .note.GNU-stack,"",@progbits
