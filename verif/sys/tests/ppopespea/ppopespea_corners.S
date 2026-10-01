/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * CASE3..16 independent sentinels/precision. Wrap destination follows pinned
 * QEMU's full-ESP+width EA; SS.B0 architectural SP updates preserve high ESP.
 * No CALL/RETF/IRET prerequisite for any of these cases.
 */
#if CASE < 3 || CASE > 16
#error CASE must be3..16
#endif
#if CASE == 3 || CASE == 4 || CASE == 6
#define WIDTH 2
#else
#define WIDTH 4
#endif
#if CASE == 3 || CASE == 5 || CASE == 6 || CASE == 7 || CASE == 13
#define STACK_B 0
#else
#define STACK_B 1
#endif
#if CASE == 6
#define OLD_ESP 0x1fffe
#elif CASE == 7 || CASE == 8
#define OLD_ESP 0x1fffc
#elif CASE == 3 || CASE == 4 || CASE == 5 || CASE == 13
#define OLD_ESP 0x12000
#elif CASE == 12
#define OLD_ESP 0xfff8
#elif CASE == 16
#define OLD_ESP 0x10000
#else
#define OLD_ESP 0x2000
#endif
#if STACK_B
#define SOURCE OLD_ESP
#define POST_ESP (OLD_ESP + WIDTH)
#define HANDLER_ESP (OLD_ESP - 16)
#define FRAME (OLD_ESP - 16)
#else
#define SOURCE (OLD_ESP & 0xffff)
#define POST_ESP ((OLD_ESP & 0xffff0000) | ((OLD_ESP + WIDTH) & 0xffff))
#define HANDLER_ESP ((OLD_ESP & 0xffff0000) | ((OLD_ESP - 16) & 0xffff))
#define FRAME ((OLD_ESP - 16) & 0xffff)
#endif
#if CASE == 9
#define DISP -4
#elif CASE == 10
#define DISP 0x18000
#elif CASE == 12
#define DISP 4
#elif CASE == 14 || CASE == 15
#define DISP 0xffa
#else
#define DISP 8
#endif
#if CASE == 10
#define DEST_BASE 0x40000
#else
#define DEST_BASE 0
#endif
#if CASE == 11
#define DESTINATION 0x7008
#define WRONG_DESTINATION 0x7008
#elif CASE == 8
#define DESTINATION (OLD_ESP + WIDTH + 3 * 4 + DISP)
#define WRONG_DESTINATION (DESTINATION - WIDTH)
#else
#define DESTINATION (DEST_BASE + OLD_ESP + WIDTH + DISP)
#define WRONG_DESTINATION (DESTINATION - WIDTH)
#endif
#if CASE == 14 || CASE == 15
#if DESTINATION != 0x2ffe || ((DESTINATION & 0xfff) + WIDTH) <= 0x1000
#error CASE14/15 must really cross the4KiB destination boundary
#endif
#endif
#if CASE == 12 || CASE == 13 || CASE == 15 || CASE == 16
#define FAULTED 1
#define FINAL_ESP OLD_ESP
#else
#define FAULTED 0
#if CASE == 11
#define FINAL_ESP 0x13579bdf
#else
#define FINAL_ESP POST_ESP
#endif
#endif
#if CASE == 13
#define FAULT_VECTOR 12
#define ERROR 0
#define CR2_VALUE 0
#elif CASE == 15
#define FAULT_VECTOR 14
#define ERROR 3
#define CR2_VALUE 0x3000
#elif CASE == 16
#define FAULT_VECTOR 14
#define ERROR 0
#define CR2_VALUE 0x10000
#else
#define FAULT_VECTOR 14
#define ERROR 2
#define CR2_VALUE 0x10000
#endif
#define VALUE 0x13579bdf
#if WIDTH == 2
#define READ_VALUE 0x9bdf
#define CANARY 0x5aa5
#define WRONG_CANARY 0x3c3c
#else
#define READ_VALUE VALUE
#define CANARY 0xa55a5aa5
#define WRONG_CANARY 0x3c3c3c3c
#endif
    .global case_id, expected_esp, pop_esp, destination_lin, source_lin, expected_value, expected_cs
    .global width, stack_b, initial_esp, expected_faults, expected_fault_vector, expected_fault_error
    .global expected_cr2, expected_handler_esp, wrong_destination_lin, paged_case
    .global expected_fault_flags
    .set case_id, CASE
    .set expected_esp, FINAL_ESP
    .set pop_esp, POST_ESP
    .set destination_lin, DESTINATION
    .set wrong_destination_lin, WRONG_DESTINATION
    .set source_lin, SOURCE
    .set expected_value, READ_VALUE
    .set expected_cs, 8
    .set width, WIDTH
    .set stack_b, STACK_B
    .set initial_esp, OLD_ESP
    .set expected_faults, FAULTED
    .set expected_fault_vector, FAULT_VECTOR
    .set expected_fault_error, ERROR
    .set expected_cr2, CR2_VALUE
    .set expected_handler_esp, HANDLER_ESP
    /* Exact current pinned-QEMU profile, not Intel automatic-RF qualification.
     * Intel1997 Vol3 printed14-9 requires RF on these fault-class images;
     * original10002 fixtures preserve that independent fidelity failure. */
    .set expected_fault_flags, 2
    .set paged_case, (CASE == 12 || CASE == 14 || CASE == 15 || CASE == 16)
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
    movl $0x00409b0f,0x50c
    movl $0x0000ffff,0x510
    movl $0x00cf9300,0x514
    movl $0,0x518
    movl $0,0x51c
    movl $0x0000ffff,0x520
