/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Standalone VERR/VERW architectural witnesses; host build is NOT a run.
 * CASE1 PM32 type/RPL/LDT/null/OOB/P=0 and fixed-word/prefix controls.
 * CASE2 CPL3 privilege and readable-conforming-code controls.
 * CASE3 operand word-end/word-crossing #PF, preserving pre-query ZF/GPRs.
 * CASE4 implicit descriptor high-dword #PF; no early ZF commit.
 * CASE5 real-mode #UD, CASE6 V86 #UD before an unmapped operand.
 * CASE7 PM16, with 66/67 prefixes and precise instruction lengths.
 * CASE8 query TF/#DB; CASE9 illegal LOCK before operand access.
 * CASE10 precise source #GP/#SS, requiring VEN_SEG_ENFORCE (Intel-spec gate).
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 10
#error CASE must be 1..10
#endif
    .set QUERIES, 0x2000
    .set ERRORS, 0x2004
    .set FAULTS, 0x2008
    .set FLAGS_SAVE, 0x200c
    .set EXPECT_PC, 0x2010
    .set RESUME_PC, 0x2014
    .set EXPECT_FLAGS, 0x2018
    .set EXPECT_SP, 0x201c
    .set EXPECT_AX, 0x2020
    .set EXPECT_VECTOR, 0x2024
    .set EXPECT_DS, 0x2028
    .set EXPECT_SS, 0x202c
    .set EDGE, 0x9ffe
    .set TARGET, 0x9000
    .set FLAGS_MASK, 0x003e7fd5 /* defined EFLAGS, except exception-image RF */
#if CASE == 2
    .set QUERY_MODE_FLAGS, 0x3000 /* CPL3 POPF cannot clear current IOPL3 */
#else
    .set QUERY_MODE_FLAGS, 0
#endif
    .set QUERY_EXPECT, 0
#if CASE == 3 || CASE == 4
    .set FAULT_EXPECT, 2
#elif CASE == 5
    .set FAULT_EXPECT, 4
#elif CASE == 6
    .set FAULT_EXPECT, 3
#elif CASE == 8
    .set FAULT_EXPECT, 8
#elif CASE == 9
    .set FAULT_EXPECT, 4
#elif CASE == 10
    .set FAULT_EXPECT, 6
#else
    .set FAULT_EXPECT, 0
#endif

    .macro regs selector
    movl $(0xa55a0000 | \selector),%eax
    movl $0xdead9000,%ebx
    movl $0x23456789,%ecx
    movl $0x3456789a,%edx
    movl $0x56789abc,%ebp
    movl $0x6789abcd,%esi
    movl $0x789abcde,%edi
    .endm
    .macro stage selector, flags=0xcd7
    regs \selector
    pushl $\flags
    popfl
    .endm
    .macro checked selector, zf, flags=0xcd7, bad=fail, count=1
    pushfl
    popl %ss:FLAGS_SAVE
    cmpl $(0xa55a0000 | \selector),%eax
    jne \bad
    cmpl $0xdead9000,%ebx
    jne \bad
    cmpl $0x23456789,%ecx
    jne \bad
    cmpl $0x3456789a,%edx
    jne \bad
    cmpl $0x56789abc,%ebp
    jne \bad
    cmpl $0x6789abcd,%esi
    jne \bad
    cmpl $0x789abcde,%edi
    jne \bad
    cmpl %ss:EXPECT_SP,%esp
    jne \bad
    movl %ss:FLAGS_SAVE,%edx
    andl $FLAGS_MASK,%edx
    cmpl $((\flags & FLAGS_MASK & ~0x40) | (\zf << 6) | QUERY_MODE_FLAGS),%edx
    jne \bad
    .if \count
      incl %ss:QUERIES
      .set QUERY_EXPECT, QUERY_EXPECT+1
    .endif
    .endm

