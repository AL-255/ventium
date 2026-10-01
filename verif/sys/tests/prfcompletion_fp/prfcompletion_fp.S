/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * PREPARED ONLY: CPL0 protected32 successful x87 RF-completion probes.
 * The seed IRETD is entered with RF0 and restores RF1 immediately before
 * one x87 probe. UD2 then saves FULL EFLAGS, not a masked guest verdict.
 * x87=false traces check integer/system state and store readbacks only.
 * They do NOT establish x87 register/datapath bit correctness.
 */
#ifndef CASE
#error CASE must be 1..4
#endif
#if CASE < 1 || CASE > 4
#error CASE must be 1..4
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
    /* Only the intended vector6 trap gate exists; #DE cannot masquerade
     * as the directed UD2 through an equivalent shared handler.
     */
    movl $0,0x1000
    movl $0,0x1004
    movl $0,0x1030
    movl $0,0x1034
    movl $fault_handler,%eax
    movw %ax,0x1030
    movw $8,0x1032
    movw $0x8f00,0x1034
    shrl $16,%eax
    movw %ax,0x1036
    movw $55,0x490
    movl $0x1000,0x492
    lidt 0x490

#if CASE != 1
    fninit                    /* FPU setup completes before restoring RF. */
#endif
    movl $0x3f800000,0x20000   /* +1.0 single, valid flat source memory. */
    /* The entire 28-byte destination begins with a different sentinel;
     * CW, SW and TAG readbacks prove actual environment writes, not
     * merely the RF/retire result. Reserved fields are not interpreted.
     */
    movl $0xa5a55a5a,0x20100
    movl $0xa5a55a5a,0x20104
    movl $0xa5a55a5a,0x20108
    movl $0xa5a55a5a,0x2010c
    movl $0xa5a55a5a,0x20110
    movl $0xa5a55a5a,0x20114
    movl $0xa5a55a5a,0x20118
    movl $7,%eax
    movl $0,%ecx
    movl $0,%edx
    movl $0,%ebp
    movl $0,%esi
    movl $0,%edi
    pushl $0x00010002
    pushl $8
    pushl $probe_entry
    .global seed_iret
seed_iret:
    iretl

    .global probe_entry,ordinary_success,fault_instruction,post_fault
probe_entry:
ordinary_success:
#if CASE == 1
    fninit                    /* Register/control command completion. */
#elif CASE == 2
    flds 0x20000              /* 32-bit memory load, no waiting prefix. */
#elif CASE == 3
    fnstcw 0x20100            /* Successful 16-bit control-word store. */
#else
    fnstenv 0x20100           /* .code32 selects the 28-byte environment. */
#endif
fault_instruction:
    ud2
post_fault:
#if CASE >= 3
    .global capture_control_word
capture_control_word:
    movzwl 0x20100,%ecx       /* Full stored CW must be default037f. */
#endif
#if CASE == 4
    .global capture_status_word,capture_tag_word
capture_status_word:
    movzwl 0x20104,%edx       /* FNINIT's empty-state SW must be0000. */
capture_tag_word:
    movzwl 0x20108,%eax       /* Empty-state TAG must beffff. */
#endif
    movl $(0x52465000+CASE),%ebx
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
    movl 8(%esp),%ebp         /* FULL saved flags in the32-bit trap frame. */
capture_saved_pc:
    movl (%esp),%esi
    movl $1,%edi
    movl $post_fault,(%esp)   /* Skip only directed UD2 after recording it. */
    iretl

    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
