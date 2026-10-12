/* Cold paged memory-divide owner/overlap fixture. KIND selects all eight
 * floating/integer width+direction forms. No restore, guest shortcut or mask.
 * Independent integer memory work runs while the division is outstanding;
 * queued FXCH and FNSTSW then consume the real ordered completion.
 */
#ifndef KIND
#define KIND 0
#endif
#ifndef OFFSET
#define OFFSET 0
#endif
#ifndef RELOC
#define RELOC 0
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
    movl $0x003063,0x1200c
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
    fninit
    movl $0x40000000,0x3000
    movl $0,0x3030
    movl $0x40000000,0x3034
    movl $2,0x3050
    movl $0x40800000,0x30a0
    fld1
    flds 0x30a0
    movl $0x3000,%eax
    movl $0x3040,%edi
    movl $0x573cbda1,%esi
    movl $7,%ebx
    xorl %ebp,%ebp
    movl $16,%ecx
    jmp hot_u
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_u,hot_load,hot_div,pair_v,exit_port
hot_u:
hot_load:
hot_div:
#if KIND == 0
    fdivs 0x3000
#elif KIND == 1
    fdivrs 0x3000
#elif KIND == 2
    fdivl 0x3030
#elif KIND == 3
    fdivrl 0x3030
#elif KIND == 4
    fidivs 0x3050
#elif KIND == 5
    fidivrs 0x3050
#elif KIND == 6
    fidivl 0x3050
#elif KIND == 7
    fidivrl 0x3050
#else
#error Invalid memory-divide fixture kind
#endif
    movl %esi,8(%edi)
    movl 8(%edi),%edx
    addl %edx,%ebx
    fxch %st(1)
    fxch %st(1)
    fnstsw 0x3060
    fstpl 0x3080
    flds 0x30a0
    incl %ebp
    incl %esi
    decl %ecx
    jz done
    jmp hot_u
done:
    fstpl 0x3080
    fstpl 0x3088
    cmpl $16,%ebp
    jne fail
    jmp verify_pair
    .balign 32,0x90
verify_pair:
    movl $0x12345678,%esi
pair_v:
    movl $0x76543210,%edi
    movb $0x42,%al
    jmp exit_port
fail:
    movb $0x43,%al
exit_port:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