#if CASE >= 8
    /* Every event checks the same-CPL PUSHAL image. The saved PUSHAL ESP is
     * the original ESP minus the 12/16-byte exception frame, not original ESP. */
    .macro event_context error=0
    movl %ss:EXPECT_PC,%eax
    cmpl %eax,(32+4*\error)(%esp)
    jne unexpected
    cmpl $8,(36+4*\error)(%esp)
    jne unexpected
    movl (40+4*\error)(%esp),%eax
    andl $FLAGS_MASK,%eax
    cmpl %ss:EXPECT_FLAGS,%eax
    jne unexpected
    movl %ss:EXPECT_AX,%eax
    cmpl %eax,28(%esp)
    jne unexpected
    cmpl $0x23456789,24(%esp)
    jne unexpected
    cmpl $0x3456789a,20(%esp)
    jne unexpected
    cmpl $0xdead9000,16(%esp)
    jne unexpected
    movl %ss:EXPECT_SP,%eax
    subl $(12+4*\error),%eax
    cmpl %eax,12(%esp)
    jne unexpected
    cmpl $0x56789abc,8(%esp)
    jne unexpected
    cmpl $0x6789abcd,4(%esp)
    jne unexpected
    cmpl $0x789abcde,0(%esp)
    jne unexpected
    movw %ds,%ax
    cmpw %ss:EXPECT_DS,%ax
    jne unexpected
    movw %ss,%ax
    cmpw %ss:EXPECT_SS,%ax
    jne unexpected
    .endm
    .set EVENT_ORDINAL,0
    .macro fault_stage name, resume, vector, flags=0xcd7
    movl $\name,%ss:EXPECT_PC
    movl $\resume,%ss:RESUME_PC
    movl $\vector,%ss:EXPECT_VECTOR
    movl $(\flags & FLAGS_MASK),%ss:EXPECT_FLAGS
    movl $0xa55a0018,%ss:EXPECT_AX
    stage 0x18,\flags
    .endm
    .macro fault_return flags=0xcd7
    checked 0x18,((\flags >> 6) & 1),\flags,fail,0
    .set EVENT_ORDINAL,EVENT_ORDINAL+1
    cmpl $EVENT_ORDINAL,%ss:FAULTS
    jne fail
    .endm
#endif
#if CASE == 8
    .macro tfq name, selector, opcode, modrm, result, zf, flags
    movl $0xffff0ff0,%eax
    movl %eax,%dr6
    movl $\name\()_end,%ss:EXPECT_PC
    movl $((\flags & FLAGS_MASK & ~0x40) | (\zf << 6) | 0x100),%ss:EXPECT_FLAGS
    movl $\result,%ss:EXPECT_AX
    stage \selector,(\flags | 0x100)
    .global \name,\name\()_end
\name:
    .byte 0x0f,\opcode,\modrm
\name\()_end:
    /* IRET must have cleared TF; only LAR/LSL success changes EAX. */
    pushfl
    popl %ss:FLAGS_SAVE
    cmpl $\result,%eax
    jne fail
    cmpl $0xdead9000,%ebx
    jne fail
    cmpl $0x23456789,%ecx
    jne fail
    cmpl $0x3456789a,%edx
    jne fail
    cmpl $0x56789abc,%ebp
    jne fail
    cmpl $0x6789abcd,%esi
    jne fail
    cmpl $0x789abcde,%edi
    jne fail
    cmpl %ss:EXPECT_SP,%esp
    jne fail
    movl %ss:FLAGS_SAVE,%edx
    andl $(FLAGS_MASK | 0x10000),%edx
    cmpl $((\flags & FLAGS_MASK & ~0x40) | (\zf << 6)),%edx
    jne fail
    .set EVENT_ORDINAL,EVENT_ORDINAL+1
    cmpl $EVENT_ORDINAL,%ss:FAULTS
    jne fail
    incl %ss:QUERIES
    .set QUERY_EXPECT,QUERY_EXPECT+1
    .endm
#endif
#if CASE == 10
    .macro ss_memq name, op, address
    stage 0x18
    .global \name,\name\()_end
\name:
    .byte 0x36,0x0f,0x00,(0x05 | (\op << 3))
    .long \address
\name\()_end:
    checked 0x18,1
    .endm
#endif
    .macro regq name, selector, op, zf, prefix=0
    stage \selector
    .global \name, \name\()_end
\name:
    .if \prefix
    .byte 0x66
    .endif
    .byte 0x0f,0x00,(0xc0 | (\op << 3))
\name\()_end:
    checked \selector,\zf
    .endm
    .macro memq name, op, zf, opsize=0, addr16=0, address=TARGET
    stage 0x18
    .global \name, \name\()_end
\name:
    .if \opsize
    .byte 0x66
    .endif
    .if \addr16
    .byte 0x67,0x0f,0x00,(0x07 | (\op << 3)) /* [BX], ignores stale EBX high */
    .else
    .byte 0x0f,0x00,(0x05 | (\op << 3))
    .long \address
    .endif
