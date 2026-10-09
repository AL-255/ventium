/* Ordinary cacheable RAM read/modify/write, U/V enabled by the harness.
 * OFFSET variants include crossing words and lines; no guest-specific hook. */
    .ifndef OFFSET
    .equ OFFSET, 0
    .endif
    .equ ITERATIONS, 128
    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp
    movl $0x500, %ebx
    movl $0, 0(%ebx)
    movl $0, 4(%ebx)
    movl $0x0000ffff, 8(%ebx)
    movl $0x00cf9a00, 12(%ebx)
    movl $0x0000ffff, 16(%ebx)
    movl $0x00cf9200, 20(%ebx)
    movw $0x17, 0x480
    movl $0x500, 0x482
    lgdt 0x480
    movl %cr0, %eax
    andl $0x9fffffff, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long pm32_entry
    .word 8
    .code32
    .section .text32, "ax"
pm32_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x90000, %esp
    movl $(0x80000+OFFSET), %ebx
    movl $0, 0(%ebx)
    movl $0, 8(%ebx)
    movl $ITERATIONS, %ecx
    xorl %esi, %esi
    .balign 32
    .global loop_body
loop_body:
    movl 0(%ebx), %eax
    incl %eax
    movl %eax, 0(%ebx)
    movl 8(%ebx), %edx
    addl $5, %edx
    movl %edx, 8(%ebx)
    incl %esi
    decl %ecx
    jnz loop_body
    cmpl $ITERATIONS, 0(%ebx)
    jne fail
    cmpl $(5*ITERATIONS), 8(%ebx)
    jne fail
    cmpl $ITERATIONS, %esi
    jne fail
    movl $0x42, %eax
    jmp exit
fail:
    movl $0x21, %eax
exit:
    movw $0xf4, %dx
    outb %al, %dx
halt:
    hlt
    jmp halt
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
