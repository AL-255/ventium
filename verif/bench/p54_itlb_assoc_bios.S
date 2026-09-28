/* Fixed-work protected-mode I-TLB conflict microbenchmark. Four executable
 * 4 KiB pages share a direct-mapped 16-entry TLB index; a 32-entry/four-way
 * I-TLB can keep all four. Different within-page offsets put each snippet in
 * a different I-cache set, avoiding an unrelated two-way I-cache thrash.
 * Copies position-independent snippets before PG. */
    .equ PD, 0x00070000
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
    movl $0x00080000, %esp

    /* Each copy is position-independent: local branches remain local and
     * cross-page transfers load their exact destination as a constant. */
    movl $snip1, %esi
    movl $0x00010000, %edi
    movl $(snip1_end-snip1), %ecx
    rep movsb
    movl $snip2, %esi
    movl $0x00020020, %edi
    movl $(snip2_end-snip2), %ecx
    rep movsb
    movl $snip3, %esi
    movl $0x00030040, %edi
    movl $(snip3_end-snip3), %ecx
    rep movsb
    movl $snip4, %esi
    movl $0x00040060, %edi
    movl $(snip4_end-snip4), %ecx
    rep movsb

    movl $PD, %edi
    pushl %edi
    movl $1024, %ecx
    xorl %eax, %eax
    rep stosl
    popl %edi
    movl $0x00000083, (%edi)  /* P|RW|PS, identity-mapped 4 MiB */
    movl %cr4, %eax
    orl $0x10, %eax
    movl %eax, %cr4
    movl $PD, %eax
    movl %eax, %cr3
    /* A real P5 BIOS enables caching before handing off to pageable code.
     * The reset value has CD/NW set; leaving them set would turn every
     * iteration into an uncached I-line fill and obscure the I-TLB question. */
    movl %cr0, %eax
    andl $0x9fffffff, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0
    movl $ITERATIONS, %ecx
    xorl %ebx, %ebx
    movl $0x00010000, %eax
    jmp *%eax

snip1:
    incl %ebx
    movl $0x00020020, %eax
    jmp *%eax
snip1_end:
snip2:
    incl %ebx
    movl $0x00030040, %eax
    jmp *%eax
snip2_end:
snip3:
    incl %ebx
    movl $0x00040060, %eax
    jmp *%eax
snip3_end:
snip4:
    incl %ebx
    decl %ecx
    jnz 1f
    cmpl $(4*ITERATIONS), %ebx
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
1:
    movl $0x00010000, %eax
    jmp *%eax
snip4_end:

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