\name\()_end:
    checked 0x18,\zf
    .endm
    .macro pair stem, selector, readable, writable
    regq \stem\()_r,\selector,4,\readable
    regq \stem\()_w,\selector,5,\writable
    .endm
    .macro gate vector, handler, access=0x8e
    movl $\handler,%eax
    movl %eax,%edx
    andl $0xffff,%eax
    orl $0x00080000,%eax
    movl %eax,(0x1000+8*\vector)
    andl $0xffff0000,%edx
    orl $(\access << 8),%edx
    movl %edx,(0x1004+8*\vector)
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
    movl $0x7000,%esp
    movl $0,QUERIES
    movl $0,ERRORS
    movl $0,FAULTS
    movw $0x1357,TARGET-2
    movw $0x18,TARGET
    movw $0x2468,TARGET+2
#if CASE == 5
    movw $real_ud_handler_off,0x18
    movw $0xf000,0x1a
    stage 0x18
    .global real_r,real_r_end
real_r: .byte 0x0f,0x00,0xe0
real_r_end:
    stage 0x18
    .global real_w66,real_w66_end
real_w66: .byte 0x66,0x0f,0x00,0xe8
real_w66_end:
    stage 0x18
    .global real_mem_r,real_mem_r_end
real_mem_r: .byte 0x0f,0x00,0x26
    .word TARGET
real_mem_r_end:
    stage 0x18
    .global real_mem_w67,real_mem_w67_end
real_mem_w67: .byte 0x67,0x0f,0x00,0x2d
    .long 0x21000
real_mem_w67_end:
    jmp real_finish
#else
    /* GDT descriptors already accessed where actually loaded. Query-only
     * entries deliberately include A=0, proving queries never set A. */
    movl $0,0x500
    movl $0,0x504
    movl $0xffff,0x508
    movl $0x00cf9b00,0x50c       /* 08 code0 */
    movl $0xffff,0x510
    movl $0x00cf9300,0x514       /* 10 RW data0 */
    movl $0xffff,0x518
    movl $0x00cff200,0x51c       /* 18 RW data3 */
    movl $0xffff,0x520
    movl $0x00cff000,0x524       /* 20 RO data3 */
    movl $0xffff,0x528
    movl $0x00cf9e00,0x52c       /* 28 readable conforming code0 */
    movl $0xffff,0x530
    movl $0x00cf9c00,0x534       /* 30 execute-only conforming code0 */
    movl $0xffff,0x538
    movl $0x00cffb00,0x53c       /* 38 readable nonconforming code3 */
    movl $0xffff,0x540
    movl $0x00cff800,0x544       /* 40 execute-only nonconforming code3 */
    movl $0xffff,0x548
    movl $0x00cf7200,0x54c       /* 48 P=0 RW data3 */
    movl $0xffff,0x550
    movl $0x00cf7000,0x554       /* 50 P=0 RO data3 */
    movl $0xffff,0x558
#if CASE == 7
    .global pm16_descriptor_high,pm16_descriptor_high_end
pm16_descriptor_high:
    movl $0x00009b0f,0x55c       /* 58 PM16 code: baseF0000, limitFFFF, G=0,D=0 */
pm16_descriptor_high_end:
#else
    movl $0x000f9b00,0x55c       /* preserved historical unused slot58 encoding */
#endif
    movl $0x40000017,0x560
    movl $0x00008200,0x564       /* 60 LDT, base4000 limit17 */
    movl $0x30000067,0x568
    movl $0x00008900,0x56c       /* 68 TSS32 */
    movl $0xffff,0x570
    movl $0x00cfb200,0x574       /* 70 RW data1 */
    movl $0,0x578
    movl $0x00008c00,0x57c       /* 78 call gate: never data */
#if CASE == 10
    movl $0x9fff,0x580
    movl $0x00409300,0x584       /* 80 DS short: byte limit9fff, B=1 */
    movl $0x9fff,0x588
    movl $0x00409300,0x58c       /* 88 SS short: valid stack below limit */
    movw $0x8f,0x480
#else
    movw $0x7f,0x480
#endif
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm_entry
    .word 8
#endif

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
    movl %esp,EXPECT_SP
#if CASE >= 8
    movl $0x10,EXPECT_DS
    movl $0x10,EXPECT_SS
#endif
#if CASE == 8
    gate 1,db_handler,0x8f
#endif
    gate 6,ud_handler
    gate 8,unexpected
    gate 11,unexpected
#if CASE == 10
    gate 12,seg_ss_handler
    gate 13,seg_gp_handler
#else
    gate 12,unexpected
    gate 13,unexpected
