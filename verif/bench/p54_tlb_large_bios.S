/* Fixed-work BIOS microbenchmark for P54 4 MiB data-TLB residency. */
    .equ PD, 0x00010000
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

    /* Eight 4 KiB pages share low VPN set bits [3:0] and one 4 MiB PDE.
     * Distinct values make a wrong-frame or wrong-offset hit fail loudly. */
    movl $1, 0x00008000
    movl $2, 0x00018000
    movl $3, 0x00028000
    movl $4, 0x00038000
    movl $5, 0x00048000
    movl $6, 0x00058000
    movl $7, 0x00068000
    movl $8, 0x00078000

    movl $PD, %edi
    pushl %edi
    movl $1024, %ecx
    xorl %eax, %eax
    rep stosl
    popl %edi
    movl $0x00000083, (%edi)  /* P|RW|PS, identity-mapped 4 MiB page */
    movl %cr4, %eax
    orl $0x10, %eax
    movl %eax, %cr4
    movl $PD, %eax
    movl %eax, %cr3
    movl %cr0, %eax
    /* BIOS reset leaves CD/NW set. Use normal cache-enabled DRAM here so a
     * TLB-capacity result is not dominated by uncached line service. */
    andl $0x9fffffff, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0

    movl $ITERATIONS, %ecx
    .global loop_body
loop_body:
    movl 0x00008000, %eax
    addl 0x00018000, %eax
    addl 0x00028000, %eax
    addl 0x00038000, %eax
    addl 0x00048000, %eax
    addl 0x00058000, %eax
    addl 0x00068000, %eax
    addl 0x00078000, %eax
    cmpl $36, %eax
    jne fail
    decl %ecx
    jnz loop_body
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
