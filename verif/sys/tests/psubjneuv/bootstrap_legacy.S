/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * External directed diagnostic, not a Quake image or snapshot restoration.
 * Diagnostic JP mutation:171 of172 Quake bytes unchanged, finalJNE14565->JP.
 * Memory schedule remains1,1,0,0; EDI schedule0,0,80000000,0.
 * Third CMP produces OF1/ZF0/PF1; JP outcomesNT,NT,T,T.
 * SOURCE ONLY: one recurrent congruent caller page before all64 bodies.
 * Runtime retained-owner/predT-actualNT conjunction is REQUIRED, not assumed.
 * IF0/IOPL0 and bootstrap retain the previously accepted CPL3 fixture policy.
 */
    /* Private logger variant only; production BIOS/Quake are never patched.
     * 0=original JP control, 1/2=CPL3 UD/PF, 3/4=CPL0 UD/PF validation.
     */
    .ifndef LOGGER_MODE
    .set LOGGER_MODE, 0
    .endif
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
    movl $0, 0x500
    movl $0, 0x504
    movl $0x0000ffff, 0x508
    movl $0x00cf9a00, 0x50c
    movl $0x0000ffff, 0x510
    movl $0x00cf9200, 0x514
    movl $0xd68800af, 0x518
    movl $0x00008202, 0x51c
    movl $0x06000067, 0x520
    movl $0x00008900, 0x524
    movw $0x27, 0x480
    movl $0x500, 0x482
    lgdt 0x480
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long pm32_entry
    .word 8

    .code32
    .section .text32, "ax"
pm32_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x7000, %esp
    xorl %eax, %eax
    movl $0x79000, %edi
    movl $1024, %ecx
    rep stosl
    movl $0x7c000, %edi
    movl $1024, %ecx
    rep stosl
    movl $0x7d000, %edi
    movl $1024, %ecx
    rep stosl
    movl $0x7e000, %edi
    movl $1024, %ecx
    rep stosl
    movl $sub_client, %esi
    movl $0x158000, %edi
    movl $1024, %ecx
    rep movsl
    /* Copy immutable caller code BEFORE paging; no writes to its hot page. */
    movl $sub_warm_page, %esi
    movl $0x134000, %edi
    movl $1024, %ecx
    rep movsl
    .ifdef COLD_LAYOUT
    movl $sub_warm_page, %esi
    movl $0x136000, %edi
    movl $1024, %ecx
    rep movsl
    .endif
    movl $0x00000f3f, 0x2d728
    movl $0x10c0fa00, 0x2d72c
    movl $0x0000ffff, 0x2d730
    movl $0x10cff200, 0x2d734
    movw $0x18, %ax
    lldt %ax
    xorl %eax, %eax
    movl $0x600, %edi
    movl $26, %ecx
    rep stosl
    movl $0x7000, 0x604
    movw $0x10, 0x608
    movw $0x68, 0x666
    movw $0x20, %ax
    ltr %ax
    /* Ordinary interrupt gates, not a guest-rescue or altered payload. */
    call exception_init
    movw $0x407, 0x490
    movl $0x800, 0x492
    lidt 0x490
    movl $0x7d003, 0x7e000
    movl $0x7c227, 0x7e100
    movl $0x79227, 0x7e10c
    movl $0x00000003, 0x7d000
    movl $0x00006003, 0x7d018
    movl $0x00007003, 0x7d01c
    movl $0x0002d003, 0x7d0b4
    movl $0x000f0003, 0x7d3c0
    /* Added ordinary cacheable user pages for real prelude destinations. */
    movl $0x0015fa67, 0x7c180  /* DS:60270 -> physical15f270 */
    movl $0x001b7a67, 0x7c2e0  /* DS:b8200/b85fc -> physical1b7200/1b75fc */
    movl $0x001c7a67, 0x7c320  /* DS:c8f7c..8c -> physical1c7f7c..8c */
    movl $0x00113a67, 0x7c050
    movl $0x00158a67, 0x7c164 /* New client59000 -> physical158000. */
    /* New readonly/user/cacheable caller; matches naturalpage134000 geometry. */
    movl $0x00134a65, 0x7c0d4
    movl $0x001e5a67, 0x7c380
    .ifdef COLD_LAYOUT
    movl $0x001ffa67, 0x7c3e8 /* cold guestFA000 -> physical1ff000 */
    movl $0x0020fa67, 0x7c068 /* ordinary D-pressure pages */
    movl $0x0021fa67, 0x7c06c
    movl $0x00136a65, 0x7c0dc /* second I-pressure tag */
    .endif
    movl $0x0044a267, 0x7cd2c
    movl $0x00f8ba67, 0x79a30
    /* Actual first-failure pointer/object pages, ordinary cacheable user mappings. */
    movl $0x003c3a67, 0x7cb10
    movl $0x00ffda67, 0x79bf8
    movl $0x7e000, %eax
    movl %eax, %cr3
    movl %cr0, %eax
    andl $0x9fffffff, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0
    .if LOGGER_MODE >= 3
    jmp kernel_forced_case
    .endif
    pushl $0xaf
    .ifdef COLD_LAYOUT
    pushl $0xfaef0
    pushl $0x3202
    .else
    pushl $0xe07f8
    pushl $2
    .endif
    pushl $0xa7
    pushl $0x59000
    iretl
    .global exit_cpl0, exit_out, exit_hlt, exit_halted
