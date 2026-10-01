/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Isolated signed memory-bit-string address / precise-fault witnesses.
 * CASE 1: op32 addr16 positive/negative wrap + modulo immediate control.
 * CASE 2: op16 addr16 wrap, signed low16 index, stale high16 ignored.
 * CASE 3: adjusted op32 read hits NP page (correct CR2, no CF/memory change).
 * CASE 4: RMW write hits RO page (saved CF preserved; independent of EA fix).
 * CASE 5: RMW crosses onto RO page (neither half changes; saved CF preserved).
 * CASE 6: LOCK RMW crosses noncontiguous physical frames, signed index control.
 * CASE 7: RMW read crosses onto NP page (no partial memory/CF effect).
 * CASE 8: adjusted read faults, handler poisons/maps target, full restart re-reads.
 *
 * No device, OS, snapshot, installed-handler or application dependency.
 * Expected FAIL before the fix is evidence, not permission to weaken tests.
 * Exit AL42=PASS / AL43=FAIL; EDI=error count, ECX=PF count, EBX=CASE.
 * PF saved EFLAGS.CF is checked before any handler instruction can hide it.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 8
#error CASE must be 1..8
#endif
#if CASE == 4 || CASE == 5
#define EXPECT_PF_ERROR 3
#else
#define EXPECT_PF_ERROR 0
#endif
#if CASE >= 3 && CASE != 6
#define EXPECT_PF_COUNT 1
#else
#define EXPECT_PF_COUNT 0
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
    movl $0,0x0500
    movl $0,0x0504
    movl $0x0000FFFF,0x0508
    movl $0x00CF9A00,0x050C
    movl $0x0000FFFF,0x0510
    movl $0x00CF9200,0x0514
    movw $0x17,0x0480
    movl $0x0500,0x0482
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
    movw %ax,%fs
    movw %ax,%gs
    movl $0x90000,%esp
    movl $0,0x20000                 /* PF count */
    movl $0,0x20004                 /* errors */
    movl $0,0x20008                 /* last CR2 */
    movl $0,0x2000C                 /* saved CF */

    movl $pf_handler,%eax
    movl %eax,%edx
    andl $0xFFFF,%eax
    orl $0x00080000,%eax
    movl %eax,0x1070
    andl $0xFFFF0000,%edx
    orl $0x00008E00,%edx
    movl %edx,0x1074
    movw $0x07FF,0x0490
    movl $0x1000,0x0492
    lidt 0x0490

#if CASE == 1
    movl $0,0x0000
    movl $0,0xFFFC
    movl $0xDEADFFFC,%ebx
    movl $32,%ecx
    btsl %ecx,(%bx)                 /* addr16 FFFC+4 wraps to0 */
    jc fail
    cmpl $1,0x0000
    jne fail
    cmpl $0,0xFFFC
    jne fail
    movl $0xBEEF0000,%ebx
    movl $-1,%ecx
    btsl %ecx,(%bx)                 /* addr16 0-4 wraps toFFFC, bit31 */
    jc fail
    cmpl $0x80000000,0xFFFC
    jne fail
    movl $0xDEADFFFC,%ebx
    .byte 0x67,0x0F,0xBA,0x2F,0x20 /* BTS dword [BX],imm20: no EA adjustment */
    jc fail
    cmpl $0x80000001,0xFFFC
    jne fail
    cmpl $1,0x0000
    jne fail
#elif CASE == 2
    movw $0,0x0000
    movw $0,0xFFFE
    movl $0xDEADFFFE,%ebx
    movl $0x98760010,%ecx
    btsw %cx,(%bx)                  /* low16 +16 => +2 =>0 */
    jc fail
    cmpw $1,0x0000
    jne fail
    cmpw $0,0xFFFE
    jne fail
    movl $0xBEEF0000,%ebx
    movl $0x1234FFFF,%ecx
    btsw %cx,(%bx)                  /* low16 -1 => -2 =>FFFE, bit15 */
    jc fail
    cmpw $0x8000,0xFFFE
    jne fail
    cmpw $1,0x0000
    jne fail
#else
    /* Identity low4MiB. PT1 maps400000->600000,401000->801000.
     * Linear5000 is a separate writable alias of801000 for the PF handler.
     * All bootstrap writes are before paging and do not rely on BT*. */
    xorl %eax,%eax
    movl $0x11000,%edi
    movl $1024,%ecx
1:  movl %eax,(%edi)
    addl $4,%edi
    loop 1b
    movl $0x12003,0x11000
    movl $0x13003,0x11004
    movl $0x12000,%edi
    movl $3,%eax
    movl $1024,%ecx
1:  movl %eax,(%edi)
    addl $0x1000,%eax
    addl $4,%edi
    loop 1b
    movl $0x801003,0x12014          /* alias5000 */
    movl $0x600003,0x13000
#if CASE == 3 || CASE == 7 || CASE == 8
    movl $0x801002,0x13004          /* second page NP */