#endif
    gate 14,pf_handler
    gate 32,done_handler,0xee
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0xffff,0x4000
    movl $0x00cff200,0x4004
    movl $0xffff,0x4008
    movl $0x00cff000,0x400c
    movl $0xffff,0x4010
    movl $0x00cf7200,0x4014
    movw $0x60,%ax
    lldt %ax

#if CASE == 1
    pair rw0,0x10,1,1
    pair rw3,0x18,1,1
    pair ro3,0x20,1,0
    pair conf_read,0x2b,1,0
    pair conf_exec,0x33,0,0
    pair code_read,0x3b,1,0
    pair code_exec,0x43,0,0
    pair absent_rw,0x4b,1,1
    pair absent_ro,0x53,1,0
    pair system_ldt,0x60,0,0
    pair system_tss,0x68,0,0
    pair system_gate,0x78,0,0
    pair rpl_deny,0x13,0,0
    pair null0,0,0,0
    pair null3,3,0,0
    pair gdt_oob,0x80,0,0
    pair ldt_index0,4,1,1
    pair ldt_ro,0x0f,1,0
    pair ldt_absent,0x17,1,1
    pair ldt_oob,0x1c,0,0
    regq reg_r66,0x18,4,1,1
    regq reg_w66,0x18,5,1,1
    memq mem_r,4,1
    memq mem_w,5,1
    memq mem_r66,4,1,1
    memq mem_w66,5,1,1
    memq mem_r67,4,1,0,1
    memq mem_w67,5,1,0,1
    memq mem_r6667,4,1,1,1
    memq mem_w6667,5,1,1,1
    /* Neither query may set the queried descriptor's accessed bit. */
    cmpl $0x00cff200,%ss:0x51c
    jne fail
    cmpl $0x00cf7200,%ss:0x54c
    jne fail
    jmp finish
#elif CASE == 2 || CASE == 6
    /* Zero complete TSS, then publish only the architectural CPL0 stack. */
    movl $0x3000,%edi
    xorl %eax,%eax
    movl $26,%ecx
    rep stosl
    movl $0x88000,0x3004
    movw $0x10,0x3008
    movw $0x68,%ax
    ltr %ax
#if CASE == 2
    movl $0x80000,EXPECT_SP
    pushl $0x1b
    pushl $0x80000
    pushl $0x3002                 /* IOPL3 permits terminal OUT at CPL3 */
    pushl $0x3b
    pushl $ring3
    iret
ring3:
    movw $0x1b,%ax
    movw %ax,%ds
    movw %ax,%es
    pair cpl_deny0,0x10,0,0
    pair cpl_deny1,0x70,0,0
    pair cpl_rw3,0x1b,1,1
    pair cpl_ro3,0x23,1,0
    pair cpl_conf_read,0x2b,1,0
    pair cpl_conf_exec,0x33,0,0
    pair cpl_code0,8,0,0
    pair cpl_code3,0x3b,1,0
    pair cpl_absent,0x4b,1,1
    pair cpl_null,3,0,0
    pair cpl_oob,0x80,0,0
    jmp finish
#else
    movl $v86_start,%esi
    movl $0x10000,%edi
    movl $(v86_end-v86_start),%ecx
    rep movsb
    call paging
    pushl $0
    pushl $0
    pushl $0x2000
    pushl $0
    pushl $0x2000
    pushl $0xf000
    pushl $0x23002
    pushl $0x1000
    pushl $0
    iret
#endif
#elif CASE == 3
    movw $0x18,0x20ffe
    call paging
    memq edge_word_r,4,1,0,0,0x20ffe
    memq edge_word_w66,5,1,1,0,0x20ffe
    movl $operand_fault1,EXPECT_PC
    movl $operand_resume1,RESUME_PC
    movl $(0xcd7 & FLAGS_MASK),EXPECT_FLAGS
    stage 0x18
    .global operand_fault1,operand_resume1
operand_fault1:
    .byte 0x0f,0x00,0x25
    .long 0x21000
operand_resume1:
    cmpl $1,%ss:FAULTS
    jne fail
    movl $operand_fault2,EXPECT_PC
    movl $operand_resume2,RESUME_PC
    movl $(0xc97 & FLAGS_MASK),EXPECT_FLAGS
    stage 0x18,0xc97
    .global operand_fault2,operand_resume2
operand_fault2:
    .byte 0x66,0x0f,0x00,0x2d
    .long 0x20fff
operand_resume2:
    jmp finish
