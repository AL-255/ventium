/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Cold-boot SMSW witness, not a benchmark or a guest-state injection.
 * MODE=0(real)/1(protected CPL0), ADDR32 and OP32 select effective sizes.
 * OFFSET covers aligned/unaligned, word, cache-line and page boundaries;
 * paging is OFF in this first-stage witness. BASE=0/0x2000 checks relocation.
 * CONTROL=1 replaces memory SMSW with ordinary MOV of the expected CR0 word;
 * it is a fixture/control test, NEVER SMSW correctness evidence.
 */
#if (MODE != 0 && MODE != 1) || (ADDR32 != 0 && ADDR32 != 1) || (OP32 != 0 && OP32 != 1)
#error Invalid SMSW fixture mode
#endif
    .set DST, 0x4000 + OFFSET
    .set CR0_VALUE, 0x6000001a + MODE
    .section .text16, "ax"
    .code16
    .global _start16, fail16
_start16:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ss
    movw %ax, %ds
    movw %ax, %es
    movl $0x9000, %esp
    /* Fail loudly on #UD instead of falling through the default zero IVT. */
    movw $fail16_off, 6*4
    movw $0xf000, 6*4+2
    movl $CR0_VALUE-MODE, %eax
    movl %eax, %cr0
#if MODE
    movl $0, 0x500
    movl $0, 0x504
    movl $0x0000ffff, 0x508
    movl $0x00cf9a00, 0x50c
    movl $0x0000ffff, 0x510
    movl $0x00cf9200, 0x514
    movl $(0xffff | (BASE << 16)), 0x518
    movl $0x00409200, 0x51c
    movw $0x1f, 0x480
    movl $0x500, 0x482
    lgdt 0x480
    movl $CR0_VALUE, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long pm_entry
    .word 8
#else
    movw $(BASE >> 4), %ax
    movw %ax, %ds
    jmp test_body
#endif
fail16:
    movb $0x43, %al
    outb %al, $0xf4
    hlt
    jmp fail16

#if MODE
    .section .text32, "ax"
    .code32
pm_entry:
    movw $0x10, %ax
    movw %ax, %ss
    movw %ax, %es
    movw $0x18, %ax
    movw %ax, %ds
    /* A #UD at the tested instruction returns a distinguishable failure. */
    movl $fail, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, %es:0x600+6*8
    movl $fail, %eax
    andl $0xffff0000, %eax
    orl $0x8e00, %eax
    movl %eax, %es:0x600+6*8+4
    movw $0x7f, %es:0x490
    movl $0x600, %es:0x492
    lidt %es:0x490
#endif
test_body:
    movl $0xa5a5a5a5, DST-2
    movl $0xa5a5a5a5, DST+2
    /* Separate expected data from the instruction-under-test encoding. */
    movl $0x12340000 + (CR0_VALUE & 0xffff), %eax
    movl $0x3ff0, %ebx
    movl $0x22334455, %ecx
    movl $0x33445566, %edx
    movl $0x44556677, %ebp
    movl $8 + OFFSET, %esi
    movl $0x66778899, %edi
    pushl $0x8d7
    popfl
    .global smsw_probe, smsw_after
smsw_probe:
#if CONTROL
    movw %ax, DST
#else
#if OP32 != MODE
    .byte 0x66
#endif
#if ADDR32 != MODE
    .byte 0x67
#endif
#if ADDR32
    /* [EBX+ESI+8], SIB without scaling: the same target as BX+SI+8. */
    .byte 0x0f, 0x01, 0x64, 0x33, 0x08
#else
    .byte 0x0f, 0x01, 0x60, 0x08
#endif
#endif
smsw_after:
    pushfl
    pushal
    /* Save first; comparisons must not hide a changed architectural flag. */
    cmpl $0x12340000 + (CR0_VALUE & 0xffff), %eax
    jne fail
    cmpl $0x3ff0, %ebx
    jne fail
    cmpl $0x22334455, %ecx
    jne fail
    cmpl $0x33445566, %edx
    jne fail
    cmpl $0x44556677, %ebp
    jne fail
    cmpl $8 + OFFSET, %esi
    jne fail
    cmpl $0x66778899, %edi
    jne fail
    cmpl $0x8fdc, %esp
    jne fail
    /* Use SS explicitly: DS can be relocated and BP addressing implies SS. */
    movl %ss:32(%esp), %eax
    andl $0xfd7, %eax
    cmpl $0x8d7, %eax
    jne fail
    cmpw $(CR0_VALUE & 0xffff), DST
    jne fail
    cmpw $0xa5a5, DST-2
    jne fail
    cmpl $0xa5a5a5a5, DST+2
    jne fail
    /* Register control: r16 must preserve the upper half. */
    movl $0xcafe0000, %eax
    smsw %ax
    cmpl $0xcafe0000 + (CR0_VALUE & 0xffff), %eax
    jne fail
    movb $0x42, %al
    jmp do_exit
    .global fail
fail:
    movb $0x43, %al
do_exit:
    outb %al, $0xf4
    hlt
    jmp do_exit

    .section .reset, "ax"
    .code16
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11, 1, 0x90
