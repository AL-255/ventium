/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * CPL0 protected32 software-RF retention/completion probes. No paging,
 * snapshots, debug registers, task transfers, or RF-specific guest verdict.
 * Observe FULL saved EFLAGS in EBP and compare the COMPLETE architectural
 * trace. CASE3 skips the faulting DIV after capture, not a retry test.
 */
#ifndef CASE
#error CASE must be 1..7
#endif
#if CASE < 1 || CASE > 7
#error CASE must be 1..7
#endif
#if CASE == 1
#define SEED_FLAGS 0x00000002
#else
#define SEED_FLAGS 0x00010002
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
    movw $23,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm_entry
    .word 8

    .code32
    .section .text32,"ax"
pm_entry:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movl $0x90000,%esp
    /* Install ONLY the intended vector; a wrong delivery cannot hit an
     * equivalent shared handler through the other directed vector.
     */
    movl $0,0x1000
    movl $0,0x1004
    movl $0,0x1030
    movl $0,0x1034
    .macro install_gate vector
    movl $fault_handler,%eax
    movw %ax,0x1000+8*\vector
    movw $8,0x1002+8*\vector
    movw $0x8f00,0x1004+8*\vector
    shrl $16,%eax
    movw %ax,0x1006+8*\vector
    .endm
#if CASE == 3
    install_gate 0
#else
    install_gate 6
#endif
    movw $55,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $7,%eax
    movl $0,%ecx
    movl $0,%edx
    movl $0,%ebp
    movl $0,%esi
    movl $0,%edi
#if CASE == 7
    movl $2,0x20000            /* BTS sees old bit1=1; CF must become1. */
#endif
#if CASE == 6
    /* This operand precedes the THREE-word RF seed frame. IRETD entered
     * RF0 leaves ESP=0x8fffc; the first POPFD restores ESP=0x90000.
     */
    pushl $0x00000047
#endif
    pushl $SEED_FLAGS
    pushl $8
    pushl $probe_entry
    .global seed_iret
seed_iret:
    iretl

    .global probe_entry,ordinary_success,fault_instruction,post_fault
probe_entry:
#if CASE == 4
ordinary_success:
    movl $0x71727374,%edx
#elif CASE == 5
ordinary_success:
    stc                       /* Whole-flags completion must retain new CF1. */
#elif CASE == 6
ordinary_success:
    popfl                     /* Load complete0x47, consume incoming RF1. */
#elif CASE == 7
ordinary_success:
    btsl $1,0x20000           /* Final store ACK commits CF1 and clears RF. */
#else
ordinary_success = probe_entry
#endif
fault_instruction:
#if CASE == 3
    divl %ecx                 /* #DE before successful DIV/undefined flags. */
#else
    ud2
#endif
post_fault:
#if CASE == 7
    movl 0x20000,%edx         /* Full destination dword witness remains2. */
#endif
    movl $(0x52460000+CASE),%ebx
    .global supply_exit_code
supply_exit_code:
    movb $0x42,%al
    .global normal_exit
normal_exit:
    outb %al,$0xf4
    hlt
    jmp normal_exit

    .global fault_handler,capture_saved_flags,capture_saved_pc
fault_handler:
capture_saved_flags:
    movl 8(%esp),%ebp          /* FULL saved EFLAGS; no RF mask. */
capture_saved_pc:
    movl (%esp),%esi
    movl $1,%edi
    movl $post_fault,(%esp)    /* Skip only this directed faulting instruction. */
    iretl

    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