#elif CASE == 4
    /* Legal unaligned GDT base: query selector18's low dword is20ffc,
     * high dword21000 is NP. Handler CS8 remains fully mapped at20fec. */
    movl $0x500,%esi
    movl $0x20fe4,%edi
    movl $10,%ecx
    rep movsl
    movw $0x27,0x480
    movl $0x20fe4,0x482
    lgdt 0x480
    call paging
    pair descriptor_null,0,0,0
    pair descriptor_oob,0x28,0,0
    movl $descriptor_fault1,EXPECT_PC
    movl $descriptor_resume1,RESUME_PC
    movl $(0xcd7 & FLAGS_MASK),EXPECT_FLAGS
    stage 0x18
    .global descriptor_fault1,descriptor_resume1
descriptor_fault1: .byte 0x0f,0x00,0xe0
descriptor_resume1:
    cmpl $1,%ss:FAULTS
    jne fail
    movl $descriptor_fault2,EXPECT_PC
    movl $descriptor_resume2,RESUME_PC
    movl $(0xc97 & FLAGS_MASK),EXPECT_FLAGS
    stage 0x18,0xc97
    .global descriptor_fault2,descriptor_resume2
descriptor_fault2: .byte 0x66,0x0f,0x00,0xe8
descriptor_resume2:
    jmp finish
#elif CASE == 7
    ljmp $0x58,$pm16_entry_off
#elif CASE == 8
    movl $0x400,%eax
    movl %eax,%dr7              /* no competing address breakpoints */
    tfq tf_verr_valid,0x18,0x00,0xe0,0xa55a0018,1,0xc97
    tfq tf_verr_null,0,0x00,0xe0,0xa55a0000,0,0xcd7
    tfq tf_verw_valid,0x18,0x00,0xe8,0xa55a0018,1,0xc97
    tfq tf_verw_ro,0x20,0x00,0xe8,0xa55a0020,0,0xcd7
    tfq tf_lar_valid,0x18,0x02,0xc0,0x00c0f200,1,0xc97
    tfq tf_lar_null,0,0x02,0xc0,0xa55a0000,0,0xcd7
    tfq tf_lsl_valid,0x18,0x03,0xc0,0xffffffff,1,0xc97
    tfq tf_lsl_null,0,0x03,0xc0,0xa55a0000,0,0xcd7
    jmp finish
#elif CASE == 9
    call paging
    movl $0x77889900,%eax
    movl %eax,%cr2              /* #UD must not visit the absent operand */
    fault_stage lock_verr_reg,lock_verr_reg_end,6
    .global lock_verr_reg,lock_verr_reg_end
lock_verr_reg: .byte 0xf0,0x0f,0x00,0xe0
lock_verr_reg_end:
    fault_return
    fault_stage lock_verw_reg66,lock_verw_reg66_end,6,0xc97
    .global lock_verw_reg66,lock_verw_reg66_end
lock_verw_reg66: .byte 0xf0,0x66,0x0f,0x00,0xe8
lock_verw_reg66_end:
    fault_return 0xc97
    fault_stage lock_verr_mem,lock_verr_mem_end,6
    .global lock_verr_mem,lock_verr_mem_end
lock_verr_mem: .byte 0xf0,0x0f,0x00,0x25
    .long 0x21000
lock_verr_mem_end:
    fault_return
    fault_stage lock_verw_mem66,lock_verw_mem66_end,6,0xc97
    .global lock_verw_mem66,lock_verw_mem66_end
lock_verw_mem66: .byte 0xf0,0x66,0x0f,0x00,0x2d
    .long 0x21000
lock_verw_mem66_end:
    fault_return 0xc97
    jmp finish
#elif CASE == 10
    movw $0x1357,%ss:EDGE-2
    movw $0x18,%ss:EDGE
    movw $0x2468,%ss:EDGE+2
    xorw %ax,%ax
    movw %ax,%ds
    movl $0,%ss:EXPECT_DS
    fault_stage gp_null_verr,gp_null_verr_end,13
    .global gp_null_verr,gp_null_verr_end
gp_null_verr: .byte 0x0f,0x00,0x25
    .long TARGET
gp_null_verr_end:
    fault_return
    fault_stage gp_null_verw66,gp_null_verw66_end,13,0xc97
    .global gp_null_verw66,gp_null_verw66_end
gp_null_verw66: .byte 0x66,0x0f,0x00,0x2d
    .long TARGET
