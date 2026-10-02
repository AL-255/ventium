/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
/* Twenty-two independent fetch-boundary BIOSes. CASE is selected at assembly.
 * No saved frame is edited. Valid #PF cases map only the missing code page
 * and IRET the unchanged original instruction. The intentionally overlong
 * prefix cases end in the checked #GP handler rather than skipping the #GP.
 */
#ifndef CASE
#error Select CASE=1..22 through the Makefile
#endif
#if CASE == 1
#define ENTRY 0x00401ffa
#define PHYSICAL 0x000f9ffa
#define PF_COUNT 0
#define GP_COUNT 0
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 1
#define FINAL_EIP 0x00401fff
#define FINAL_CR2 0
#elif CASE == 2
#define ENTRY 0x00401fff
#define PHYSICAL 0x000f9fff
#define PF_EIP 0x00402000
#define PF_COUNT 1
#define GP_COUNT 0
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 1
#define FINAL_EIP PF_EIP
#define FINAL_CR2 0x00402000
#elif CASE == 3
#define ENTRY 0x00401ffc
#define PHYSICAL 0x000f9ffc
#define PF_EIP ENTRY
#define PF_COUNT 1
#define GP_COUNT 0
#define FINAL_EAX 0x2468ace0
#define FINAL_COUNTER 1
#define FINAL_EIP ENTRY
#define FINAL_CR2 0x00402000
#elif CASE == 4
#define ENTRY 0x00401fff
#define PHYSICAL 0x000f9fff
#define PF_EIP ENTRY
#define PF_COUNT 1
#define GP_COUNT 0
#define FINAL_EAX 0x5eedbeef
#define FINAL_COUNTER 1
#define FINAL_EIP ENTRY
#define FINAL_CR2 0x00402000
#elif CASE == 5
#define ENTRY 0x00401ffe
#define PHYSICAL 0x000f9ffe
#define PF_EIP ENTRY
#define PF_COUNT 1
#define GP_COUNT 0
#define FINAL_EAX 0x5eedbeef
#define FINAL_COUNTER 1
#define FINAL_EIP ENTRY
#define FINAL_CR2 0x00402000
#elif CASE == 6 || CASE == 7
#define ENTRY 0x00401ff1
#define PHYSICAL 0x000f9ff1
#define PF_EIP ENTRY
#if CASE == 6
#define PF_COUNT 1
#define FINAL_CR2 0x00402000
#else
#define PF_COUNT 0
#define FINAL_CR2 0
#endif
#define GP_COUNT 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 0
#define FINAL_EIP ENTRY
#elif CASE == 8
#define ENTRY 0x00401ff0
#define PHYSICAL 0x000f9ff0
#define PF_EIP ENTRY
#define PF_CR2 0x00402000
#define PF_COUNT 1
#define GP_COUNT 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 0
#define FINAL_EIP ENTRY
#define FINAL_CR2 PF_CR2
#elif CASE == 9
#define ENTRY 0x00401fee
#define PHYSICAL 0x000f9fee
#define PF_EIP ENTRY
#define PF_CR2 0
#define PF_COUNT 0
#define GP_COUNT 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 0
#define FINAL_EIP ENTRY
#define FINAL_CR2 0
#elif CASE == 10
#define ENTRY 0x00401fff
#define PHYSICAL 0x000f9fff
#define PF_EIP ENTRY
#define PF_COUNT 1
#define GP_COUNT 0
#define NM_COUNT 1
#define INITIAL_TS 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 1
#define FINAL_EIP ENTRY
#define FINAL_CR2 0x00402000
#elif CASE == 11 || CASE == 12
#define ENTRY 0x00401ffe
#define PHYSICAL 0x000f9ffe
#define PF_COUNT 0
#define GP_COUNT 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 0
#define FINAL_EIP ENTRY
#define FINAL_CR2 0
#elif CASE == 13 || CASE == 14 || CASE == 15
#define ENTRY 0x00401ff1
#define PHYSICAL 0x000f9ff1
#define PF_EIP ENTRY
#if CASE == 15
#define PF_COUNT 0
#define FINAL_CR2 0
#else
#define PF_COUNT 1
#define FINAL_CR2 0x00402000
#endif
#if CASE == 13
#define NM_COUNT 1
#endif
#define INITIAL_TS 1
#define GP_COUNT 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 0
#define FINAL_EIP ENTRY
#elif CASE >= 16 && CASE <= 19
#define ENTRY 0x00401ffd
#define PHYSICAL 0x000f9ffd
#define PF_COUNT 0
#define GP_COUNT 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 0
#define FINAL_EIP ENTRY
#define FINAL_CR2 0
#elif CASE == 20
#define ENTRY 0x00401ffd
#define PHYSICAL 0x000f9ffd
#define PF_COUNT 0
#define GP_COUNT 0
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 1
#define FINAL_EIP 0
#define FINAL_CR2 0
#elif CASE == 21
#define ENTRY 0x00401ff0
#define PHYSICAL 0x000f9ff0
#define PF_COUNT 0
#define GP_COUNT 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 0
#define FINAL_EIP ENTRY
#define FINAL_CR2 0
#elif CASE == 22
#define ENTRY 0x00401f00
#define PHYSICAL 0x000f9f00
#define PF_COUNT 0
#define GP_COUNT 0
#define NM_COUNT 1
#define UD_COUNT 1
#define INITIAL_TS 1
#define FINAL_EAX 0xdeadc0de
#define FINAL_COUNTER 0
#define FINAL_EIP ENTRY
#define FINAL_CR2 0
#else
#error CASE must be in 1..22
#endif
#ifndef PF_CR2
#define PF_CR2 0x00402000
#endif
#ifndef NM_COUNT
#define NM_COUNT 0
#endif
#ifndef INITIAL_TS
#define INITIAL_TS 0
#endif
    .global case_id, user_entry_eip, user_entry_physical, expected_pf, expected_gp
    .global expected_final_eax, expected_counter, expected_fault_eip, expected_cr2
    .global user_safe_eip
    .set case_id, CASE
    .set user_entry_eip, ENTRY
    .set user_entry_physical, PHYSICAL
    .set expected_pf, PF_COUNT
    .set expected_gp, GP_COUNT
    .set expected_final_eax, FINAL_EAX
    .set expected_counter, FINAL_COUNTER
    .set expected_fault_eip, FINAL_EIP
    .set expected_cr2, FINAL_CR2
    .set user_safe_eip, 0x00400000