exit_cpl0:
    movw $0xf4, %dx
exit_out:
    outb %al, %dx
exit_hlt:
    hlt
exit_halted:
    jmp exit_hlt

    .section .client32, "ax"
    .global client
client:
    movw $0xaf, %ax
    movw %ax, %ds
    movw %ax, %es
    .if LOGGER_MODE == 1 || LOGGER_MODE == 2
    movl $0x11111111, %eax
    movl $0x22222222, %ecx
    movl $0x33333333, %edx
    movl $0x44444444, %ebx
    movl $0x55555555, %ebp
    movl $0x66666666, %esi
    movl $0x77777777, %edi
    .global user_forced_fault
user_forced_fault:
    .if LOGGER_MODE == 1
    ud2
    .else
    movl 0x00400000, %eax
    .endif
    ud2
    .endif
    movl $0, 0x14f00
    movl $0, 0x14f20
    movl $0, 0x14f24
    jmp case_setup

    .org 0x400, 0x90
    .global fullchain_return
fullchain_return:
    nop
    jmp verify_return

    .org 0x4ce, 0x90
    .global prelude_bytes
prelude_bytes:
.Lprelude:
    /* Exact saved DDR/accepted Quake prelude; never reassemble these bytes. */
    .byte 0x89,0x44,0x24,0x1c,0x8b,0x4c,0x24,0x1c,0x89,0x0d,0x8c,0x8f
    .byte 0x0c,0x00,0x0f,0xb6,0x43,0x38,0x8b,0x04,0x85,0x00,0x82,0x0b
    .byte 0x00,0x89,0x44,0x24,0x18,0x8b,0x4c,0x24,0x18,0x89,0x0d,0x7c
    .byte 0x8f,0x0c,0x00,0x0f,0xb6,0x43,0x39,0x8b,0x2c,0x85,0x00,0x82
    .byte 0x0b,0x00,0x89,0x2d,0x80,0x8f,0x0c,0x00,0x0f,0xb6,0x43,0x3a
    .byte 0x8b,0x3c,0x85,0x00,0x82,0x0b,0x00,0x89,0x3d,0x84,0x8f,0x0c
    .byte 0x00,0x0f,0xb6,0x43,0x3b,0x8b,0x04,0x85,0x00,0x82,0x0b,0x00
    .byte 0x89,0x44,0x24,0x14,0x8b,0x4c,0x24,0x14,0x89,0x0d,0x88,0x8f
    .byte 0x0c,0x00,0x8b,0x54,0xb3,0x1c,0x83,0xc4,0x04,0x85,0xd2,0x74
    .byte 0x3f,0x83,0x7a,0x18,0x00,0x75,0x39,0xa1,0x70,0x02,0x06,0x00
    .byte 0x39,0x43,0x04,0x74,0x2f,0x8b,0x4c,0x24,0x18,0x39,0x4a,0x2c
    .byte 0x75,0x26
    .global fullchain_bytes
fullchain_bytes:
    /* One byte mutation at14565/index151:75->7a; other37chain bytes unchanged. */
    .byte 0x8b,0x4c,0x24,0x14,0x39,0x4a,0x08,0x75,0x1d,0x39,0x6a,0x0c
    .byte 0x75,0x18,0x39,0x7a,0x10,0x7a,0x13,0x8b,0x4c,0x24,0x10,0x39
    .byte 0x4a,0x14,0x75,0x0a,0x89,0xd0,0x5b,0x5e,0x5f,0x5d,0x83,0xc4
    .byte 0x10,0xc3

    /* Preserve original common branch target MOV EAX,1, then fail closed. */
    .global fullchain_taken
fullchain_taken:
    .byte 0xb8,0x01,0x00,0x00,0x00
    /* Synthetic test-only common-target epilogue; no Quake cache allocation. */
    popl %ebx
    popl %esi
    popl %edi
    popl %ebp
    addl $0x10, %esp
    ret

    .org 0x600, 0x90
    .global case_setup
