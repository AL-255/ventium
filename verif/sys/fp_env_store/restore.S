/* Cold cross-size pointer-image conversion; MODE 0=PM0, 1=real, 2=V86/IOPL3.
 * The image is constructed from Intel figures 6-6..6-9, not from an old
 * possibly broken FNSTENV. Reserved fields/FOP are outside this pointer test.
 */
#if IN16
#define PM_IP 0x1234
#define PM_DP 0xabcd
#define REAL_IP_HIGH 0xd000
#define REAL_DP_HIGH 0x6000
#else
#define PM_IP 0xabcd1234
#define PM_DP 0x7656abcd
#define REAL_IP_HIGH 0x0abcd000
#define REAL_DP_HIGH 0x07656000
#endif
    .set src, 0x4000+SHIFT
    .set dst, 0x6000+SHIFT
    .section .text16,"ax"
    .code16
    .global _start16,fail16
_start16:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%ss
    movw %ax,%es
    movl $0x9000,%esp
    movw $fail16_off,6*4
    movw $0xf000,6*4+2
    movw $fail16_off,7*4
    movw $0xf000,7*4+2
    movw $fail16_off,13*4
    movw $0xf000,13*4+2
#if MODE == 1
    movl $0x60000010,%eax
    movl %eax,%cr0
    .byte 0xea
    .word user_entry_off
    .word 0xf000
#else
    movl $0,0x500
    movl $0,0x504
    movl $0x0000ffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0x0000ffff,0x510
    movl $0x00cf9200,0x514
    movl $0x30000088,0x518
    movl $0x00008900,0x51c
    movw $0x1f,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl $0x60000011,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm_entry
    .word 8
#endif
fail16:
    movb $0x43,%al
    outb %al,$0xf4
    hlt
    jmp fail16
    .section .text32,"ax"
    .code32
pm_entry:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    .macro gate vector
    movl $fail_pm,%eax
    andl $0xffff,%eax
    orl $0x80000,%eax
    movl %eax,0x1000+8*\vector
    movl $fail_pm,%eax
    andl $0xffff0000,%eax
    orl $0x8e00,%eax
    movl %eax,0x1004+8*\vector
    .endm
    gate 6
    gate 7
    gate 12
    gate 13
    gate 14
    gate 16
    movw $0x87,0x490
    movl $0x1000,0x492
    lidt 0x490
#if MODE == 2
    movl $0x3000,%edi
    movl $26,%ecx
    xorl %eax,%eax
    rep stosl
    movl $0x16000,0x3004
    movl $16,0x3008
    movw $0x68,0x3066
    /* V86 scalar I/O consults the TSS bitmap. Permit only the debug-exit
     * port, including a present deny-all sentinel; do not bypass the check. */
    movl $0x3068,%edi
    movl $8,%ecx
    movl $0xffffffff,%eax
    rep stosl
    movb $0xef,0x3086
    movw $0x18,%ax
    ltr %ax
    pushl $0
    pushl $0
    pushl $0
    pushl $0
    pushl $0
    pushl $0x9000
    pushl $0x23002
    pushl $0xf000
    pushl $user_entry_off
    iret
#else
    jmp user_entry
#endif
fail_pm:
    movb $0x43,%al
    outb %al,$0xf4
    hlt
    jmp fail_pm
    .section .textuser,"ax"
#if MODE == 0
    .code32
#else
    .code16
#endif
    .global user_entry
user_entry:
    fninit
    fld1
    /* Clear the entire input, including all eight register slots. */
    movl $src,%edi
    movl $27,%ecx
    xorl %eax,%eax
    rep stosl
    movw $0x037f,src
#if IN16
    movw $0xffff,src+4
    movw $0x1234,src+6
    movw $0xabcd,src+10
#if MODE == 0
    movw $0x3217,src+8
    movw $0x4563,src+12
#else
    movw $0xd000,src+8
    movw $0x6000,src+12
#endif
#else
    movw $0xffff,src+8
#if MODE == 0
    movl $0xabcd1234,src+12
    movl $0x3217,src+16
    movl $0x7656abcd,src+20
    movl $0x4563,src+24
#else
    movl $0x1234,src+12
    movl $0x0abcd000,src+16
    movl $0xabcd,src+20
    movl $0x07656000,src+24
#endif
#endif
#if IN16 == (MODE == 0)
    .byte 0x66
#endif
#if FULL
    .byte 0xdd
#else
    .byte 0xd9
#endif
#if MODE == 0
    .byte 0x25
    .long src
#else
    .byte 0x26
    .word src
#endif
#if OUT16 == (MODE == 0)
    .byte 0x66
#endif
#if SAVE
    .byte 0xdd
#else
    .byte 0xd9
#endif
#if MODE == 0
    .byte 0x35
    .long dst
#else
    .byte 0x36
    .word dst
#endif
    cmpw $0x037f,dst
    jne fail
#if OUT16
    cmpw $0,dst+2
    jne fail
    cmpw $0xffff,dst+4
    jne fail
    cmpw $0x1234,dst+6
    jne fail
    cmpw $0xabcd,dst+10
    jne fail
#if MODE == 0
    cmpw $0x3217,dst+8
    jne fail
    cmpw $0x4563,dst+12
#else
    movw dst+8,%ax
    andw $0xf000,%ax
    cmpw $0xd000,%ax
    jne fail
    movw dst+12,%ax
    andw $0xf000,%ax
    cmpw $0x6000,%ax
#endif
#else
    cmpw $0,dst+4
    jne fail
    cmpw $0xffff,dst+8
    jne fail
#if MODE == 0
    cmpl $PM_IP,dst+12
    jne fail
    cmpw $0x3217,dst+16
    jne fail
    cmpl $PM_DP,dst+20
    jne fail
    cmpw $0x4563,dst+24
#else
    cmpw $0x1234,dst+12
    jne fail
    cmpw $0xabcd,dst+20
    jne fail
    movl dst+16,%eax
    andl $0x0ffff000,%eax
    cmpl $REAL_IP_HIGH,%eax
    jne fail
    movl dst+24,%eax
    andl $0x0ffff000,%eax
    cmpl $REAL_DP_HIGH,%eax
#endif
#endif
    jne fail
    movb $0x42,%al
    jmp finish
fail:
    movb $0x43,%al
finish:
    outb %al,$0xf4
    hlt
    jmp finish
    .section .reset,"ax"
    .code16
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11,1,0x90