#if CASE == 13
    movl $0x00009300,0x524
#else
    movl $(0x008f9300 | (STACK_B << 22)),0x524
#endif
    movl $0x0000ffff,0x528
    movl $0x00cf9304,0x52c
    movw $0x2f,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long _pm32_off
    .word 8
    .code32
    .section .text32,"ax"
    .global pm32_entry, fault_fail, fault_handler
pm32_entry:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movl $0x9000,%esp
    xorl %eax,%eax
    movl %eax,%cr2
    movl %eax,%cr3
    movl $0,0x2100
    movl $0x5000,%edi
    movl $16,%ecx
1:  movl $_fault_gate_low,(%edi)
    movl $0x00008e00,4(%edi)
    addl $8,%edi
    loop 1b
    movl $_precision_gate_low,(0x5000 + FAULT_VECTOR * 8)
    movw $0x7f,0x490
    movl $0x5000,0x492
    lidt 0x490
#if WRONG_DESTINATION != SOURCE && WRONG_DESTINATION != DESTINATION
#if WIDTH == 2
    movw $WRONG_CANARY,WRONG_DESTINATION
#else
    movl $WRONG_CANARY,WRONG_DESTINATION
#endif
#endif
#if DESTINATION != SOURCE
#if WIDTH == 2
    movw $CANARY,DESTINATION
#else
    movl $CANARY,DESTINATION
#endif
#endif
    movl $0x5aa5a55a,(DESTINATION + WIDTH)
    movl $VALUE,SOURCE
#if CASE == 11
    movw $0xa55a,0x3018
#endif
#if CASE == 12 || CASE == 14 || CASE == 15 || CASE == 16
    movl $0x11000,%edi
    movl $2048,%ecx
    xorl %eax,%eax
    rep stosl
    movl $0x12003,0x11000
    movl $0x12000,%edi
    movl $3,%eax
    movl $256,%ecx
2:  movl %eax,(%edi)
    addl $0x1000,%eax
    addl $4,%edi
    loop 2b
#if CASE == 12 || CASE == 16
    movl $0,0x12040
#elif CASE == 15
    movl $0x3001,0x1200c
#endif
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    orl $0x80010000,%eax
    movl %eax,%cr0
#endif
    pushl $2
    popfl
#if CASE == 10
    movw $0x28,%ax
    movw %ax,%es
#endif
    movw $0x20,%ax
    movw %ax,%ss
    movl $OLD_ESP,%esp
    movl $0x11223344,%eax
    movl $0x3000,%ebx
    movl $3,%ecx
    movl $0x55667788,%edx
    movl $0x10,%esi
    movl $0x778899aa,%edi
    movl $0x7000,%ebp
    jmp tested_entry
    .section .textcase,"ax"
    .global tested_entry, tested_pop, pop_end, tested_retf, after_retf
    .global control_addr16, control_reg, control_esp
    .global capture_esp, capture_destination, capture_source, do_exit, set_exit_port, do_out, fail
