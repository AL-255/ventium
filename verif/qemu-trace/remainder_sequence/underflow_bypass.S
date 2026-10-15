/* Both zero-quotient bypasses must deliver UE; signed zero must not. */
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
    fldcw unmask_ue_pc24
    fprem
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0x8092,%eax
    jne bad
    fnclex
    fstpt result
    cmpl $0,result
    jne bad
    cmpl $0x80000000,result+4
    jne bad
    cmpw $0x5fc2,result+8
    jne bad
    fninit
    fldt infinity
    fldt negative_three_ulps
    fnclex
    fldcw unmask_ue_pc24
    fprem1
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0x8092,%eax
    jne bad
    fnclex
    fstpt result
    cmpl $0,result
    jne bad
    cmpl $0xc0000000,result+4
    jne bad
    cmpw $0xdfc3,result+8
    jne bad
    fninit
    fld1
    fldz
    fchs
    fldcw unmask_ue_pc24
    fprem1
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0,%eax
    jne bad
    fstpt result
    cmpl $0,result
    jne bad
    cmpl $0,result+4
    jne bad
    cmpw $0x8000,result+8
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
negative_three_ulps: .quad 3; .short 0x8000
infinity: .quad 0x8000000000000000; .short 0x7fff
unmask_ue_pc24: .short 0x006f
result: .space 10
    .section .note.GNU-stack,"",@progbits
