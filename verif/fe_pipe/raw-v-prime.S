/* Cold protected-mode resident-read priming microbenchmarks, not guest hooks.
 * KIND: four hot lines, address RAW, retained load/V pair, crossing read,
 *       high-parent byte load, read-ALU. RELOC selects common 256 MiB base.
 */
#ifndef KIND
#define KIND 0
#endif
#ifndef RELOC
#define RELOC 0
#endif
#ifndef OFFSET
#define OFFSET 0
#endif
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw $0x7000,%sp
    movl $0,0x500
    movl $0,0x504
    movl $0x0000ffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0x0000ffff,0x510
    movl $0x00cf9200,0x514
    movl $0x0000ffff,0x518
    movl $(0x00cf9a00 | (RELOC << 28)),0x51c
    movl $0x0000ffff,0x520
    movl $(0x00cf9200 | (RELOC << 28)),0x524
    movw $0x27,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm32
    .word 8
    .code32
    .section .text32,"ax"
pm32:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x12023,0x11000
    movl $0x12023,0x11100
    movl $0x000063,0x12000
    .set p,0
    .rept 16
    movl $(0xf0063+p*4096),(0x123c0+p*4)
    .set p,p+1
    .endr
    movl $0x180063,0x1223c
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    orl $0x80000000,%eax
    movl %eax,%cr0
    .byte 0xea
    .long client
    .word 0x18
client:
    movw $0x20,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movl $0x8fff0,%esp
    movl $0x8f100,%ebp
    movl $3,(%ebp)
    movl $5,32(%ebp)
    movl $7,64(%ebp)
    movl $11,96(%ebp)
#if KIND == 3
    movl $7,31(%ebp)
#elif KIND == 4
    movb $0x7f,31(%ebp)
#endif
    movl $16,%ecx
    xorl %esi,%esi
    xorl %edi,%edi
    jmp hot_loop
    .balign 32
    .space OFFSET,0x90
    .global hot_loop,query_load,load_pair_v,pair_u,pair_v
hot_loop:
#if KIND == 1
    leal 32(%ebp),%ebx
query_load:
    movl (%ebx),%eax
    addl %eax,%edi
#elif KIND == 4
    movl $0x12345600,%eax
query_load:
    movb 31(%ebp),%al
    addl %eax,%edi
#else
    incl %esi
query_load:
#if KIND == 5
    addl (%ebp),%edi
    addl 32(%ebp),%edi
    addl 64(%ebp),%edi
    addl 96(%ebp),%edi
#elif KIND == 3
    movl 31(%ebp),%eax
    addl %eax,%edi
#else
    movl (%ebp),%eax
#if KIND == 2
load_pair_v:
    movl $0x13579bdf,%ebx
#endif
    addl %eax,%edi
#if KIND == 0
    movl 32(%ebp),%eax
    addl %eax,%edi
    movl 64(%ebp),%eax
    addl %eax,%edi
    movl 96(%ebp),%eax
    addl %eax,%edi
#endif
#endif
#endif
    decl %ecx
    jnz hot_loop
#if KIND == 0 || KIND == 5
    cmpl $416,%edi
#elif KIND == 1
    cmpl $80,%edi
#elif KIND == 2
    cmpl $48,%edi
#elif KIND == 3
    cmpl $112,%edi
#elif KIND == 4
    cmpl $0x234567f0,%edi
#else
#error unsupported KIND
#endif
    jne fail
#if KIND != 1 && KIND != 4
    cmpl $16,%esi
    jne fail
#endif
    cmpl $0x8fff0,%esp
    jne fail
    jmp pair_u
    .balign 32,0x90
pair_u:
    movl $0x23456789,%ebx
pair_v:
    movl $0x3456789a,%edx
    cmpl $0x23456789,%ebx
    jne fail
    cmpl $0x3456789a,%edx
    jne fail
    movb $0x42,%al
    jmp exit
fail:
    movb $0x43,%al
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