gp_null_verw66_end:
    fault_return 0xc97
    ss_memq null_ds_ss_verr,4,TARGET
    ss_memq null_ds_ss_verw,5,TARGET
    movw $0x80,%ax
    movw %ax,%ds
    movl $0x80,%ss:EXPECT_DS
    memq short_ds_legal_verr,4,1,0,0,EDGE
    memq short_ds_legal_verw,5,1,1,0,EDGE
    fault_stage gp_limit_verr,gp_limit_verr_end,13
    .global gp_limit_verr,gp_limit_verr_end
gp_limit_verr: .byte 0x0f,0x00,0x25
    .long EDGE+1
gp_limit_verr_end:
    fault_return
    fault_stage gp_limit_verw66,gp_limit_verw66_end,13,0xc97
    .global gp_limit_verw66,gp_limit_verw66_end
gp_limit_verw66: .byte 0x66,0x0f,0x00,0x2d
    .long EDGE+1
gp_limit_verw66_end:
    fault_return 0xc97
    movw $0x10,%ax
    movw %ax,%ds
    movl $0x10,%ss:EXPECT_DS
    movw $0x88,%ax
    movw %ax,%ss
    movl $0x7000,%esp
    movl %esp,%ss:EXPECT_SP
    movl $0x88,%ss:EXPECT_SS
    ss_memq short_ss_legal_verr,4,EDGE
    ss_memq short_ss_legal_verw,5,EDGE
    fault_stage ss_limit_verr,ss_limit_verr_end,12
    .global ss_limit_verr,ss_limit_verr_end
ss_limit_verr: .byte 0x36,0x0f,0x00,0x25
    .long EDGE+1
ss_limit_verr_end:
    fault_return
    fault_stage ss_limit_verw66,ss_limit_verw66_end,12,0xc97
    .global ss_limit_verw66,ss_limit_verw66_end
ss_limit_verw66: .byte 0x36,0x66,0x0f,0x00,0x2d
    .long EDGE+1
ss_limit_verw66_end:
    fault_return 0xc97
    movw $0x10,%ax
    movw %ax,%ss
    movl $0x90000,%esp
    movl %esp,%ss:EXPECT_SP
    movl $0x10,%ss:EXPECT_SS
    cmpw $0x1357,%ss:EDGE-2
    jne fail
    cmpw $0x18,%ss:EDGE
    jne fail
    cmpw $0x2468,%ss:EDGE+2
    jne fail
    jmp finish
#endif

paging:
    /* Identity low4MiB, including BIOS, structures, both stacks and V86.
     * Only page21000 is absent. U/S=1 permits the V86 code/data controls. */
    movl $0x11000,%edi
    xorl %eax,%eax
    movl $1024,%ecx
    rep stosl
    movl $0x12007,0x11000
    movl $0x12000,%edi
    movl $7,%eax
    movl $1024,%ecx
1:  movl %eax,(%edi)
    addl $0x1000,%eax
    addl $4,%edi
    loop 1b
    movl $0x21006,0x12084
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    orl $0x80000000,%eax
    movl %eax,%cr0
    ret

pf_handler:
    pushal
    incl %ss:FAULTS
#if CASE == 3 || CASE == 4
    movl %ss:EXPECT_PC,%eax
    cmpl %eax,36(%esp)
    jne pf_bad
    cmpl $0,32(%esp)              /* supervisor read, not-present */
    jne pf_bad
    movl %cr2,%eax
    cmpl $0x21000,%eax
    jne pf_bad
    movl 44(%esp),%eax
    andl $FLAGS_MASK,%eax
    cmpl %ss:EXPECT_FLAGS,%eax
    jne pf_bad
    cmpl $0xa55a0018,28(%esp)
    jne pf_bad
    cmpl $0x23456789,24(%esp)
    jne pf_bad
    cmpl $0x3456789a,20(%esp)
    jne pf_bad
    cmpl $0xdead9000,16(%esp)
    jne pf_bad
    cmpl $0x8fff0,12(%esp)
    jne pf_bad
    cmpl $0x56789abc,8(%esp)
    jne pf_bad
    cmpl $0x6789abcd,4(%esp)
    jne pf_bad
    cmpl $0x789abcde,0(%esp)
    jne pf_bad
    movl %ss:RESUME_PC,%eax
    movl %eax,36(%esp)
    popal
    addl $4,%esp
    iret
#endif
pf_bad:
    jmp unexpected