#if CASE >= 10
    .global expected_nm, expected_initial_ts
    .set expected_nm, NM_COUNT
    .set expected_initial_ts, INITIAL_TS
#endif
#if CASE == 22
    .global expected_ud
    .set expected_ud, UD_COUNT
#endif

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
    movl $0x0000ffff, 0x0508
    movl $0x00cf9a00, 0x050c
    movl $0x0000ffff, 0x0510
    movl $0x00cf9200, 0x0514
    movl $0x0000ffff, 0x0518
    movl $0x00cffa00, 0x051c
    movl $0x0000ffff, 0x0520
    movl $0x00cff200, 0x0524
    movl $0x30000067, 0x0528
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
    movl $0x2000, %edi
    xorl %eax, %eax
    movl $20, %ecx
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
    movl $pf_handler, %ebx
    movl $0x1070, %edi
    movl $0x8e00, %edx
    call install_gate
    movl $gp_handler, %ebx
    movl $0x1068, %edi
    call install_gate
#if CASE == 22
    movl $ud_handler, %ebx
#else
    movl $unexpected_fault, %ebx
#endif
    movl $0x1030, %edi
    call install_gate
#if CASE >= 10
    movl $nm_handler, %ebx
    movl $0x1038, %edi
    call install_gate
#endif
    movl $final_grade, %ebx
    movl $0x1200, %edi
    movl $0xee00, %edx
    call install_gate
    movw $0x07ff, 0x0490
    movl $0x00001000, 0x0492
    lidt 0x0490
    movl $0x12000, %edi
    movl $0x00000003, %eax
    movl $20, %ecx
3:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 3b
    movl $0x00004007, 0x12010
    movl $0x0007f007, 0x121fc
    movl $0x00087003, 0x1221c
    movl $0x0008f003, 0x1223c
    movl $0x123c0, %edi
    movl $0x000f0003, %eax
    movl $16, %ecx
4:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 4b
    movl $0x000f8007, 0x13000
    movl $0x000f9007, 0x13004
#if CASE == 7 || CASE == 15 || CASE == 20
    movl $0x000fa007, 0x13008
#else
    movl $0x000fa006, 0x13008
#endif
    movl $0x00012007, 0x11000
    movl $0x00013007, 0x11004
    movl $0x5eedbeef, 0x4000
    movl $0, 0x4004
#if CASE == 10
    movl $0xa5a5a5a5, 0x4010
    movl $0xa5a5a5a5, 0x4014
    movw $0xa5a5, 0x4018
#elif CASE == 20
    movl $0xdeadbeef, 0x4008
    movl $0xdeadbeef, 0x400c
#endif
    xorl %eax, %eax
    movl %eax, %cr2
    movl $0x00011000, %eax
    movl %eax, %cr3
    movl %cr0, %eax
    orl $0x80010000, %eax
#if INITIAL_TS
    orl $8, %eax
#endif
    movl %eax, %cr0
#if CASE == 20
    /* Derive expectations architecturally in CPL0, never from a host reset
     * constant. Word SMSW must merge only BX, preserving EBX[31:16]. */
    .global prepare_smsw_cr0
prepare_smsw_cr0:
    movl %cr0, %edx
    movl %edx, 0x4014
    movl %edx, %edi
    andl $0xffff, %edi
    orl $0xa5a50000, %edi
    movl %edi, 0x4018
    movl $0xa5a55a5a, %ebx
#endif
    movw $0x23, %ax
    movw %ax, %ds
    movw %ax, %es
    movl $0xdeadc0de, %eax
    pushl $0x23
    pushl $0x00080000
    pushl $0x00000002
    pushl $0x1b
    pushl $ENTRY
    .global enter_iret
enter_iret:
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

    /* Actual saved frame operands: error,EIP,CS,EFLAGS,oldESP,oldSS. */
    .macro capture name, offset, reg, expected, selector=0
    .global \name
\name:
    .if \selector
    movzwl \offset(%esp), \reg
    .else
    movl \offset(%esp), \reg
    .endif
    cmpl $\expected, \reg
    jne fail_frame
    .endm

    .global pf_handler
pf_handler:
#if PF_COUNT == 0
    jmp fail_unexpected
#else
    incl 0x2000
    cmpl $1, 0x2000
    jne fail_count
    cmpl $0, 0x2004
    jne fail_count
#if NM_COUNT
    cmpl $NM_COUNT, 0x2008
    jne fail_count
#endif
    capture pf_capture_error, 0, %ebx, 4
    capture pf_capture_eip, 4, %esi, PF_EIP
    movl %esi, 0x200c
    capture pf_capture_cs, 8, %ecx, 0x1b, 1
    capture pf_capture_flags, 12, %ebp, 2
    .global pf_capture_cr2
pf_capture_cr2:
    movl %cr2, %edi
    movl %edi, 0x2014
    cmpl $PF_CR2, %edi
    jne fail_frame
    capture pf_capture_esp, 16, %edx, 0x00080000
    capture pf_capture_ss, 20, %ebp, 0x23, 1
    .global pf_capture_seed, pf_capture_counter, pf_capture_eax
pf_capture_seed:
    movl 0x4000, %ebx
    cmpl $0x5eedbeef, %ebx
    jne fail_effect
pf_capture_counter:
    movl 0x4004, %ecx
    testl %ecx, %ecx
    jnz fail_effect
pf_capture_eax:
    movl %eax, %edx
    cmpl $0xdeadc0de, %edx
    jne fail_effect
    movl $0x000fa007, 0x13008
    movl %cr3, %edx
    movl %edx, %cr3
    addl $4, %esp
    .global pf_retry_iret
pf_retry_iret:
    iret                              /* saved EIP/CS/EFLAGS/SS:ESP untouched */
#endif

    .global gp_handler
gp_handler:
#if GP_COUNT == 0
    jmp fail_unexpected
#else
    incl 0x2004
    cmpl $1, 0x2004
    jne fail_count
    cmpl $PF_COUNT, 0x2000
    jne fail_count
