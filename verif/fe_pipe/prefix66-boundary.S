/* Cold-reset prefix ownership at a real page/CS boundary and after SMC.
 * KIND 0: mapped crossing; 1: demand-map missing instruction tail;
 * 2: finite CS truncates immediate (#GP, no partial commit); 3: SMC revisit.
 * The probe executes from ordinary RAM, not writable QEMU BIOS storage.
 */
#ifndef KIND
#define KIND 0
#endif
#ifndef OFFSET
#define OFFSET 4093
#endif
#ifndef RELOC
#define RELOC 0
#endif
#define HOT (0x2f000 + OFFSET)
    .global hot_probe
    .set hot_probe,HOT
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
    movl $((HOT+2) & 0xffff),0x528
    movl $(0x00409a00 | (((HOT+2) >> 16) << 16) | (RELOC << 28)),0x52c
    movw $0x2f,0x480
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
    movl $0x8fff0,%esp
    movl $0,0x2000
    movl $0,0x2004
    /* add ax,1234; mov ebx,456789ab; jmp edx */
    movl $0x12340566,HOT
    movl $0x6789abbb,HOT+4
    movb $0x45,HOT+8
    movw $0xe2ff,HOT+9
    .macro gate vector,handler
    movl $\handler,%eax
    movl %eax,%ebx
    andl $0xffff,%eax
    orl $0x00180000,%eax
    movl %eax,(0x1000+\vector*8)
    andl $0xffff0000,%ebx
    orl $0x8e00,%ebx
    movl %ebx,(0x1004+\vector*8)
    .endm
    gate 14,pf_handler
    gate 13,gp_handler
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0x12063,0x11000
    movl $0x12063,0x11100
    movl $0x000063,0x12000
    movl $0x001063,0x12004
    movl $0x002063,0x12008
    movl $0x012063,0x12048
    movl $0x02f063,0x120bc
#if KIND == 1
    movl $0x030062,0x120c0
#else
    movl $0x030063,0x120c0
#endif
    movl $0x08f063,0x1223c
    .set p,0
    .rept 16
    movl $(0xf0063+p*4096),(0x123c0+p*4)
    .set p,p+1
    .endr
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
    movl $0x12348001,%eax
    movl $0x11112222,%ebx
    movl $returned,%edx
    .global enter_probe
enter_probe:
    .byte 0xea
    .long HOT
#if KIND == 2
    .word 0x28
#else
    .word 0x18
#endif
    .global returned
returned:
#if KIND == 2
    cmpl $0x12348001,%eax
    jne fail
    cmpl $0x11112222,%ebx
    jne fail
    cmpl $1,0x2004
    jne fail
#else
    cmpl $0x12349235,%eax
    jne fail
    cmpl $0x456789ab,%ebx
    jne fail
    cmpl $0,0x2004
    jne fail
#endif
#if KIND == 1
    cmpl $1,0x2000
#else
    cmpl $0,0x2000
#endif
    jne fail
#if KIND == 3
    /* Retain the same prefix/EIP but replace its immediate through a real
     * CPU store; the subsequent taken branch refetches those changed bytes. */
    movw $0x4321,HOT+2
    movl $0x12348001,%eax
    movl $0x11112222,%ebx
    movl $returned_smc,%edx
    movl $HOT,%esi
    jmp *%esi
returned_smc:
    cmpl $0x1234c322,%eax
    jne fail
    cmpl $0x456789ab,%ebx
    jne fail
#endif
    /* A separate ordinary pair proves this is not globally slow/STEP mode. */
    .balign 16,0x90
    .global pair_u,pair_v
pair_u:
    movl $0x76543210,%esi
pair_v:
    movl $0xfedcba98,%edi
    movb $0x42,%al
    jmp exit_port
fail:
    movb $0x43,%al
exit_port:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
pf_handler:
    cmpl $0,(%esp)
    jne fail
    cmpl $HOT,4(%esp)
    jne fail
    cmpl $0x12348001,%eax
    jne fail
    cmpl $0x11112222,%ebx
    jne fail
    pushl %eax
    movl %cr2,%eax
    cmpl $((RELOC << 28)+0x30000),%eax
    jne fail
    movl $0x030063,0x120c0
    invlpg 0x30000
    incl 0x2000
    popl %eax
    addl $4,%esp
    iret
gp_handler:
    cmpl $0,(%esp)
    jne fail
    cmpl $HOT,4(%esp)
    jne fail
    cmpl $0x12348001,%eax
    jne fail
    cmpl $0x11112222,%ebx
    jne fail
    incl 0x2004
    movl $returned,4(%esp)
    movl $0x18,8(%esp)
    addl $4,%esp
    iret
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