ud_handler:
#if CASE == 6
    pushal
    incl %ss:FAULTS
    movl 40(%esp),%eax
    andl $FLAGS_MASK,%eax
    cmpl $(0x23000 | (0xcd7 & FLAGS_MASK)),%eax
    jne unexpected
    cmpl $0x1000,36(%esp)
    jne unexpected
    cmpl $0x87fdc,12(%esp)
    jne unexpected
    cmpl $0xf000,44(%esp)
    jne unexpected
    cmpl $0x2000,48(%esp)
    jne unexpected
    cmpl $0x2000,56(%esp)
    jne unexpected
    cmpl $0xa55a0018,28(%esp)
    jne unexpected
    cmpl $0x23456789,24(%esp)
    jne unexpected
    cmpl $0x3456789a,20(%esp)
    jne unexpected
    cmpl $0xdead9000,16(%esp)
    jne unexpected
    cmpl $0x56789abc,8(%esp)
    jne unexpected
    cmpl $0x6789abcd,4(%esp)
    jne unexpected
    cmpl $0x789abcde,0(%esp)
    jne unexpected
    cmpl $1,%ss:FAULTS
    jne 1f
    cmpl $(vm_r-v86_start),32(%esp)
    jne unexpected
    addl $(vm_r_end-vm_r),32(%esp)
    jmp 3f
1:  cmpl $2,%ss:FAULTS
    jne 2f
    cmpl $(vm_mem_w-v86_start),32(%esp)
    jne unexpected
    addl $(vm_mem_w_end-vm_mem_w),32(%esp)
    jmp 3f
2:  cmpl $3,%ss:FAULTS
    jne unexpected
    cmpl $(vm_r66-v86_start),32(%esp)
    jne unexpected
    addl $(vm_r66_end-vm_r66),32(%esp)
3:  popal
    iret
#elif CASE == 9
    pushal
    event_context
    cmpl $6,%ss:EXPECT_VECTOR
    jne unexpected
    movl %cr2,%eax
    cmpl $0x77889900,%eax
    jne unexpected
    incl %ss:FAULTS
    movl %ss:RESUME_PC,%eax
    movl %eax,32(%esp)
    popal
    iret
#else
    jmp unexpected
#endif
#if CASE == 8
    .global db_handler
db_handler:
    pushal
    event_context
    /* TF traps save the post-query flags/PC; unlike faults they do not set RF. */
    testl $0x10000,40(%esp)
    jnz unexpected
    pushfl
    popl %eax
    testl $0x100,%eax
    jnz unexpected
    movl %dr6,%eax
    testl $0x4000,%eax
    jz unexpected
    incl %ss:FAULTS
    andl $~0x100,40(%esp)        /* prevent recursive stepping after IRET */
    movl $0xffff0ff0,%eax
    movl %eax,%dr6
    popal
    iret
#endif
#if CASE == 10
    .global seg_gp_handler,seg_ss_handler
seg_gp_handler:
    pushal
    cmpl $13,%ss:EXPECT_VECTOR
    jne unexpected
    jmp seg_fault_common
seg_ss_handler:
    pushal
    cmpl $12,%ss:EXPECT_VECTOR
    jne unexpected
seg_fault_common:
    event_context 1
    cmpl $0,32(%esp)
    jne unexpected
    incl %ss:FAULTS
    movl %ss:RESUME_PC,%eax
    movl %eax,36(%esp)
    popal
    addl $4,%esp
    iret
#endif
done_handler:
    jmp finish
unexpected:
    incl %ss:ERRORS
fail:
    incl %ss:ERRORS
    movl $0x43,%eax
    jmp terminal
finish:
    cmpl $query_expected,%ss:QUERIES
    jne fail
    cmpl $FAULT_EXPECT,%ss:FAULTS
    jne fail
    cmpl $0,%ss:ERRORS
    jne fail
    cmpw $0x1357,%ss:TARGET-2
    jne fail
    cmpw $0x18,%ss:TARGET
    jne fail
    cmpw $0x2468,%ss:TARGET+2
    jne fail
    movl $0x42,%eax
terminal:
    movl %ss:QUERIES,%ecx
    movl %ss:FAULTS,%edx
    movl %ss:ERRORS,%edi
    movl %ss:FAULTS,%ebp
    movl $CASE,%ebx
    movl $0x600d0f00,%esi
    /* EBP retains the fault count after DX becomes the terminal port. */
    .global do_out
    movw $0xf4,%dx
do_out:
    outb %al,%dx
    hlt

    .code16
    .section .text16,"ax"
#if CASE == 5
    .global real_ud_handler
