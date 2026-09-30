/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Scalar I/O permission checking in V86, independent of IOPL.
 * No paging, string I/O, hardware IRQ, guest patch or save-state dependency.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 15
#error CASE must be 1..15
#endif
#if CASE == 14
#define CLIENT_FLAGS 0x00003002
#define CLIENT_CS 0x1B
#define CLIENT_SS 0x23
#define CLIENT_SP 0x00088000
#define IO_PC io_fault
#define END_PC finish_hlt
#define RESUME_PC after_io
#elif CASE == 15
#define CLIENT_FLAGS 0x00020002
#define CLIENT_CS 0x1000
#define CLIENT_SS 0x2000
#define CLIENT_SP 0x0000F000
#define IO_PC (io_fault-v86_entry)
#define END_PC (finish_hlt-v86_entry)
#define RESUME_PC (after_io-v86_entry)
#else
#define CLIENT_FLAGS 0x00023002
#define CLIENT_CS 0x1000
#define CLIENT_SS 0x2000
#define CLIENT_SP 0x0000F000
#define IO_PC (io_fault-v86_entry)
#define END_PC (finish_hlt-v86_entry)
#define RESUME_PC (after_io-v86_entry)
#endif
#if CASE == 3 || CASE == 4 || CASE == 9 || CASE == 10
#define CLIENT_DX 0xAABB0087
#elif CASE == 5 || CASE == 6 || CASE == 11 || CASE == 12
#define CLIENT_DX 0xAABB0085
#else
#define CLIENT_DX 0xAABB0080
#endif

    .macro client_regs
    movl $0xA58391B2,%eax
    movl $0x34560009,%ecx
    movl $CLIENT_DX,%edx
    movl $0x11223344,%ebx
    movl $0x88776655,%ebp
    movl $0x44332211,%esi
    movl $0x55667788,%edi
    .endm

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
    movl $0,0x0500
    movl $0,0x0504
    movl $0x0000FFFF,0x0508
    movl $0x00CF9A00,0x050C
    movl $0x0000FFFF,0x0510
    movl $0x00CF9200,0x0514
    movl $0x0000FFFF,0x0518
    movl $0x00CFFA00,0x051C
    movl $0x0000FFFF,0x0520
    movl $0x00CFF200,0x0524
    movl $0x30000083,0x0528
    movl $0x00008900,0x052C
    movw $0x002F,0x0480
    movl $0x00000500,0x0482
    lgdt 0x0480
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xEA
    .long pm_entry
    .word 0x08

    .code32
    .section .text32,"ax"
pm_entry:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x90000,%esp
    movl $0x3000,%edi
    xorl %eax,%eax
    movl $26,%ecx
1:  movl %eax,(%edi)
    addl $4,%edi
    loop 1b
    movl $0x80000,0x3004
    movl $0x10,0x3008
    movw $0x68,0x3066
    movl $0,0x3078
    movb $0xFF,0x3083              /* bitmap terminator inside TSS limit */
#if CASE == 3 || CASE == 4 || CASE == 5 || CASE == 6 || CASE == 9 || CASE == 10 || CASE == 11 || CASE == 12
    /* First port(s) allowed; only trailing port 0x88 is denied. */
    movb $1,0x3079
#elif CASE != 13
    movb $1,0x3078
#endif
    movw $0x28,%ax
    ltr %ax
    movl $gp_handler,%eax
    movl %eax,%edx
    andl $0xFFFF,%eax
    orl $0x00080000,%eax
    movl %eax,0x1068
    andl $0xFFFF0000,%edx
    orl $0x00008E00,%edx
    movl %edx,0x106C
    movw $0x07FF,0x0490
    movl $0x1000,0x0492
    lidt 0x0490
    movl $0,0x20000                 /* target #GP count */
    movl $0,0x20004                 /* self-check errors */
    movl $CASE,0x20008
#if CASE == 14
    pushl $0x23
    pushl $CLIENT_SP
    pushl $CLIENT_FLAGS
    pushl $0x1B
    pushl $pm_client
    iret
pm_client:
    movw $0x23,%ax
    movw %ax,%ds
    movw %ax,%es
    client_regs
    .global io_fault,after_io,finish_hlt
io_fault:
    outb %al,%dx
