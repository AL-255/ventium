/* An unmasked DE outranks numeric UE and preserves the tiny operand. */
    .text
    .globl _start
_start:
    xor %ebp,%ebp
    mov $1,%esi
    mov $2,%edi
    fninit
    fld1
    fldt tiny
    fnclex
    fldcw unmask_de_ue
    fprem1
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0x8082,%eax
    jne bad
    fnclex
    fstpt result
    cmpl $1,result
    jne bad
    cmpl $0,result+4
    jne bad
    cmpw $0,result+8
    jne bad
    fninit
    fldz
    fldt tiny
    fnclex
    fldcw unmask_all_three
    fprem
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0x8081,%eax
    jne bad
    fnclex
    fstpt result
    cmpl $1,result
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
tiny: .quad 1; .short 0
unmask_de_ue: .short 0x036d
unmask_all_three: .short 0x036c
result: .space 10
    .section .note.GNU-stack,"",@progbits
