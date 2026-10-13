/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Cold-boot, paging-off SMSW at CPL3 or V86 (IOPL=3 for native exit).
 * DS/SS/FS have DIFFERENT bases, so the wrong default/override cannot pass.
 * CONTROL=1 is an ordinary MOV fixture control, not SMSW acceptance.
 */
#if (V86 != 0 && V86 != 1) || SEG < 0 || SEG > 2
#error Invalid privilege fixture
#endif
#define CODE32 (1-V86)
    .set DST, 0x4000 + OFFSET
    .set CR0_VALUE, 0x6000001b
    .section .text16, "ax"
    .code16
    .global _start16
_start16:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x9000, %esp
    /* null, code0, data0, code3, DS3, SS3, FS3, TSS. */
    movl $0, 0x500
    movl $0, 0x504
    movl $0x0000ffff, 0x508
    movl $0x00cf9a00, 0x50c
    movl $0x0000ffff, 0x510
    movl $0x00cf9200, 0x514
    movl $0x0000ffff, 0x518
    movl $0x00cffa00, 0x51c
    movl $0x2000ffff, 0x520
    movl $0x0040f200, 0x524
    movl $0x0000ffff, 0x528
    movl $0x0040f200, 0x52c
    movl $0x6000ffff, 0x530
    movl $0x0040f200, 0x534
    movl $0x30000088, 0x538
    movl $0x00008900, 0x53c
    movw $0x3f, 0x480
    movl $0x500, 0x482
    lgdt 0x480
    movl $CR0_VALUE, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long pm_entry
    .word 8

    .section .text32, "ax"
    .code32
pm_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x18000, %esp
    .set tss_offset, 0
    .rept 26
    movl $0, 0x3000+tss_offset
    .set tss_offset, tss_offset+4
    .endr
    movl $0x16000, 0x3004
    movl $0x10, 0x3008
    movw $0x68, 0x3066
    /* V86 I/O checks the TSS bitmap even with IOPL=3. Permit ONLY the
     * byte-wide native debug-exit port; everything else stays denied. */
    .set io_offset, 0
    .rept 8
    movl $0xffffffff, 0x3068+io_offset
    .set io_offset, io_offset+4
    .endr
    movb $0xef, 0x3086
    movb $0xff, 0x3088
    movw $0x38, %ax
    ltr %ax
    .macro gate vector, target, attrs
    movl $\target, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0x1000+8*\vector
    movl $\target, %eax
    andl $0xffff0000, %eax
    orl $\attrs, %eax
    movl %eax, 0x1000+8*\vector+4
    .endm
    gate 6, fail0, 0x8e00
    gate 12, fail0, 0x8e00
    gate 13, fail0, 0x8e00
    gate 0x40, exit0, 0xee00
    movw $0x207, 0x490
    movl $0x1000, 0x492
    lidt 0x490
#if V86
    pushl $0
    pushl $0x600
    pushl $0x200
    pushl $0
    pushl $0
    pushl $0x9000
    pushl $0x23002
    pushl $0xf000
    pushl $user_entry_off
#else
    movw $0x23, %ax
    movw %ax, %ds
    movw $0x33, %ax
    movw %ax, %fs
    pushl $0x2b
    pushl $0x9000
    pushl $2
    pushl $0x1b
    pushl $user_entry
#endif
    iret
fail0:
    movb $0x43, %al
exit0:
    outb %al, $0xf4
    hlt
    jmp exit0

    .section .textuser, "ax"
#if V86
    .code16
#else
    .code32
#endif
    .global user_entry, smsw_probe, smsw_after
user_entry:
    .macro fill segment
    movl $0xa5a5a5a5, %\segment:DST-2
    movl $0xa5a5a5a5, %\segment:DST+2
    .endm
    fill ds
    fill ss
    fill fs
    movl $0x1234001b, %eax
    movl $0x3ff0, %ebx
    movl $0x22334455, %ecx
    movl $0x33445566, %edx
    movl $0x3ff0, %ebp
    movl $8+OFFSET, %esi
    movl $0x66778899, %edi
    pushl $(0x8d7 + V86*0x3000)
    popfl
smsw_probe:
#if CONTROL
#if SEG == 0
    movw %ax, %ds:DST
#elif SEG == 1
    movw %ax, %ss:DST
#else
    movw %ax, %fs:DST
#endif
#else
#if SEG == 2
    .byte 0x64
#endif
#if OP32 != CODE32
    .byte 0x66
#endif
#if ADDR32 != CODE32
    .byte 0x67
#endif
#if ADDR32
    /* DS/FS: EBX+ESI+8. Default SS: EBP+ESI+8. */
#if SEG == 1
    .byte 0x0f, 0x01, 0x64, 0x35, 0x08
#else
    .byte 0x0f, 0x01, 0x64, 0x33, 0x08
#endif
#else
    /* DS/FS: BX+SI+8. Default SS: BP+SI+8. */
#if SEG == 1
    .byte 0x0f, 0x01, 0x62, 0x08
#else
    .byte 0x0f, 0x01, 0x60, 0x08
#endif
#endif
#endif
smsw_after:
    pushfl
    pushal
    cmpl $0x1234001b, %eax
    jne fail
    cmpl $0x3ff0, %ebx
    jne fail
    cmpl $0x22334455, %ecx
    jne fail
    cmpl $0x33445566, %edx
    jne fail
    cmpl $0x3ff0, %ebp
    jne fail
    cmpl $8+OFFSET, %esi
    jne fail
    cmpl $0x66778899, %edi
    jne fail
    cmpl $0x8fdc, %esp
    jne fail
    movl %ss:32(%esp), %eax
    andl $0x3fd7, %eax
    cmpl $(0x8d7 + V86*0x3000), %eax
    jne fail
    .macro check segment, expected
    cmpw $\expected, %\segment:DST
    jne fail
    cmpw $0xa5a5, %\segment:DST-2
    jne fail
    cmpl $0xa5a5a5a5, %\segment:DST+2
    jne fail
    .endm
#if SEG == 0
    check ds, 0x1b
#else
    check ds, 0xa5a5
#endif
#if SEG == 1
    check ss, 0x1b
#else
    check ss, 0xa5a5
#endif
#if SEG == 2
    check fs, 0x1b
#else
    check fs, 0xa5a5
#endif
    movl $0xcafe0000, %eax
    smsw %ax
    cmpl $0xcafe001b, %eax
    jne fail
    movl $0xdeadbeef, %eax
    smsw %eax
    cmpl $CR0_VALUE, %eax
    jne fail
    movb $0x42, %al
    jmp do_exit
fail:
    movb $0x43, %al
do_exit:
#if V86
    outb %al, $0xf4
#else
    int $0x40
#endif
    jmp do_exit

    .section .reset, "ax"
    .code16
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11, 1, 0x90
