/* Copyright 2026 Ventium Contributors
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Bare-metal 64 KiB BIOS bootstrap for 32-bit protected-mode Dhrystone 2.1.
 * Enters flat 32-bit protected mode (CS=0x08, DS/ES/SS/FS/GS=0x10, base=0,
 * limit=4 GiB), copies the Dhrystone payload into L1-cacheable DRAM at
 * 0x00010000, clears BSS, builds 4 KiB identity page tables (0..4 MiB) at
 * 0x00070000..0x00071FFF, enables L1 I$/D$ (CR0.CD=0, CR0.NW=0) and paging
 * (CR0.PG=1 unless -DDHRY_PAGING=0), and calls dhrystone_entry().
 */

#ifndef DHRY_PAGING
#define DHRY_PAGING 1
#endif

    .equ GDT_ADDR,  0x00000500
    .equ GDTR_ADDR, 0x00000480
    .equ PD_ADDR,   0x00070000
    .equ PT0_ADDR,  0x00071000
    .equ STACK_TOP, 0x0008FF00

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* Install flat 4 GiB 32-bit GDT at 0x0500:
     *   0x00: null
     *   0x08: 32-bit code (base=0, limit=0xFFFFF, G=1, D=1, P=1, DPL=0, exec/read)
     *   0x10: 32-bit data (base=0, limit=0xFFFFF, G=1, B=1, P=1, DPL=0, read/write)
     */
    movl    $GDT_ADDR, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)

    movw    $23, GDTR_ADDR
    movl    $GDT_ADDR, GDTR_ADDR + 2
    lgdt    GDTR_ADDR

    movl    %cr0, %eax
    andl    $0x9FFFFFF3, %eax       /* clear CD, NW, EM, TS */
    orl     $0x00000001, %eax       /* set PE=1 */
    movl    %eax, %cr0

    .byte   0x66, 0xEA
    .long   _boot32
    .word   0x0008

    .code32
    .section .boot32, "ax"
_boot32:
    movw    $0x0010, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $STACK_TOP, %esp
    xorl    %ebp, %ebp

    /* Copy Dhrystone .text/.rodata/.data from ROM window to 0x00010000 DRAM */
    movl    $_payload_lma, %esi
    movl    $_payload_vma_start, %edi
    movl    $_payload_dwords, %ecx
    rep movsl

    /* Zero .bss in low DRAM */
    movl    $__bss_start, %edi
    movl    $__bss_end, %ecx
    subl    %edi, %ecx
    shrl    $2, %ecx
    xorl    %eax, %eax
    rep stosl

#if DHRY_PAGING
    /* Zero Page Directory (0x70000) and Page Table 0 (0x71000) */
    movl    $PD_ADDR, %edi
    movl    $2048, %ecx
    xorl    %eax, %eax
    rep stosl

    /* PDE[0] -> PT0_ADDR | P | RW */
    movl    $(PT0_ADDR | 0x03), PD_ADDR

    /* Populate 1024 4 KiB PTEs identity-mapping 0x00000000..0x003FFFFF */
    movl    $PT0_ADDR, %edi
    movl    $0x00000003, %eax       /* phys 0 | P | RW */
    movl    $1024, %ecx
1:
    movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    decl    %ecx
    jnz     1b

    movl    $PD_ADDR, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    andl    $0x9FFFFFF3, %eax       /* ensure CD=0, NW=0 */
    orl     $0x80000001, %eax       /* PG=1, PE=1 */
    movl    %eax, %cr0
#endif

    /* Indirect jump to relocated 0x00010000 entry in cached DRAM */
    movl    $dhrystone_c_entry, %eax
    call    *%eax

    /* isa-debug-exit (port 0xF4): qemu & tb_ventium exit with (AL << 1) | 1.
     * AL = 0x10 -> status 33 on PASS; AL = nonzero fail_code -> status != 33. */
    outb    %al, $0xF4
    cli
2:
    hlt
    jmp     2b

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000

    .section .note.GNU-stack, "", @progbits