#if CASE >= 10
    cmpl $NM_COUNT, 0x2008
    jne fail_count
#endif
    capture gp_capture_error, 0, %ebx, 0
    capture gp_capture_eip, 4, %esi, ENTRY
    movl %esi, 0x2024
    capture gp_capture_cs, 8, %ecx, 0x1b, 1
    capture gp_capture_flags, 12, %ebp, 2
    .global gp_capture_cr2
gp_capture_cr2:
    movl %cr2, %edi
    movl %edi, 0x202c
    cmpl $FINAL_CR2, %edi
    jne fail_frame
    capture gp_capture_esp, 16, %edx, 0x00080000
    capture gp_capture_ss, 20, %ebp, 0x23, 1
    .global gp_capture_seed, gp_capture_counter, gp_capture_eax
gp_capture_seed:
    movl 0x4000, %ebx
    cmpl $0x5eedbeef, %ebx
    jne fail_effect
gp_capture_counter:
    movl 0x4004, %ecx
    testl %ecx, %ecx
    jnz fail_effect
gp_capture_eax:
    movl %eax, %edx
    cmpl $0xdeadc0de, %edx
    jne fail_effect
    jmp final_grade                   /* invalid instruction is NOT resumed */
#endif

#if CASE >= 10
    /* #NM has no error word: EIP,CS,EFLAGS,oldESP,oldSS. CLTS removes
     * only the architectural cause, then IRET retries the unchanged frame.
     * A missing ModR/M may fault only after that real retry. */
    .global nm_handler
nm_handler:
#if NM_COUNT == 0
    jmp fail_unexpected
#else
    incl 0x2008
    cmpl $1, 0x2008
    jne fail_count
    cmpl $0, 0x2000
    jne fail_count
    cmpl $0, 0x2004
    jne fail_count
#if CASE == 22
    cmpl $0, 0x2010
    jne fail_count
#endif
    capture nm_capture_eip, 0, %esi, ENTRY
    capture nm_capture_cs, 4, %ecx, 0x1b, 1
    capture nm_capture_flags, 8, %ebp, 2
    .global nm_capture_cr2, nm_capture_cr0
nm_capture_cr2:
    movl %cr2, %edi
    testl %edi, %edi
    jnz fail_frame
nm_capture_cr0:
    movl %cr0, %edi
    movl %edi, %edx
    andl $0x80010009, %edx
    cmpl $0x80010009, %edx
    jne fail_frame
    capture nm_capture_esp, 12, %edx, 0x00080000
    capture nm_capture_ss, 16, %ebp, 0x23, 1
    .global nm_capture_seed, nm_capture_counter, nm_capture_eax
nm_capture_seed:
    movl 0x4000, %ebx
    cmpl $0x5eedbeef, %ebx
    jne fail_effect
nm_capture_counter:
    movl 0x4004, %ecx
    testl %ecx, %ecx
    jnz fail_effect
nm_capture_eax:
    movl %eax, %edx
    cmpl $0xdeadc0de, %edx
    jne fail_effect
    .global nm_clear_ts, nm_retry_iret
nm_clear_ts:
    clts
nm_retry_iret:
    iret
#endif
#endif

#if CASE == 22
    /* Unknown D9 D1 remains invalid after CLTS. Check the real no-error
     * #UD frame, then terminate without changing or skipping the instruction. */
    .global ud_handler
ud_handler:
    incl 0x2010
    cmpl $UD_COUNT, 0x2010
    jne fail_count
    cmpl $0, 0x2000
    jne fail_count
    cmpl $0, 0x2004
    jne fail_count
    cmpl $NM_COUNT, 0x2008
    jne fail_count
    capture ud_capture_eip, 0, %esi, ENTRY
    movl %esi, 0x2034
    capture ud_capture_cs, 4, %ecx, 0x1b, 1
    capture ud_capture_flags, 8, %ebp, 2
    .global ud_capture_cr2
ud_capture_cr2:
    movl %cr2, %edi
    testl %edi, %edi
    jnz fail_frame
    capture ud_capture_esp, 12, %edx, 0x00080000
    capture ud_capture_ss, 16, %ebp, 0x23, 1
    .global ud_capture_seed, ud_capture_counter, ud_capture_eax