tested_entry:
tested_pop:
#if CASE == 8
    popl 8(%esp,%ecx,4)
#elif CASE == 9
    popl -4(%esp)
#elif CASE == 10
    popl %es:0x18000(%esp)
#elif CASE == 11
    popl 8(%ebp)
#elif CASE == 12
    popl 4(%esp)
#elif CASE == 14 || CASE == 15
    popl 0xffa(%esp)
#elif WIDTH == 2
    popw 8(%esp)
#else
    popl 8(%esp)
#endif
pop_end:
tested_retf:
after_retf:
#if FAULTED
    jmp fail
#elif CASE == 11
    cmpl $0x2004,%esp
    jne fail
    cmpl $VALUE,0x7008
    jne fail
    movl $OLD_ESP,%esp
control_addr16:
    popw 8(%bx,%si)
    cmpl $0x2002,%esp
    jne fail
    cmpw $0x9bdf,0x3018
    jne fail
    movl $OLD_ESP,%esp
control_reg:
    popl %edi
    cmpl $VALUE,%edi
    jne fail
    cmpl $0x2004,%esp
    jne fail
    movl $OLD_ESP,%esp
control_esp:
    popl %esp
    cmpl $VALUE,%esp
    jne fail
#endif
capture_esp:
    movl %esp,%ecx
    movw $0x10,%ax
    movw %ax,%ss
    movw %ax,%es
    movl $0x9000,%esp
#if CASE != 11 && !FAULTED
    pushfl
    popl %edx
    cmpl $2,%edx
    jne fail
#endif
    cmpl $FINAL_ESP,%ecx
    jne fail
capture_destination:
#if WIDTH == 2
    movzwl DESTINATION,%esi
#else
    movl DESTINATION,%esi
#endif
#if FAULTED
    cmpl $CANARY,%esi
#else
    cmpl $READ_VALUE,%esi
#endif
    jne fail
capture_source:
#if WIDTH == 2
    movzwl SOURCE,%edi
#else
    movl SOURCE,%edi
#endif
    cmpl $READ_VALUE,%edi
    jne fail
#if WRONG_DESTINATION != SOURCE && WRONG_DESTINATION != DESTINATION
#if WIDTH == 2
    cmpw $WRONG_CANARY,WRONG_DESTINATION
#else
    cmpl $WRONG_CANARY,WRONG_DESTINATION
#endif
    jne fail
#endif
    cmpl $0x5aa5a55a,(DESTINATION + WIDTH)
    jne fail
    movl 0x2100,%ebp
    cmpl $FAULTED,%ebp
    jne fail
    movl $CASE,%ebx
do_exit:
    movl $0x42,%eax
set_exit_port:
    movw $0xf4,%dx
do_out:
    outb %al,%dx
3:  hlt
    jmp 3b
fail:
    movl $0x43,%eax
    movw $0xf4,%dx
    outb %al,%dx
4:  hlt
    jmp 4b
    .section .text32,"ax"
fault_handler:
#if FAULTED
    movl %esp,%ecx
    cmpl $HANDLER_ESP,%ecx
    jne fault_fail
    cmpl $ERROR,FRAME
    jne fault_fail
    cmpl $_tested_pop_off,(FRAME + 4)
    jne fault_fail
    cmpl $8,(FRAME + 8)
    jne fault_fail
    .global check_fault_flags
check_fault_flags:
    cmpl $2,(FRAME + 12)
    jne fault_fail
    cmpl $0x11223344,%eax
    jne fault_fail
    cmpl $0x3000,%ebx
    jne fault_fail
    cmpl $0x55667788,%edx
    jne fault_fail
    cmpl $0x10,%esi
    jne fault_fail
    cmpl $0x778899aa,%edi
    jne fault_fail
    cmpl $0x7000,%ebp
    jne fault_fail
    movl %cr2,%eax
    cmpl $CR2_VALUE,%eax
    jne fault_fail
    incl 0x2100
    movl %cr0,%eax
    andl $0x7fffffff,%eax
    movl %eax,%cr0
    movl $OLD_ESP,%esp
    jmp capture_esp
#endif
fault_fail:
    movl $0x43,%eax
    movw $0xf4,%dx
    outb %al,%dx
5:  hlt
    jmp 5b
    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11,1,0