real_ud_handler:
    pushal
    incl %ss:FAULTS
    movw 36(%esp),%ax
    andw $(FLAGS_MASK & 0xffff),%ax
    cmpw $(0xcd7 & FLAGS_MASK & 0xffff),%ax
    jne real_bad
    cmpl $0xa55a0018,28(%esp)
    jne real_bad
    cmpw $0xf000,34(%esp)
    jne real_bad
    cmpl $0x6ffa,12(%esp)
    jne real_bad
    cmpl $0x23456789,24(%esp)
    jne real_bad
    cmpl $0x3456789a,20(%esp)
    jne real_bad
    cmpl $0xdead9000,16(%esp)
    jne real_bad
    cmpl $0x56789abc,8(%esp)
    jne real_bad
    cmpl $0x6789abcd,4(%esp)
    jne real_bad
    cmpl $0x789abcde,0(%esp)
    jne real_bad
    cmpl $1,%ss:FAULTS
    jne 1f
    cmpw $real_r_off,32(%esp)
    jne real_bad
    addw $(real_r_end-real_r),32(%esp)
    jmp 4f
1:  cmpl $2,%ss:FAULTS
    jne 2f
    cmpw $real_w66_off,32(%esp)
    jne real_bad
    addw $(real_w66_end-real_w66),32(%esp)
    jmp 4f
2:  cmpl $3,%ss:FAULTS
    jne 3f
    cmpw $real_mem_r_off,32(%esp)
    jne real_bad
    addw $(real_mem_r_end-real_mem_r),32(%esp)
    jmp 4f
3:  cmpl $4,%ss:FAULTS
    jne real_bad
    cmpw $real_mem_w67_off,32(%esp)
    jne real_bad
    addw $(real_mem_w67_end-real_mem_w67),32(%esp)
4:  popal
    iret
real_bad:
    incl %ss:ERRORS
real_finish:
    cmpl $4,%ss:FAULTS
    jne real_fail
    cmpl $0,%ss:ERRORS
    jne real_fail
    movl $0x42,%eax
    jmp real_terminal
real_fail:
    incl %ss:ERRORS
    movl $0x43,%eax
real_terminal:
    movl %ss:QUERIES,%ecx
    movl %ss:ERRORS,%edi
    movl %ss:FAULTS,%ebp
    movl $CASE,%ebx
    movl $0x600d0f00,%esi
    movw $0xf4,%dx
    .global real_do_out
real_do_out:
    outb %al,%dx
    hlt
#endif
#if CASE == 7
    .macro q16 name, op, zf, opsize=0, addr32=0, memory=0
    stage 0x18
    .global \name, \name\()_end
\name:
    .if \opsize
    .byte 0x66
    .endif
    .if \addr32
    .byte 0x67
    .endif
    .byte 0x0f,0x00
    .if \memory
      .if \addr32
      .byte (0x05 | (\op << 3))
      .long TARGET
      .else
      .byte (0x06 | (\op << 3))
      .word TARGET
      .endif
    .else
    .byte (0xc0 | (\op << 3))
    .endif
\name\()_end:
    checked 0x18,\zf,0xcd7,pm16_fail
    .endm
    .global pm16_entry
pm16_entry:
    q16 pm16_r,4,1
    q16 pm16_w66,5,1,1
    q16 pm16_mem_r,4,1,0,0,1
    q16 pm16_mem_w66,5,1,1,0,1
    q16 pm16_mem_r67,4,1,0,1,1
    q16 pm16_mem_w6667,5,1,1,1,1
    ljmpl $8,$finish
pm16_fail:
    ljmpl $8,$fail
#endif
#if CASE == 6
    .section .text32,"ax"
v86_start:
    stage 0x18
    .global vm_r,vm_r_end
vm_r: .byte 0x0f,0x00,0xe0
vm_r_end:
    stage 0x18
    .global vm_mem_w,vm_mem_w_end
vm_mem_w: .byte 0x0f,0x00,0x2e
    .word 0x1000                /* DS2000:1000 = absent linear21000 */
vm_mem_w_end:
    stage 0x18
    .global vm_r66,vm_r66_end
vm_r66: .byte 0x66,0x0f,0x00,0xe0
vm_r66_end:
    int $0x20
v86_end:
#endif
    .global query_expected,fault_expected
    .set query_expected,QUERY_EXPECT
    .set fault_expected,FAULT_EXPECT
    .section .reset,"ax"
    .code16
    .global _reset
_reset:
    ljmp $0xf000,$_start16_off
    .org 16,0
