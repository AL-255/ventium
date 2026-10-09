/* Four resident operand lines exceed the two registered reuse windows.
 * The loop uses ordinary instructions, data, permissions and memory requests.
 * Each tested form has the same fixed work under candidate and control.
 * KIND 0/1 MOVSX b/w; 2 ADDW read; 3 IMUL read; 4 FIADD32; 5/6 FCOM32/64;
 * 7 FST32, 8 fast MOV32 and 9 fast store are excluded controls.
 */
#ifndef KIND
#define KIND 0
#endif
#ifndef RELOC
#define RELOC 0
#endif
#ifndef OFFSET
#define OFFSET 17
#endif
#ifndef DATAOFFSET
#define DATAOFFSET 0
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
    movl $(0x8f100+DATAOFFSET),%ebp
    .irp displacement,0,64,128,192
    movl $0,\displacement(%ebp)
    movl $0,4+\displacement(%ebp)
    .endr
    fninit
    fld1
    xorl %eax,%eax
    xorl %esi,%esi
    movl $64,%ecx
    jmp hot_loop
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_loop,hot_end,pair_u,pair_v
hot_loop:
    .irp displacement,0,64,128,192
#if KIND == 0
    movsbl \displacement(%ebp),%eax
#elif KIND == 1
    movswl \displacement(%ebp),%eax
#elif KIND == 2
    addw \displacement(%ebp),%ax
#elif KIND == 3
    imull \displacement(%ebp),%eax
#elif KIND == 4
    fiaddl \displacement(%ebp)
#elif KIND == 5
    fcoms \displacement(%ebp)
#elif KIND == 6
    fcoml \displacement(%ebp)
#elif KIND == 7
    fsts \displacement(%ebp)
#elif KIND == 8
    movl \displacement(%ebp),%eax
#elif KIND == 9
    movl %eax,\displacement(%ebp)
#else
#error unsupported KIND
#endif
    .endr
hot_end:
    jmp pair_u
    .balign 32,0x90
pair_u:
    movl $0x23456789,%ebx
pair_v:
    incl %esi
    decl %ecx
    jnz hot_loop
    testl %eax,%eax
    jne fail
    cmpl $64,%esi
    jne fail
    cmpl $0x23456789,%ebx
    jne fail
    fistpl 0x8f204
    fwait
    cmpl $1,0x8f204
    jne fail
#if KIND == 7
    .irp displacement,0,64,128,192
    cmpl $0x3f800000,\displacement(%ebp)
    jne fail
    .endr
#endif
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
