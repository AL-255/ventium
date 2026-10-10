/* Ordinary paged reset; branch fallthrough loads, no saved state or forced core
 * signal. KIND: paired branch, U branch, dependent base, alternating outcome,
 * operand prefix, SIB, disp32, split-data-line, two/four-node pointer chase.
 * Relocated CS/DS aliases too.
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
    .set p,0
    .rept 24
    movl $0x11223344,(0x3000+p*4)
    .set p,p+1
    .endr
#if KIND == 8 || KIND == 9
    movl $0x3040,0x3000
#if KIND == 9
    movl $0x3080,0x3040
    movl $0x30c0,0x3080
    movl $0x3000,0x30c0
    movl $0x11223344,0x3084
    movl $0x11223344,0x30c4
#else
    movl $0x3000,0x3040
#endif
#endif
#if KIND == 7
    movl $0x11223344,0x301f
    movl $0x301b,%eax
#else
    movl $0x3000,%eax
#endif
    xorl %ebx,%ebx
    xorl %ebp,%ebp
    movl $1,%edi
    movl $16,%ecx
    /* Warm the target line through a real load, not testbench cache injection. */
    movl 4(%eax),%edx
    testl %edi,%edi
    jmp hot_u
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_u,hot_branch,hot_load,pair_v,exit_port
hot_u:
#if KIND == 1
hot_branch:
    je branch_taken
#elif KIND == 2
    addl $4,%eax
hot_branch:
    je branch_taken
#elif KIND == 3
    testl $1,%ecx
hot_branch:
    jne branch_taken
#else
    testl %edi,%edi
hot_branch:
    je branch_taken
#endif
hot_load:
#if KIND == 4
    movw 4(%eax),%dx
#elif KIND == 5
    movl 4(%eax,%ebx,1),%edx
#elif KIND == 6
    .byte 0x8b,0x90
    .long 4
#else
    movl 4(%eax),%edx
#endif
    cmpl $0x11223344,%edx
    jne fail
    incl %ebp
    jmp after_load
branch_taken:
#if KIND != 3
    jmp fail
#endif
after_load:
#if KIND == 8 || KIND == 9
    /* Real pointer reads rotate L1 lines. Two lines fit the old reuse windows;
     * four exceed them. Keep both controls: do not claim the two-line steady
     * case improves merely because the new prime path is exercised. */
    movl (%eax),%eax
#endif
    decl %ecx
    jz done
    testl %edi,%edi
    jmp hot_u
done:
#if KIND == 3
    cmpl $8,%ebp
#else
    cmpl $16,%ebp
#endif
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
