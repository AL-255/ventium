/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
/*
 * pfetchpc: precise restart ownership for user instruction-fetch #PFs.
 *
 * Case A is a positive control: an outer IRETD enters 0x400000 with its FIRST
 * opcode byte on a nonpresent user page. This may fault in S_PIPE already.
 *
 * Case B targets the slow-fetch handoff: C7 05 disp32 imm32 at 0x401ffa is
 * ten bytes long. Its six opcode/address bytes occupy 0x401ffa..0x401fff;
 * ALL FOUR immediate bytes occupy the nonpresent page at 0x402000. They are
 * architecturally necessary, not incidental 16-byte prefetch. The handler
 * must save EIP=0x401ffa under CS=0x1b, NEVER a stale kernel IRET PC.
 *
 * Both handlers check error=4 (NP, read, user; P5 has no fetch-error bit),
 * exact saved EIP/CS/CR2/old SS:ESP, map only the missing page, flush CR3,
 * and IRET WITHOUT changing saved EIP or CS. Case B also checks the memory
 * destination and following-instruction counter are unchanged at the fault.
 * After retry, the store result and counter=1 prove correct resumed flow;
 * this is not a claim about counting physical bus writes of an idempotent MOV.
 *
 * BIOS physical F8000 maps to user linear400000; F9000 maps to401000;
 * FA000 maps to402000. Kernel code is identity-mapped supervisor-only.
 */
    .global user_first_eip, user_cross_eip, first_cr2, cross_cr2
    .set user_first_eip, 0x00400000
    .set user_cross_eip, 0x00401ffa
    .set first_cr2, 0x00400000
    .set cross_cr2, 0x00402000

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp
    movl $0, 0x0500
    movl $0, 0x0504
    movl $0x0000ffff, 0x0508           /* code0, selector08 */
    movl $0x00cf9a00, 0x050c
    movl $0x0000ffff, 0x0510           /* data0, selector10 */
    movl $0x00cf9200, 0x0514
    movl $0x0000ffff, 0x0518           /* code3, selector1b */
    movl $0x00cffa00, 0x051c
    movl $0x0000ffff, 0x0520           /* data3, selector23 */
    movl $0x00cff200, 0x0524
    movl $0x30000067, 0x0528           /* TSS at3000, limit67 */
    movl $0x00008900, 0x052c
    movw $0x002f, 0x0480
    movl $0x00000500, 0x0482
    lgdt 0x0480
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long pm_entry
    .word 0x08

    .code32
    .section .text32, "ax"
pm_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs
    movl $0x00090000, %esp

    /* Explicitly initialize markers and the104-byte TSS. */
    movl $0x2000, %edi
    xorl %eax, %eax
    movl $17, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    loop 1b
    movl $0x3000, %edi
    movl $26, %ecx
2:  movl %eax, (%edi)
    addl $4, %edi
    loop 2b
    movl $0x00088000, 0x3004
    movl $0x00000010, 0x3008
    movw $0x0068, 0x3066
    movw $0x0028, %ax
    ltr %ax

    /* Three ordinary exception gates and the user phase/exit INT40 gate. */
    movl $pf_handler, %ebx
    movl $0x1070, %edi
    movl $0x8e00, %edx
    call install_gate
    movl $unexpected_fault, %ebx
    movl $0x1068, %edi                /* #GP */
    call install_gate
    movl $0x1030, %edi                /* #UD */
    call install_gate
    movl $phase_controller, %ebx
    movl $0x1200, %edi
    movl $0xee00, %edx
    call install_gate
    movw $0x07ff, 0x0490
    movl $0x00001000, 0x0492
    lidt 0x0490

    /* PD11000 -> PT0/1 at12000/13000. Zero entries remain unreferenced. */
    movl $0x12000, %edi
    movl $0x00000003, %eax
    movl $20, %ecx                  /* low structures and page tables */
3:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 3b
    movl $0x00004007, 0x12010       /* user destination4000: P|RW|US */
    movl $0x0007f007, 0x121fc       /* user stack below80000 */
    movl $0x00087003, 0x1221c       /* ring0 TSS stack below88000 */
    movl $0x0008f003, 0x1223c       /* ring0 bootstrap stack below90000 */
    movl $0x123c0, %edi
    movl $0x000f0003, %eax
    movl $16, %ecx                 /* identity supervisor BIOS pages */
4:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 4b
    movl $0x000f8006, 0x13000      /*400000 -> F8000, user RW, NP */
    movl $0x000f9007, 0x13004      /*401000 -> F9000, user RW, present */
    movl $0x000fa006, 0x13008      /*402000 -> FA000, user RW, NP */
    movl $0x00012007, 0x11000      /* both PDEs have US|RW|P */
    movl $0x00013007, 0x11004
    movl $0x5eedbeef, 0x4000
    movl $0, 0x4004
    movl $0x00011000, %eax
    movl %eax, %cr3
    movl %cr0, %eax
    orl $0x80010000, %eax
    movl %eax, %cr0

    /* A CPL0-only DS would be nulled by outer IRET. User C7 cannot first
     * execute a setup instruction, so install the valid flat user DS NOW. */
    movw $0x23, %ax
    movw %ax, %ds
    movw %ax, %es
    movl $0xdeadc0de, %eax
    pushl $0x23
    pushl $0x00080000
    pushl $0x00000002               /* IF=0: no unrelated PIC deliveries */
    pushl $0x1b
    pushl $user_first_eip
    .global first_enter_iret
