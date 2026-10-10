/* Cold paged FP payload ownership: direct/queued/memory commands mixed with
 * independent integer and memory work. Full x87 state is compared, not masked.
 * Flat/relocated clients, all instruction-line offsets, no saved state.
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
    movl $0x3f800000,0x3000
    movl $0,0x3030
    movl $0x3ff00000,0x3034
    movw $0x037f,0x3070
    fld1
    fld1
    movl $0x3000,%eax
    movl $0x3040,%edi
    movl $0x573cbda1,%esi
    movl $7,%ebx
    xorl %ebp,%ebp
    movl $16,%ecx
    jmp hot_u
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_u,hot_load,pair_v,exit_port
hot_u:
hot_load:
    fadd %st(1),%st(0)
#if KIND == 0
    fxch %st(1)
    fadd %st(1),%st(0)
    fxch %st(1)
    fld1
    faddp %st(0),%st(1)
#elif KIND == 1
    flds 0x3000
    faddp %st(0),%st(1)
    fldl 0x3030
    fmulp %st(0),%st(1)
#elif KIND == 2
    fld1
    fsqrt
    movl %esi,8(%edi)
    movl 8(%edi),%edx
    addl %edx,%ebx
    fstp %st(0)
#elif KIND == 3
    fdiv %st(1),%st(0)
    fxch %st(1)
    movl %esi,16(%edi)
    movl 16(%edi),%edx
    fxch %st(1)
    flds 0x3000
    faddp %st(0),%st(1)
#elif KIND == 4
    fmul %st(1),%st(0)
    fadd %st(1),%st(0)
    fchs
    fabs
    fnstsw 0x3060
#elif KIND == 5
    fldcw 0x3070
    fnstcw 0x3064
    fnstsw 0x3068
    fwait
    fld1
    fstp %st(0)
#endif
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
