/* Protected-mode I-fill reuse after an unrelated store and CR3 flush.
 * The repeated MOV CR3 invalidates the upstream I-cache, while the physical
 * code line in L1D's I-fill staging slot is unchanged. No executable byte is
 * written. The candidate must keep that slot across the data store. */
    .ifndef ITERATIONS
    .equ ITERATIONS, 200
    .endif

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
    movl $0x00000500, %ebx
    movl $0, 0(%ebx)
    movl $0, 4(%ebx)
    movl $0x0000ffff, 8(%ebx)
    movl $0x00cf9a00, 12(%ebx)
    movl $0x0000ffff, 16(%ebx)
    movl $0x00cf9200, 20(%ebx)
    movw $0x0017, 0x0480
    movl $0x00000500, 0x0482
    lgdt 0x0480
    movl %cr0, %eax
    andl $0x9fffffff, %eax      /* clear reset CD/NW; normal cacheable code */
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long pm32_entry
    .word 0x08

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x00090000, %esp
    movl $0x00070000, %eax      /* CR3; PG stays disabled */
    movl %eax, %cr3
    movl $ITERATIONS, %ecx
    xorl %ebx, %ebx
    .balign 32
    .global loop_body
loop_body:
    movl %ebx, 0x00080000     /* unrelated physical data-line store */
    movl %eax, %cr3           /* invalidate I$, not physical RAM */
    incl %ebx
    decl %ecx
    jnz loop_body
    cmpl $ITERATIONS, %ebx
    jne fail
    movl 0x00080000, %edx
    cmpl $(ITERATIONS-1), %edx
    jne fail
    movl $0x42, %eax
    jmp exit
fail:
    movl $0x21, %eax
exit:
    movw $0x00f4, %dx
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