first_enter_iret:
    iret

install_gate:
    movl %ebx, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, (%edi)
    movl %ebx, %eax
    andl $0xffff0000, %eax
    orl %edx, %eax
    movl %eax, 4(%edi)
    ret

    /* Saved #PF frame: error,EIP,CS,EFLAGS,oldESP,oldSS. */
    .macro frame_dword name, offset, marker, reg, expected
    .global \name
\name:
    movl \offset(%esp), \reg
    movl \reg, \marker
    cmpl $\expected, \reg
    jne fail_frame
    .endm
    .macro frame_selector name, offset, marker, reg, expected
    .global \name
\name:
    movzwl \offset(%esp), \reg
    movl \reg, \marker
    cmpl $\expected, \reg
    jne fail_frame
    .endm

    .global pf_handler
pf_handler:
    incl 0x2000
    cmpl $0, 0x2004
    jne cross_fault
    cmpl $1, 0x2000
    jne fail_count
    frame_dword first_capture_error, 0, 0x2008, %ebx, 4
    frame_dword first_capture_eip, 4, 0x200c, %esi, user_first_eip
    frame_selector first_capture_cs, 8, 0x2010, %ecx, 0x1b
    .global first_capture_cr2
first_capture_cr2:
    movl %cr2, %edx
    movl %edx, 0x2014
    cmpl $first_cr2, %edx
    jne fail_frame
    frame_dword first_capture_esp, 16, 0x2018, %edi, 0x00080000
    frame_selector first_capture_ss, 20, 0x201c, %ebp, 0x23
    movl $0x000f8007, 0x13000
    movl %cr3, %edx
    movl %edx, %cr3
    addl $4, %esp
    .global first_fault_iret
first_fault_iret:
    iret                            /* original saved EIP/CS are untouched */

cross_fault:
    cmpl $1, 0x2004
    jne fail_count
    cmpl $2, 0x2000
    jne fail_count
    frame_dword cross_capture_error, 0, 0x2020, %ebx, 4
    frame_dword cross_capture_eip, 4, 0x2024, %esi, user_cross_eip
    frame_selector cross_capture_cs, 8, 0x2028, %ecx, 0x1b
    .global cross_capture_cr2
cross_capture_cr2:
    movl %cr2, %edx
    movl %edx, 0x202c
    cmpl $cross_cr2, %edx
    jne fail_frame
    frame_dword cross_capture_esp, 16, 0x2030, %edi, 0x00080000
    frame_selector cross_capture_ss, 20, 0x2034, %ebp, 0x23
    movl %eax, 0x2038
    cmpl $0xdeadc0de, %eax
    jne fail_effect
    .global cross_capture_seed
cross_capture_seed:
    movl 0x4000, %ebx
    cmpl $0x5eedbeef, %ebx
    jne fail_effect
    .global cross_capture_counter
cross_capture_counter:
    movl 0x4004, %ecx
    testl %ecx, %ecx
    jnz fail_effect
    movl $0x000fa007, 0x13008
    movl %cr3, %edx
    movl %edx, %cr3
    addl $4, %esp
    .global cross_fault_iret
cross_fault_iret:
    iret                            /* do not skip or patch the faulting MOV */

    .global phase_controller
phase_controller:
    cmpl $0, 0x2004
    jne final_grade
    cmpl $0x13579bdf, %eax
    jne fail_signature
    cmpl $1, 0x2000
    jne fail_count
    movl $1, 0x203c
    movl $1, 0x2004
    movl $0x00090000, %esp
    movl $0xdeadc0de, %eax
    pushl $0x23
    pushl $0x00080000
    pushl $0x00000002
    pushl $0x1b
    pushl $user_cross_eip
    .global cross_enter_iret
cross_enter_iret:
    iret

final_grade:
    cmpl $1, 0x2004
    jne fail_count
    cmpl $2, 0x2000
    jne fail_count
    cmpl $0x2468ace0, 0x4000
    jne fail_effect
    cmpl $1, 0x4004
    jne fail_effect
    orl $2, 0x203c
    movl 0x2000, %ecx
    movl 0x200c, %esi
    movl 0x2024, %edi
    movl 0x202c, %ebx
    movl 0x203c, %ebp
    movl $0xc0de0042, %eax
    jmp do_exit
    .global fail_count, fail_frame, fail_effect, fail_signature, unexpected_fault
fail_count:
    movb $0x43, %al
    jmp do_exit
fail_frame:
    movb $0x44, %al
    jmp do_exit
fail_effect:
    movb $0x45, %al
    jmp do_exit
fail_signature:
    movb $0x46, %al
    jmp do_exit
unexpected_fault:
    movb $0x47, %al
do_exit:
    movl $0xc0de0000, %edx
    .global set_exit_port, do_out
set_exit_port:
    movw $0xf4, %dx
do_out:
    outb %al, %dx
5:  hlt
    jmp 5b

    .section .user_first, "ax"
    .global user_first, user_first_end, user_first_int
user_first:
    movl $0x13579bdf, %eax
user_first_end:
user_first_int:
    int $0x40
6:  jmp 6b

    .section .user_cross, "ax"
    .global user_cross, user_cross_end, user_cross_counter, user_cross_int
user_cross:
    .byte 0xc7, 0x05
    .long 0x00004000
    .long 0x2468ace0
user_cross_end:
user_cross_counter:
    incl 0x4004
user_cross_int:
    int $0x40
7:  jmp 7b

    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