after_io:
finish_hlt:
    hlt
    jmp finish_hlt
#else
    movl $_v86_lma,%esi
    movl $0x10000,%edi
    movl $_v86_blob_len,%ecx
    rep movsb
    pushl $0x2000                  /* GS */
    pushl $0x2000                  /* FS */
    pushl $0x2000                  /* DS */
    pushl $0x2000                  /* ES */
    pushl $0x2000                  /* SS */
    pushl $CLIENT_SP
    pushl $CLIENT_FLAGS
    pushl $0x1000
    pushl $0
    iret
#endif

    .global gp_handler
gp_handler:
    pushal
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    /* Original #GP frame starts at +32 after PUSHAD. The common prefix is
     * err,EIP,CS,EFLAGS,ESP,SS; V86 additionally saves ES/DS/FS/GS. */
    cmpl $0,32(%esp)
    jne bad_frame
    cmpl $CLIENT_CS,40(%esp)
    jne bad_frame
    cmpl $CLIENT_SS,52(%esp)
    jne bad_frame
    cmpl $CLIENT_SP,48(%esp)
    jne bad_frame
    movl 44(%esp),%eax
    andl $0x00023ED7,%eax          /* ignore RF/reserved bits only */
    cmpl $CLIENT_FLAGS,%eax
    jne bad_frame
    cmpl $0xA58391B2,28(%esp)
    jne bad_frame
    cmpl $0x34560009,24(%esp)
    jne bad_frame
    cmpl $CLIENT_DX,20(%esp)
    jne bad_frame
    cmpl $0x11223344,16(%esp)
    jne bad_frame
    cmpl $0x88776655,8(%esp)
    jne bad_frame
    cmpl $0x44332211,4(%esp)
    jne bad_frame
    cmpl $0x55667788,0(%esp)
    jne bad_frame
#if CASE != 14
    cmpl $0x2000,56(%esp)
    jne bad_frame
    cmpl $0x2000,60(%esp)
    jne bad_frame
    cmpl $0x2000,64(%esp)
    jne bad_frame
    cmpl $0x2000,68(%esp)
    jne bad_frame
#endif
    jmp classify
bad_frame:
    incl 0x20004
classify:
    cmpl $IO_PC,36(%esp)
    je target_fault
    cmpl $END_PC,36(%esp)
    je finish
    incl 0x20004
    jmp finish
target_fault:
    incl 0x20000
    movl $RESUME_PC,36(%esp)
    popal
    addl $4,%esp
    iret
finish:
#if CASE == 13 || CASE == 14
    cmpl $0,0x20000
#else
    cmpl $1,0x20000
#endif
    je 1f
    incl 0x20004
1:  cmpl $0,0x20004
    jne failure
    movl 0x20000,%ecx
    movl 0x20004,%edi
    movl $CASE,%ebx
    movl $0xC0DEC0DE,%esi
    movl $0x42,%eax
    movw $0xF4,%dx
    outb %al,%dx
failure:
    movl 0x20000,%ecx
    movl 0x20004,%edi
    movl $CASE,%ebx
    movl $0x43,%eax
    movw $0xF4,%dx
    outb %al,%dx
    hlt

    .code16
    .section .text_v86,"ax"
    .global v86_entry
v86_entry:
#if CASE != 14
    client_regs
    .global io_fault,after_io,finish_hlt
io_fault:
#if CASE == 1 || CASE == 13 || CASE == 15
    outb %al,%dx
#elif CASE == 2
    inb %dx,%al
#elif CASE == 3
    outw %ax,%dx
#elif CASE == 4
    inw %dx,%ax
#elif CASE == 5
    outl %eax,%dx
#elif CASE == 6
    inl %dx,%eax
#elif CASE == 7
    outb %al,$0x80
#elif CASE == 8
    inb $0x80,%al
#elif CASE == 9
    outw %ax,$0x87
#elif CASE == 10
    inw $0x87,%ax
#elif CASE == 11
    outl %eax,$0x85
#elif CASE == 12
    inl $0x85,%eax
#endif
after_io:
finish_hlt:
    hlt
    jmp finish_hlt
#else
    nop
#endif
    .section .reset,"ax"
    .global _reset
_reset:
    ljmp $0xF000,$_start16_off