ud_capture_seed:
    movl 0x4000, %ebx
    cmpl $0x5eedbeef, %ebx
    jne fail_effect
ud_capture_counter:
    movl 0x4004, %ecx
    testl %ecx, %ecx
    jnz fail_effect
ud_capture_eax:
    movl %eax, %edx
    cmpl $0xdeadc0de, %edx
    jne fail_effect
    jmp final_grade
#endif

    .global final_grade
final_grade:
    cmpl $PF_COUNT, 0x2000
    jne fail_count
    cmpl $GP_COUNT, 0x2004
    jne fail_count
#if CASE >= 10
    cmpl $NM_COUNT, 0x2008
    jne fail_count
#endif
#if CASE == 22
    cmpl $UD_COUNT, 0x2010
    jne fail_count
#endif
    cmpl $FINAL_EAX, %eax
    jne fail_effect
#if CASE == 1
    cmpl $0x00401fff, %esi
    jne fail_effect
#elif GP_COUNT == 1
    movl 0x2024, %esi
#elif CASE == 22
    movl 0x2034, %esi
#else
    movl 0x200c, %esi
#endif
#if CASE == 10
    .global final_capture_x87_lo, final_capture_x87_hi, final_capture_x87_exponent
final_capture_x87_lo:
    movl 0x4010, %ebx
    testl %ebx, %ebx
    jnz fail_effect
final_capture_x87_hi:
    movl 0x4014, %edx
    cmpl $0x80000000, %edx
    jne fail_effect
final_capture_x87_exponent:
    movzwl 0x4018, %edi
    cmpl $0x3fff, %edi
    jne fail_effect
#elif CASE == 20
    .global final_capture_smsw_full, final_capture_smsw_word
final_capture_smsw_full:
    movl 0x4008, %edx
    cmpl 0x4014, %edx
    jne fail_effect
final_capture_smsw_word:
    movl 0x400c, %ebx
    cmpl 0x4018, %ebx
    jne fail_effect
#endif
    .global final_capture_seed, final_capture_counter
final_capture_seed:
    movl 0x4000, %ebx
    cmpl $0x5eedbeef, %ebx
    jne fail_effect
final_capture_counter:
    movl 0x4004, %ebp
    cmpl $FINAL_COUNTER, %ebp
    jne fail_effect
    movl %cr2, %edi
    cmpl $FINAL_CR2, %edi
    jne fail_frame
    movl 0x2000, %ecx
    movl $0xc0de0042, %eax
    jmp do_exit
    .global fail_count, fail_frame, fail_effect, fail_unexpected, unexpected_fault
fail_count:
    movb $0x43, %al
    jmp do_exit
fail_frame:
    movb $0x44, %al
    jmp do_exit
fail_effect:
    movb $0x45, %al
    jmp do_exit
fail_unexpected:
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

    .section .user_safe, "ax"
    .global user_safe, user_safe_pop, user_safe_counter, user_safe_int
user_safe:
user_safe_pop:
    popl %esi                         /* exact CALL return-address readback */
user_safe_counter:
    incl 0x4004
user_safe_int:
    int $0x40
6:  jmp 6b

    .section .user_test, "ax"
    .org PHYSICAL - 0x000f9000
    .global user_entry, user_entry_end
user_entry:
#if CASE == 1
    .byte 0xe8
    .long 0x00400000 - (ENTRY + 5)
#elif CASE == 2
    nop
#elif CASE == 3
    .byte 0xb8, 0xe0, 0xac, 0x68       /* final imm32 byte is on next page */
#elif CASE == 4
    .byte 0x8b                         /* ModR/M is on next page */
#elif CASE == 5
    .byte 0x8b, 0x04                   /* SIB is on next page */
#elif CASE == 8
    .rept 12
    .byte 0x2e
    .endr
    .byte 0xb8, 0xe0, 0xac, 0x68       /* byte16 mapped; imm32 endpoint17 NP */
