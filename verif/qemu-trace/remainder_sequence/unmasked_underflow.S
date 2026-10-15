/* Cold normal-operand cancellation: UM=0 commits the exact scaled result. */
    .text
    .globl _start
_start:
    xor %ebp,%ebp
    mov $1,%esi
    mov $2,%edi
    fninit
    fldt minimum_normal
    fldt minimum_plus_ulp
    fldcw unmask_ue_pc24
    fprem
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0x8090,%eax
    jne bad
    fnclex
    fstpt result
    cmpl $0,result
    jne bad
    cmpl $0x80000000,result+4
    jne bad
    cmpw $0x5fc2,result+8
    jne bad
    /* FPREM1 rounds the quotient to one and reverses the result sign. */
    fninit
    fldt minimum_plus_ulp
    fldt minimum_normal
    fldcw unmask_ue_pc24
    fprem1
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0x8090,%eax
    jne bad
    fnclex
    fstpt result
    cmpl $0,result
    jne bad
    cmpl $0x80000000,result+4
    jne bad
    cmpw $0xdfc2,result+8
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
minimum_normal: .quad 0x8000000000000000; .short 1
minimum_plus_ulp: .quad 0x8000000000000001; .short 1
unmask_ue_pc24: .short 0x006f
result: .space 10
    .section .note.GNU-stack,"",@progbits
