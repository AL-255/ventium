/* Cold protected-mode FNSTENV/FNSAVE fault/retry. No state injection.
 * A denied second page must not mask/reset x87 before the fault handler.
 * Partial destination bytes are intentionally NOT constrained: that is not
 * the state-precision property tested here. Both page frames have an alias.
 * HEAD=0 means the object ends exactly at the denied page (no fault).
 */
#if FULL
#if ENV16
#define WIDTH 94
#else
#define WIDTH 108
#endif
#else
#if ENV16
#define WIDTH 14
#else
#define WIDTH 28
#endif
#endif
#if HEAD == 0
#define FIRST WIDTH
#elif HEAD == 4
#define FIRST (WIDTH-1)
#else
#define FIRST HEAD
#endif
#define DEST (0x401000-FIRST)
#define ALIAS (DEST+0x100000)
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
    movw $23,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl $0x31,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm32
    .word 8
    .code32
    .section .text32,"ax"
pm32:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x90000,%esp
    .macro gate vector,target
    movl $\target,%eax
    movw %ax,0x1000+8*\vector
    movw $8,0x1002+8*\vector
    movw $0x8e00,0x1004+8*\vector
    shrl $16,%eax
    movw %ax,0x1006+8*\vector
    .endm
    gate 6,fail
    gate 7,fail
    gate 12,fail
    gate 13,fail
    gate 14,pf_handler
    gate 16,fail
    movw $0x87,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0,0x2000
    movl $0x12000,%edi
    movl $3,%eax
    movl $25,%ecx
1:  movl %eax,(%edi)
    addl $4096,%eax
    addl $4,%edi
    loop 1b
    movl $0x8f003,0x1223c
    movl $0x90003,0x12240
    movl $0x123c0,%edi
    movl $0xf0003,%eax
    movl $16,%ecx
1:  movl %eax,(%edi)
    addl $4096,%eax
    addl $4,%edi
    loop 1b
    movl $0x12003,0x11000
    movl $0x13003,0x11004
    movl $0x14003,0x13000
#if PRESENT
    movl $0x18001,0x13004
#else
    movl $0x18002,0x13004
#endif
    movl $0x14003,0x13400
    movl $0x18003,0x13404
    movl $0x11000,%eax
    movl %eax,%cr3
    movl $0x80010031,%eax
    movl %eax,%cr0
    /* Different, noncontiguous physical frames and exact object guards. */
    movl $ALIAS-4,%edi
    movl $WIDTH+8,%ecx
    movb $0xa5,%al
    rep stosb
    fninit
    movw $0x0340,0x2004
    fldcw 0x2004
    fld1
    fld1
    fadd %st(1),%st
    fnstenv 0x4000
    fldcw 0x2004
#if INJECT
    /* Directed negative fixture: emulate the forbidden early side effect. */
#if FULL
    fninit
#else
    movw $0x037f,0x2008
    fldcw 0x2008
#endif
#endif
    xorl %edi,%edi
    jmp pair_u
    .balign 32,0x90
    .global pair_u,pair_v,hot_op,hot_after
pair_u:
    movl $0x12345678,%ebx
pair_v:
    incl %edi
hot_op:
#if ENV16
    .byte 0x66
#endif
#if FULL
    .byte 0xdd,0x35
#else
    .byte 0xd9,0x35
#endif
    .long DEST
hot_after:
    cmpl $1,%edi
    jne fail
#if HEAD
    cmpl $1,0x2000
#else
    cmpl $0,0x2000
#endif
    jne fail
    cmpl $0xa5a5a5a5,ALIAS-4
    jne fail
    cmpl $0xa5a5a5a5,ALIAS+WIDTH
    jne fail
    cmpw $0x0340,ALIAS
    jne fail
#if ENV16
    .set SWOFF,2
    .set TWOFF,4
    .set IPOFF,6
    .set CSOFF,8
    .set DPOFF,10
    .set DSOFF,12
    .set REGOFF,14
#else
    .set SWOFF,4
    .set TWOFF,8
    .set IPOFF,12
    .set CSOFF,16
    .set DPOFF,20
    .set DSOFF,24
    .set REGOFF,28
#endif
    movw 0x4004,%ax
    cmpw %ax,ALIAS+SWOFF
    jne fail
    movw 0x4008,%ax
    cmpw %ax,ALIAS+TWOFF
    jne fail
#if ENV16
    movw 0x400c,%ax
    cmpw %ax,ALIAS+IPOFF
    jne fail
    movw 0x4014,%ax
    cmpw %ax,ALIAS+DPOFF
#else
    movl 0x400c,%eax
    cmpl %eax,ALIAS+IPOFF
    jne fail
    movl 0x4014,%eax
    cmpl %eax,ALIAS+DPOFF
#endif
    jne fail
    movw 0x4010,%ax
    cmpw %ax,ALIAS+CSOFF
    jne fail
    movw 0x4018,%ax
    cmpw %ax,ALIAS+DSOFF
    jne fail
#if FULL
    /* ST0=2, ST1=1 must survive the rejected FNSAVE and its retry. */
    cmpl $0,ALIAS+REGOFF
    jne fail
    cmpl $0x80000000,ALIAS+REGOFF+4
    jne fail
    cmpw $0x4000,ALIAS+REGOFF+8
    jne fail
    cmpl $0,ALIAS+REGOFF+10
    jne fail
    cmpl $0x80000000,ALIAS+REGOFF+14
    jne fail
    cmpw $0x3fff,ALIAS+REGOFF+18
    jne fail
    fnstcw 0x2010
    cmpw $0x037f,0x2010
    jne fail
    fnstsw %ax
    testw %ax,%ax
    jnz fail
#endif
    movl $0x42,%eax
    jmp exit
    .global pf_handler
pf_handler:
    pushal
    cmpl $2+PRESENT,32(%esp)
    jne fail
    cmpl $hot_op,36(%esp)
    jne fail
    movl %cr2,%eax
    cmpl $0x401000,%eax
    jne fail
    incl 0x2000
    cmpl $1,0x2000
    jne fail
    fnstenv 0x6000
    /* Compare defined header fields only; reserved bytes/FOP are not graded.
     * Capture precedes FLDCW, so an early mask/reset cannot be repaired away. */
    .irp off,0,4,8,16,24
    movw 0x4000+\off,%ax
    cmpw %ax,0x6000+\off
    jne fail
    .endr
    .irp off,12,20
    movl 0x4000+\off,%eax
    cmpl %eax,0x6000+\off
    jne fail
    .endr
    fldcw 0x2004
    movl $0x18003,0x13004
    invlpg 0x401000
    popal
    addl $4,%esp
    iretl
    .global fail
fail:
    movl $0x43,%eax
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    jmp exit
    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
