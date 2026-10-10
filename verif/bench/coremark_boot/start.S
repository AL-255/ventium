/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
.section .start,"ax"
.code16
.global _start16
_start16:
    cli
    cld
    lgdt %cs:(gdt_desc-_start16)
    movl %cr0,%eax
    andl $0x9ffffff3,%eax /* CD=NW=EM=TS=0, preserve other CR0 state. */
    orl $1,%eax
    movl %eax,%cr0
    ljmpl $8,$_start32
.balign 8
gdt:
    .quad 0
    .quad 0x00cf9a000000ffff
    .quad 0x00cf92000000ffff
gdt_desc:
    .word 23
    .long gdt
.code32
_start32:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movl $0x90000,%esp
    xorl %ebp,%ebp
    movl $__bss_start,%edi
    movl $__bss_end,%ecx
    subl %edi,%ecx
    shrl $2,%ecx
    xorl %eax,%eax
    rep stosl
    call main
    /* QEMU exits here; on the PC/FPGA this unused port has no acceptance role. */
    movb $0x10,%al
    outb %al,$0xf4
    cli
1:  hlt
    jmp 1b
.section .note.GNU-stack,"",@progbits