case_setup:
    /* Call before stack setup so synthetic payload return slot is overwritten correctly. */
    call warm_caller_once
    /* 64 invocations: each owner sees mem1,1,0,0 and EDI0,0,80000000,0.
     * Correct JP outcomesNT,NT,T,T; memory CMP and prelude unchanged.
     * Body has ONE explicitly labelled opcode mutation;171bytes unchanged.
     * IF0/IOPL0, no IRQ hooks, snapshots, forced cache returns or DUT writes. */
    movl 0x14f00, %ecx
    testl $4, %ecx
    jnz owner_b
    movl $0x2c403c, %ebx
    movl $2, %esi
    movl $0xefe6cc, %edx
    movl $0xefe6cc, 0x2c4060
    movl $0, 0x2c4040
    movl $0xffffff00, 0x2c4074
    movl $0x43, 0x60270
    jmp owner_ready
owner_b:
    movl $0x34b11c, %ebx
    movl $0, %esi
    movl $0xe8c3cc, %edx
    movl $0xe8c3cc, 0x34b138
    movl $0, 0x34b120
    movl $0xffffff00, 0x34b154
    movl $0xae, 0x60270
owner_ready:
    movl %edx, 0x14f04
    movl %ebx, 0x14f0c
    movl $0x108, 8(%edx)
    movl $0, 0xc(%edx)
    movl $0, 0x14(%edx)
    movl $0, 0x18(%edx)
    movl $0x34a79c, 0x2c(%edx)
    movl $0x108, 0xb8200
    movl $0, 0xb85fc
    movl $0x80000000, 0xb85f8  /* paletteFE; only byte3A/EDI selects it */
    movl $0, 0x14f10          /* expected stored EDI, not restored EDI */
    movl $0, 0xe07f4
    movl $0xee048, 0xe07f8
    movl %ebx, 0xe07fc
    movl $0xee020, 0xe0800
    movl $0x11b34c, 0xe0804
    movl $0, 0xe0808
    movl $0x108, 0xe080c
    movl $0x34a79c, 0xe0810
    movl $0x80000000, 0xe0814
    movl $0x14400, 0xe0818
    testl $2, %ecx
    jnz prepare_nt
    movl $1, 0x10(%edx)
    movl %edx, 0x14f08  /* low-byte1:PF0 ->NT EDX return */
    jmp prepared
prepare_nt:
    /* Legacylabel meansZEROoperand, notJE branchNT. */
    movl $0, 0x10(%edx)
    movl $1, 0x14f08  /* zero:PF1 ->T common-target EAX1 */
    movl %ecx, %eax
    andl $3, %eax
    cmpl $2, %eax
    jne prepared
    /* Third case: actual prelude reloads EDI from paletteFE.
     * Merely changing prepared EDI would be overwritten by original bytes.
     * Byte39/3B stayFF, so EBP and later EAX stayzero. */
    .global overflow_case_inputs
overflow_case_inputs:
    movb $0xfe, 0x3a(%ebx)
    movl $0x80000000, 0x14f10
    movl $1, 0x14f08  /* 0-80000000:PF1; correct JP isT */
prepared:
    /* EDX must be produced again by the actual14530 indexed pointer load. */
    movl $0xe07f4, %esp
    pushl $0x46
    popfl
    movl $0x34a79c, %eax
    movl $0, %ecx
    movl $0, %edx
    movl $0, %edi
    movl $0, %ebp
    .global fullchain_entry_jump
fullchain_entry_jump:
    jmp .Lprelude

    .org 0xa00, 0x90
verify_return:
    pushfl
    popl %ecx
    cmpl $6, %ecx
    jne .Lbad
    cmpl 0x14f08, %eax
    jne .Lbad
    cmpl 0x14f04, %edx
    jne .Lbad
    cmpl $0xee048, %ebx
    jne .Lbad
    cmpl 0x14f0c, %esi
    jne .Lbad
    cmpl $0xee020, %edi
    jne .Lbad
    cmpl $0x11b34c, %ebp
    jne .Lbad
    cmpl $0xe081c, %esp
    jne .Lbad
    cmpl $0x108, 0xc8f7c
    jne .Lbad
    cmpl $0, 0xc8f80
    jne .Lbad
    movl 0x14f10, %eax
    cmpl %eax, 0xc8f84
    jne .Lbad
    cmpl $0, 0xc8f88
    jne .Lbad
    cmpl $0x34a79c, 0xc8f8c
    jne .Lbad
    incl 0x14f00
    cmpl $64, 0x14f00
    jb case_setup
    .global warm_count_final, warm_checksum_final, bad_case
warm_count_final:
    cmpl $64, 0x14f20
    jne .Lbad
warm_checksum_final:
    cmpl $0xd5540, 0x14f24
    jne .Lbad
    movl $0x42, %eax
    int $0x80
