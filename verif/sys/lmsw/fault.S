/* LMSW precise-load cases, cold reset, no injected architectural state.
 * 0: successful noncontiguous page split; 1/2: first/second page absent,
 * check pre-fault CR0 then repair and retry; 3: null DS; 4: read-only DS
 * (legal read); 5: DS limit crossing; 6/7: illegal LOCK memory/register.
 * QEMU disagreements are failures, not new masks or accepted controls.
 */
#if CASE < 0 || CASE > 7
#error Invalid LMSW case
#endif
    .set INITIAL, 0x1001b
#if CASE <= 2
    .set BEFORE, INITIAL | 0x80000000
    .set ALIAS, 0x500000
#else
    .set BEFORE, INITIAL
    .set ALIAS, 0x400000
#endif
    .set AFTER, (BEFORE & ~14) | 14
    .section .text16,"ax"
    .code16
    .global _start16
_start16:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x9000,%esp
    movl $0,0x500
    movl $0,0x504
    movl $0x0000ffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0x0000ffff,0x510
    movl $0x00cf9200,0x514
#if CASE == 5
    movl $0x00000fff,0x518
#else
    movl $0x0000ffff,0x518
#endif
#if CASE == 4
    movl $0x00409040,0x51c
#else
    movl $0x00409240,0x51c
#endif
    movw $31,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl $INITIAL,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm_entry
    .word 8
    .section .text32,"ax"
    .code32
pm_entry:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    .macro gate vector, target
    movl $\target,%eax
    andl $0xffff,%eax
    orl $0x80000,%eax
    movl %eax,0x1000+8*\vector
    movl $\target,%eax
    andl $0xffff0000,%eax
    orl $0x8e00,%eax
    movl %eax,0x1004+8*\vector
    .endm
    gate 6, ud_handler
    gate 13, gp_handler
    gate 14, pf_handler
    movw $0x77,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0,0x800
#if CASE <= 2
    movl $0x0ea5a5a5,0x180ffc
    movl $0xa5a5a5a6,0x1a0000
    movl $0x12003,0x11000
    movl $0x13003,0x11004
    .irp page,0,1,8,0x11,0x12,0x13,0xf0,0xf1
    movl $(\page*4096+3),0x12000+\page*4
    .endr
#if CASE == 1
    movl $0x180002,0x13000
#else
    movl $0x180001,0x13000
#endif
#if CASE == 2
    movl $0x1a0002,0x13004
#else
    movl $0x1a0001,0x13004
#endif
    movl $0x180003,0x13400
    movl $0x1a0003,0x13404
    movl $0x11000,%eax
    movl %eax,%cr3
    movl $BEFORE,%eax
    movl %eax,%cr0
#else
    movl $0x0ea5a5a5,0x400ffc
    movl $0xa5a5a5a6,0x401000
#endif
    movl $0xaabbccdd,%eax
    movl %eax,%cr2
#if CASE == 3
    xorw %ax,%ax
#else
    movw $24,%ax
#endif
    movw %ax,%ds
    movl $0xbabea60e,%eax
    movl $0x11223344,%ebx
    movl $0x22334455,%ecx
    movl $0x33445566,%edx
    movl $0x44556677,%ebp
    movl $0x55667788,%esi
    movl $0x66778899,%edi
    pushl $0x8d7
    popfl
    .global lmsw_probe, lmsw_after
lmsw_probe:
#if CASE >= 6
    .byte 0xf0
#endif
#if !OP32
    .byte 0x66
#endif
#if !ADDR32
    .byte 0x67
#endif
#if CASE == 7
    .byte 0x0f,0x01,0xf0
#elif ADDR32
    .byte 0x0f,0x01,0x35
    .long 0xfff
#else
    .byte 0x0f,0x01,0x36
    .word 0xfff
#endif
lmsw_after:
#if CASE <= 2 || CASE == 4
    pushfl
    pushal
    call check_registers
    movl %ss:32(%esp),%eax
    andl $0xfd7,%eax
    cmpl $0x8d7,%eax
    jne fail
    movl %cr0,%eax
    cmpl $AFTER,%eax
    jne fail
#if CASE == 1 || CASE == 2
    cmpl $1,%es:0x800
#else
    cmpl $0,%es:0x800
#endif
    jne fail
    jmp check_memory
#else
    jmp fail
#endif
ud_handler:
#if CASE >= 6
    pushl $0
    jmp fault_handler
#else
    jmp fail
#endif
gp_handler:
#if CASE == 3 || CASE == 5
    jmp fault_handler
#else
    jmp fail
#endif
pf_handler:
#if CASE == 1 || CASE == 2
    jmp fault_handler
#else
    jmp fail
#endif
fault_handler:
    pushal
    call check_registers
    movl %cr0,%eax
    cmpl $BEFORE,%eax
    jne fail
    cmpl $0,32(%esp)
    jne fail
    cmpl $lmsw_probe,36(%esp)
    jne fail
    cmpl $8,40(%esp)
    jne fail
    movl 44(%esp),%eax
    andl $0xfd7,%eax
    cmpl $0x8d7,%eax
    jne fail
    movl %cr2,%eax
#if CASE == 1
    cmpl $0x400fff,%eax
#elif CASE == 2
    cmpl $0x401000,%eax
#else
    cmpl $0xaabbccdd,%eax
#endif
    jne fail
    cmpl $0x0ea5a5a5,%es:ALIAS+0xffc
    jne fail
    cmpl $0xa5a5a5a6,%es:ALIAS+0x1000
    jne fail
    incl %es:0x800
    cmpl $1,%es:0x800
    jne fail
#if CASE == 1 || CASE == 2
    movl $0x180001,%es:0x13000
    movl $0x1a0001,%es:0x13004
    invlpg %es:0x400fff
    invlpg %es:0x401000
    popal
    addl $4,%esp
    iret
#else
    jmp check_memory
#endif
check_registers:
    cmpl $0xbabea60e,%eax
    jne fail
    cmpl $0x11223344,%ebx
    jne fail
    cmpl $0x22334455,%ecx
    jne fail
    cmpl $0x33445566,%edx
    jne fail
    cmpl $0x44556677,%ebp
    jne fail
    cmpl $0x55667788,%esi
    jne fail
    cmpl $0x66778899,%edi
    jne fail
    ret
check_memory:
    cmpl $0x0ea5a5a5,%es:ALIAS+0xffc
    jne fail
    cmpl $0xa5a5a5a6,%es:ALIAS+0x1000
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