#elif CASE == 4 || CASE == 5
    movl $0x801001,0x13004          /* second page present RO */
#else
    movl $0x801003,0x13004
#endif
    movl $0,0x600FF8
    movl $0,0x600FFC
    movl $0,0x801000
    movl $0,0x801004
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    orl $0x80010000,%eax           /* PG+WP: supervisor RO writes must fault */
    movl %eax,%cr0
    jmp 1f
1:
#if CASE == 3
    movl $0x400FFC,%esi
    movl $32,%ecx
    stc
fault_insn:
    btl %ecx,(%esi)                /* adjusted EA401000, not base400FFC */
after_fault:
    cmpl $32,%ecx
    jne fail
    cmpl $0x400FFC,%esi
    jne fail
    cmpl $0,0x400FFC
    jne fail
    cmpl $0,0x5000
    jne fail
#elif CASE == 4
    movl $0x401000,%esi
    movl $0,%ecx
    stc
fault_insn:
    btsl %ecx,(%esi)               /* read allowed, write denied; old target CF0 */
after_fault:
    cmpl $0,%ecx
    jne fail
    cmpl $0,0x401000
    jne fail
    cmpl $0,0x400FFC
    jne fail
#elif CASE == 5
    movl $0x400FFD,%esi
    movl $31,%ecx
    stc
fault_insn:
    btsl %ecx,(%esi)               /* final byte in RO401000; no EA extension */
after_fault:
    cmpl $31,%ecx
    jne fail
    cmpl $0,0x400FFD               /* neither half may have changed */
    jne fail
    cmpb $0,0x400FF9
    jne fail
#elif CASE == 6
    movw $0x7654,0x400FFC
    movl $0x400FFA,%esi
    movl $63,%ecx
    lock btsl %ecx,(%esi)          /* adjusted400FFE across noncontiguous frames */
    jc fail
    cmpl $0x80000000,0x400FFE
    jne fail
    cmpw $0x7654,0x400FFC
    jne fail
    movl $0x401002,%esi
    movl $-1,%ecx
    lock btrl %ecx,(%esi)          /* signed -4 selects the SAME crossing operand */
    jnc fail
    cmpl $0,0x400FFE
    jne fail
    cmpw $0x7654,0x400FFC
    jne fail
#elif CASE == 7
    movl $0x400FF9,%esi
    movl $63,%ecx
    stc
fault_insn:
    btsl %ecx,(%esi)               /* read fault on second page, no store started */
after_fault:
    cmpw $0,0x400FFD
    jne fail
    cmpb $0,0x400FFF
    jne fail
    cmpl $0,0x5000
    jne fail
#elif CASE == 8
    movl $0x400FFC,%esi
    movl $40,%ecx
    stc
fault_insn:
    btsl %ecx,(%esi)               /* PF handler poisons bit8 to1, then retries */
after_fault:
    jnc fail                      /* retry must re-read the handler's NEW bit */
    cmpl $0x100,0x401000
    jne fail
    cmpl $0,0x400FFC
    jne fail
    cmpl $40,%ecx
    jne fail
#endif
#endif

finish:
    cmpl $EXPECT_PF_COUNT,0x20000
    jne fail
    cmpl $0,0x20004
    jne fail
    movl 0x20000,%ecx
    movl 0x20004,%edi
    movl $CASE,%ebx
    movl $0x600DB173,%esi
    movl $0x42,%eax
    movw $0xF4,%dx
    outb %al,%dx
    hlt
fail:
    incl 0x20004
    movl 0x20000,%ecx
    movl 0x20004,%edi
    movl $CASE,%ebx
    movl $0x43,%eax
    movw $0xF4,%dx
    outb %al,%dx
    hlt

pf_handler:
    pushal
    incl 0x20000
#if EXPECT_PF_COUNT == 1
    cmpl $fault_insn,36(%esp)
    jne pf_bad
    cmpl $EXPECT_PF_ERROR,32(%esp)
    jne pf_bad
    movl %cr2,%eax
    movl %eax,0x20008
    cmpl $0x401000,%eax
    jne pf_bad
    movl 44(%esp),%eax
    andl $1,%eax
    movl %eax,0x2000C
    cmpl $1,%eax                   /* fault must preserve pre-instruction CF1 */
    jne pf_bad
#if CASE == 8
    movl $0x100,0x5000            /* writable alias of previously NP target */
    movl $0x801003,0x13004
    movl %cr3,%eax
    movl %eax,%cr3
    jmp pf_return                 /* original saved fault PC: restart */
#endif
    movl $after_fault,36(%esp)
    jmp pf_return
#endif
pf_bad:
    incl 0x20004
    movl $finish,36(%esp)
pf_return:
    popal
    addl $4,%esp                   /* discard PF error code */
    iret

    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    ljmp $0xF000,$_start16_off
    .org 16,0                      /* exactly64KiB flat BIOS, no truncation tool */
