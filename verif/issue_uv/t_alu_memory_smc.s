# Cached memory ALU straddling an I-line: change EA suffix, then opcode.
# Three phases each require 100 architecturally checked source retirements.
.text
.globl _start, crossing, pass_exit, fail_exit
_start:
    xorl %esi,%esi
    movl $100,%ebx
    movl $9,%edx
reset_operand:
    movl $10,%eax
    jmp crossing
.balign 32
.space 31,0x90
crossing:
    subl operand_one,%eax
    cmpl %edx,%eax
    jne fail
    decl %ebx
    jnz reset_operand
    incl %esi
    cmpl $1,%esi
    je patch_suffix
    cmpl $2,%esi
    je patch_opcode
    movl $1,%eax
    xorl %ebx,%ebx
pass_exit:
    int $0x80
patch_suffix:
    movl $operand_three,crossing+2
    movl $7,%edx
    movl $100,%ebx
    jmp reset_operand
patch_opcode:
    movb $0x33,crossing        # SUB r32,m32 -> XOR r32,m32
    movl $9,%edx
    movl $100,%ebx
    jmp reset_operand
fail:
    movl $1,%eax
    movl $1,%ebx
fail_exit:
    int $0x80
.data
.balign 4
operand_one: .long 1
operand_three: .long 3
.section .note.GNU-stack,"",@progbits
