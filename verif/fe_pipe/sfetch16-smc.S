/* Cold reset, cache-enabled 16-bit SMC. Alternate a MOV AX,imm16 with
 * three NOPs at the same RAM address, including prefix/line/page seams.
 * A real far CALL orders each edit before execution; no debugger writes.
 * Real, protected16 and paged16 modes finish with an actual 32-bit U/V pair.
 */
#ifndef MODE
#define MODE 0
#endif
#ifndef PREFIX
#define PREFIX 0
#endif
#ifndef OFFSET
#define OFFSET 0
#endif
#ifndef PAGE_TAIL
#define PAGE_TAIL 0
#endif
#if PREFIX > 12 || PREFIX < 0
#error invalid prefix count
#endif
    .global hot_instruction, hot_end, hot_physical, hot_cs
#if PAGE_TAIL
    .set hot_instruction,4096-32+OFFSET
#else
    .set hot_instruction,0x300+OFFSET
#endif
    .set hot_end,hot_instruction+PREFIX+3
    .set hot_physical,0x9000+hot_instruction
#if MODE == 0
    .set hot_cs,0x900
#else
    .set hot_cs,0x28
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
    movl $0x00cf9a00,0x50c /* 08: flat32 code */
    movl $0x0000ffff,0x510
    movl $0x00cf9200,0x514 /* 10: flat32 data */
    movl $0x0000ffff,0x518
    movl $0x00009a0f,0x51c /* 18: ROM16 code, base f0000 */
    movl $0x0000ffff,0x520
    movl $0x00009200,0x524 /* 20: data16, base zero */
    movl $0x9000ffff,0x528
    movl $0x00009a00,0x52c /* 28: RAM16 code, base 9000 */
    movw $0x2f,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    movl %eax,%cr0
#if MODE == 1
    orl $1,%eax
    movl %eax,%cr0
    .byte 0xea
    .word setup16-_start16
    .word 0x18
#elif MODE == 2
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long page_setup
    .word 8
#elif MODE != 0
#error invalid mode
#endif
setup16:
#if MODE != 0
    movw $0x20,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
#endif
    movw $hot_physical,%di
    movw $PREFIX,%cx
    movb $0x3e,%al
    rep stosb
    movb $0xcb,hot_physical+PREFIX+3 /* far return at fixed endpoint */
    xorw %bx,%bx
edit:
    testw $1,%bx
    jnz nops
    movw $0x34b8,hot_physical+PREFIX
    movb $0x12,hot_physical+PREFIX+2
    movw $0x1234,%bp
    jmp invoke
nops:
    movw $0x9090,hot_physical+PREFIX
    movb $0x90,hot_physical+PREFIX+2
    movw $0x5678,%bp
invoke:
    movw $0x5678,%ax
    .byte 0x9a
    .word hot_instruction
    .word hot_cs
    .global after_hot
after_hot:
    cmpw %bp,%ax
    jne fail16
    incw %bx
    cmpw $16,%bx
    jne edit
#if MODE == 0
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
#endif
    .byte 0x66,0xea
    .long finish32
    .word 8
fail16:
    movw $0xf4,%dx
    movb $0x43,%al
    outb %al,%dx
    hlt
    .code32
    .section .text32,"ax"
page_setup:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x12023,0x11000
    movl $0x000063,0x12000
    movl $0x006063,0x12018 /* far CALL pushes below the initial SP=7000 */
    movl $0x007063,0x1201c
    movl $0x009063,0x12024
    movl $0x00a063,0x12028
    .set p,0
    .rept 16
    movl $(0xf0063+p*4096),(0x123c0+p*4)
    .set p,p+1
    .endr
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    orl $0x80000000,%eax
    movl %eax,%cr0
    .byte 0xea
    .long setup16-_start16
    .word 0x18
finish32:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    jmp pair_u
    .balign 32,0x90
    .global pair_u, pair_v
pair_u:
    movl $0x12345678,%ebx
pair_v:
    movl $0x23456789,%edx
    cmpl $0x12345678,%ebx
    jne fail32
    cmpl $0x23456789,%edx
    jne fail32
    movb $0x42,%al
    jmp exit
fail32:
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
