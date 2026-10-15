/* IE/DE aborts must set sticky status and retain both operands. */
    .text
    .globl _start
_start:
    xor %ebp,%ebp
    mov $1,%esi
    mov $2,%edi
    fninit
    fldt tiny
    fldt dividend
    fldcw unmask_de
    fprem1
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0x8082,%eax
    jne bad
    fnclex
    fstpt result
    cmpl $0,result
    jne bad
    cmpl $0xc0000000,result+4
    jne bad
    cmpw $0x3fff,result+8
    jne bad
    fstpt result
    cmpl $3,result
    jne bad
    cmpl $0,result+4
    jne bad
    cmpw $0,result+8
    jne bad
    fninit
    fldz
    fldt dividend
    fldcw unmask_ie
    fprem
    fnstsw %ax
    and $0x80ff,%eax
    cmp $0x8081,%eax
    jne bad
    fnclex
    fstpt result
    cmpl $0,result
    jne bad
    cmpl $0xc0000000,result+4
    jne bad
    cmpw $0x3fff,result+8
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
tiny: .quad 3; .short 0
dividend: .quad 0xc000000000000000; .short 0x3fff
unmask_de: .short 0x037d
unmask_ie: .short 0x037e
result: .space 10
    .section .note.GNU-stack,"",@progbits
