/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Directed CS extent witnesses for the UV-fast NEW memory-request cofactor.
 * Build KIND=0(load)/1(store), LENGTH=2/3/6, OVER=0(exact end)/1(overrun).
 * All conventional segment bases are ZERO: unlike pfetchlim's relocated-CS
 * stubs, these probes satisfy the deployed common-base fast-path contract.
 * DS/ES/SS retain full limits; only CS has a byte-granular limit.
 *
 * An exact-end memory instruction must commit, then #GP at the NEXT fetch.
 * An overrun must #GP at the memory instruction without changing EAX/RAM.
 * The handler checks the error, CS and precise EIP before returning flat.
 * QEMU is not the CS-extent oracle; this is a self-checking witness, not a
 * differential waiver. Native path/held-owner checks are required separately.
 */
#if (KIND != 0 && KIND != 1) || (LENGTH != 2 && LENGTH != 3 && LENGTH != 6) || (OVER != 0 && OVER != 1)
#error Invalid CS extent fixture configuration
#endif
    .set TARGET, 0x00030000
    .set PROBE_PC, 0x00008030
    .set CS_LIMIT, PROBE_PC + LENGTH - 1 - OVER
#if OVER
    .set FAULT_PC, PROBE_PC
#else
    .set FAULT_PC, PROBE_PC + LENGTH
#endif
    .global PROBE_PC, CS_LIMIT, FAULT_PC

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
    movl $CS_LIMIT, 0x0518
    movl $0x00409a00, 0x051c
    movw $0x001f, 0x0480
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
    movl $0x90000, %esp
    movl $0x600, %edi
    movl $32, %ecx
    xorl %eax, %eax
    rep stosl
    movl $gp_handler, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0x600 + 13*8
    movl $gp_handler, %eax
    andl $0xffff0000, %eax
    orl $0x8e00, %eax
    movl %eax, 0x600 + 13*8 + 4
    movw $0x7f, 0x0490
    movl $0x600, 0x0492
    lidt 0x0490
    movl $0, 0x710
    movl $0, 0x714
    movl $0x5eedf00d, TARGET
    movl $probe_template, %esi
    movl $0x8000, %edi
    movl $probe_end - probe_template, %ecx
    rep movsb
    /* Flush initialized data, so an accepted load can retain a miss owner.
     * This is guest WBINVD, not a host state patch or save-state restore. */
    wbinvd
#if LENGTH == 2
    movl $TARGET, %ebx
#else
    movl $TARGET-4, %ebx
#endif
#if KIND == 0
    movl $0xdeadcafe, %eax
#else
    movl $0xcafebabe, %eax
#endif
    .byte 0xea
    .long 0x8000
    .word 0x18

    .global case_return
case_return:
#if KIND == 0 && OVER == 0
    cmpl $0x5eedf00d, %eax
#elif KIND == 0
    cmpl $0xdeadcafe, %eax
#else
    cmpl $0xcafebabe, %eax
#endif
    jne fail
    movl TARGET, %ebp
#if KIND == 1 && OVER == 0
    cmpl $0xcafebabe, %ebp
#else
    cmpl $0x5eedf00d, %ebp
#endif
    jne fail
    movl 0x710, %edi
    cmpl $1, %edi
    jne fail
    movl 0x714, %esi
    cmpl $FAULT_PC, %esi
    jne fail
    movl $0x42, %eax
    jmp do_exit
    .global fail
fail:
    movl $0x43, %eax
do_exit:
    movw $0xf4, %dx
    outb %al, %dx
    hlt
    jmp do_exit

gp_handler:
    pushl %eax
    cmpl $0, 4(%esp)
    jne fail
    cmpl $FAULT_PC, 8(%esp)
    jne fail
    cmpw $0x18, 12(%esp)
    jne fail
    incl 0x710
    movl 8(%esp), %eax
    movl %eax, 0x714
    movl $case_return, 8(%esp)
    movl $0x08, 12(%esp)
    popl %eax
    addl $4, %esp
    iret

    .balign 32
    .global probe_template, probe_insn, probe_after, probe_end
probe_template:
    /* Independent register pairs warm the raw U/V frontend; a taken jump
     * makes the measured memory instruction the next U, not a V sidecar. */
    .rept 8
    movl %esi, %esi
    movl %edi, %edi
    .endr
    jmp probe_insn
    .fill 0x30-(.-probe_template), 1, 0x90
probe_insn:
#if KIND == 0
    .byte 0x8b
#else
    .byte 0x89
#endif
#if LENGTH == 2
    .byte 0x03
#elif LENGTH == 3
    .byte 0x43, 0x04
#else
    .byte 0x83
    .long 4
#endif
probe_after:
    /* Unchecked execution must NOT return a success marker. */
    .byte 0xea
    .long fail
    .word 0x08
probe_end:

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