#elif CASE == 9
    .rept 11
    .byte 0x2e
    .endr
    .byte 0x3e, 0xc7, 0x05            /* final override is writable DS */
    .long 0x00004000                  /* first overrun ends at mapped 401fff */
#elif CASE == 10
    .byte 0xd9                        /* #NM precedes missing FLD1 ModR/M */
#elif CASE == 11
    .byte 0x0f, 0x20                  /* CPL3 GP precedes MOV-CR ModR/M */
#elif CASE == 12
    .byte 0x0f, 0x21                  /* CPL3 GP precedes MOV-DR ModR/M */
#elif CASE == 13
    .rept 14
    .byte 0x2e
    .endr
    .byte 0xd9                        /* opcode byte15: #NM before byte16 */
#elif CASE == 16
    .byte 0x0f, 0x01, 0x14            /* LGDT [SIB]: CPL GP before missing SIB */
#elif CASE == 17
    .byte 0x0f, 0x01, 0x34            /* LMSW [SIB]: same pre-EA priority */
#elif CASE == 18
    .byte 0x0f, 0x00, 0x14            /* LLDT [SIB]: same pre-EA priority */
#elif CASE == 19
    .byte 0x0f, 0x01, 0x1c            /* LIDT [SIB]: same pre-EA priority */
#elif CASE == 20
    .byte 0x0f, 0x01, 0xe0            /* default32 SMSW EAX is unprivileged */
#elif CASE == 21
    .rept 11
    .byte 0x2e
    .endr
    .byte 0x0f, 0x01, 0x15, 0x00, 0x40 /* MRM byte14, disp low16 mapped */
#elif CASE == 22
    .byte 0xd9, 0xd1                  /* TS: NM before unsupported escape UD */
#else
    .rept 15
    .byte 0x2e                         /* repeated legacy CS prefixes */
    .endr
#endif
user_entry_end:
#if CASE == 22
    .set user_instruction_end, user_entry_end
#endif

    .section .user_tail, "ax"
    .global user_tail, user_instruction_end, user_counter, user_int
user_tail:
#if CASE == 1
    .byte 0xcc                         /* unreachable and nonpresent */
#elif CASE == 3
    .byte 0x24
#elif CASE == 4
    .byte 0x05
    .long 0x00004000
#elif CASE == 5
    .byte 0x25
    .long 0x00004000
#elif CASE == 6 || CASE == 7
    nop                                /* byte16: overlength, never retires */
#elif CASE == 8
    .byte 0x24                         /* endpoint17: PF before overlength GP */
#elif CASE == 9
    .long 0x13579bdf                  /* unused imm32 is NP; must not PF */
#elif CASE == 10 || CASE == 13
    .byte 0xe8                        /* valid FLD1; byte16 overlong in case13 */
#elif CASE == 11 || CASE == 12
    .byte 0xc0                        /* valid EAX/CR0 or EAX/DR0 register form */
#elif CASE == 14 || CASE == 15
    .byte 0xd9, 0xe8                  /* opcode byte16 rejects before #NM */
#elif CASE >= 16 && CASE <= 19
    .byte 0x25                        /* required SIB is NP; never demanded */
    .long 0x00004000
#elif CASE == 20
    .global user_smsw_full_store, user_smsw_word, user_smsw_word_store, user_smsw_restore
user_smsw_full_store:
    .byte 0xa3
    .long 0x00004008                  /* MOV [4008], EAX */
user_smsw_word:
    .byte 0x66, 0x0f, 0x01, 0xe3      /* word SMSW BX preserves upper EBX */
user_smsw_word_store:
    .byte 0x89, 0x1d
    .long 0x0000400c                  /* MOV [400c], EBX */
user_smsw_restore:
    movl $0xdeadc0de, %eax
#elif CASE == 21
    .byte 0x00, 0x00                  /* disp bytes17/18 NP; CPL GP first */
#endif
#if CASE != 22
user_instruction_end:
#endif
#if CASE == 10
    .global user_x87_store
user_x87_store:
    .byte 0xdb, 0x3d
    .long 0x00004010                  /* FSTP m80: exact raw80 FLD1 witness */
#endif
user_counter:
    incl 0x4004
user_int:
    int $0x40
7:  jmp 7b

    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