bad_case:
.Lbad:
    movl $0xee, %eax
    int $0x80
    ud2
    .org 0xc00, 0x90
    .global warm_caller_once, warm_caller_checked, warm_caller_complete
warm_caller_once:
    xorl %eax, %eax
    movl $0x35560, %edx
    call *%edx
warm_caller_checked:
    cmpl $0x3555, %eax
    jne .Lbad
    addl %eax, 0x14f24
    incl 0x14f20
warm_caller_complete:
    ret

    .org 0xf00, 0
    .long 0,0,0,0
    .long 0,0,0
    .org 4096, 0x90

    /* Only ONE new caller code page/line; no >=3tag cold replacement sweep. */
    .section .warm_caller32, "ax"
    .global warm_caller_page, warm_caller_entry, warm_caller_ret
warm_caller_page:
    .org 0x560, 0x90
warm_caller_entry:
    addl $0x3555, %eax
warm_caller_ret:
    ret
    .org 4096, 0x90

    .code16
    /* Entire logger is an ordinary mapped supervisor code page. */
    .code32
    .section .exception32, "ax"
    .global exception_init, exception_stubs, exception_common
exception_init:
    movl $0x000f3003, 0x7d3cc
    movl $exception_stubs, %ebx
    movl $0x800, %edi
    movl $32, %ecx
.Linstall_exception:
    movl %ebx, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0(%edi)
    movl %ebx, %eax
    andl $0xffff0000, %eax
    orl $0x00008e00, %eax
    movl %eax, 4(%edi)
    addl $16, %ebx
    addl $8, %edi
    loop .Linstall_exception
    movl $exit_cpl0, %ebx
    movl %ebx, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0xc00
    movl %ebx, %eax
    andl $0xffff0000, %eax
    orl $0x0000ee00, %eax
    movl %eax, 0xc04
    ret
    .org 0x100, 0x90
exception_stubs:
    .irp vec,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    .if \vec != 8 && \vec != 10 && \vec != 11 && \vec != 12 && \vec != 13 && \vec != 14 && \vec != 17
    pushl $0
    .endif
    pushl $\vec
    jmp exception_common
    .org 0x100 + 16 * (\vec + 1), 0x90
    .endr
    .org 0x500, 0x90
exception_common:
    cli
    cld
    pushal
    pushl %ds
    pushl %es
    pushl %fs
    pushl %gs
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    leal 48(%esp), %ebp  /* normalized vec,err,EIP,CS,EFLAGS[,oldESP,oldSS] */
    movl $1, 0x104
    movl 0(%ebp), %eax
    movl %eax, 0x108
    movl 4(%ebp), %eax
    movl %eax, 0x10c
    movl 8(%ebp), %eax
    movl %eax, 0x110
    movl 12(%ebp), %eax
    movl %eax, 0x114
    movl 16(%ebp), %eax
    movl %eax, 0x118
    testb $3, 12(%ebp)
    jz .Lsame_priv_frame
    movl 20(%ebp), %eax
    movl %eax, 0x11c
    movl 24(%ebp), %eax
    jmp .Lsave_old_ss
.Lsame_priv_frame:
    leal 20(%ebp), %eax
    movl %eax, 0x11c
    xorl %eax, %eax
    movw %ss, %ax
.Lsave_old_ss:
    andl $0xffff, %eax
    movl %eax, 0x120
    movl %cr2, %eax
    movl %eax, 0x124
    movl %cr3, %eax
    movl %eax, 0x128
    movl %cr0, %eax
    movl %eax, 0x12c
    leal 16(%esp), %esi
    movl $0x130, %edi
    movl $8, %ecx
    rep movsl          /* EDI,ESI,EBP,entryESP,EBX,EDX,ECX,EAX */
    movl %esp, %esi
    movl $0x150, %edi
    movl $4, %ecx
    rep movsl          /* GS,FS,ES,DS; only low16 of segment pushes are defined */
    movl %ebp, 0x160
    movl %esp, 0x164
    movl $0x564c4f47, 0x100  /* publish LAST; no speculative validity claim */
    movw $0xf4, %dx
    xorb %al, %al
    .global exception_out, exception_hlt, exception_halted
exception_out:
    outb %al, %dx
exception_hlt:
    hlt
exception_halted:
    jmp exception_hlt
    .org 0x800, 0x90
    .global kernel_forced_case, kernel_forced_fault
kernel_forced_case:
    pushl $2
    popfl
    movl $0x11111111, %eax
    movl $0x22222222, %ecx
    movl $0x33333333, %edx
    movl $0x44444444, %ebx
    movl $0x55555555, %ebp
    movl $0x66666666, %esi
    movl $0x77777777, %edi
kernel_forced_fault:
    .if LOGGER_MODE == 3
    ud2
    .else
    movl 0x00300000, %eax
    .endif
    ud2
    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
