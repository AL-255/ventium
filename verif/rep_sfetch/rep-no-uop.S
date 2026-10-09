/* Cold system-mode REP checks. No injected state or workload addresses.
 * The hot RAM command straddles an I line/page when OFFSET is 31/4095. */
#ifndef OFFSET
#define OFFSET 17
#endif
#ifndef STATIC_STOS
#define STATIC_STOS 0
#endif
    .set TARGET,0x8000+OFFSET
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
    movw $0x17,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    andl $0x9fffffff,%eax          /* enable ordinary caches: clear CD/NW */
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm32
    .word 8
    .code32
    .section .text32,"ax"
pm32:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x90000,%esp
    movb $0xf3,TARGET
    movb $0xa5,TARGET+1
    movb $0xc3,TARGET+2
#if STATIC_STOS
    movb $0xf3,TARGET+8
    movb $0xab,TARGET+9
    movb $0xc3,TARGET+10
#endif
    movl $TARGET,%ebp
    movl $0x2000,%edi
    movl $0x12345678,%eax
    movl $32,%ecx
init:
    movl %eax,(%edi)
    addl $0x01020304,%eax
    addl $4,%edi
    loop init
    movl $0x2000,%esi
    movl $0x3000,%edi
    movl $32,%ecx
    call *%ebp
    movl $0x2000,%esi
    movl $0x3000,%edi
    movl $32,%ecx
    call *%ebp
    cmpl $0x2080,%esi
    jne fail
    cmpl $0x3080,%edi
    jne fail
    testl %ecx,%ecx
    jne fail
    std
    movl $0x207c,%esi
    movl $0x307c,%edi
    movl $32,%ecx
    call *%ebp
    cld
    cmpl $0x1ffc,%esi
    jne fail
    cmpl $0x2ffc,%edi
    jne fail
    movl $0x3000,%esi
    movl $0x3000,%edi
    movl $32,%ecx
    call *%ebp
    movl $0x2000,%esi
    movl $0x3000,%edi
    movl $32,%ecx
check_nonuniform:
    movl (%esi),%eax
    cmpl (%edi),%eax
    jne fail
    addl $4,%esi
    addl $4,%edi
    loop check_nonuniform
    /* Overlap must propagate the preceding store, not pre-read a future
     * source before the older element has acknowledged. */
    movl $0x2000,%esi
    movl $0x2004,%edi
    movl $31,%ecx
    call *%ebp
    movl $0x2000,%edi
    movl $32,%ecx
check_forward:
    cmpl $0x12345678,(%edi)
    jne fail
    addl $4,%edi
    loop check_forward
    movl $0x87654321,0x207c
    std
    movl $0x207c,%esi
    movl $0x2078,%edi
    movl $31,%ecx
    call *%ebp
    cld
    movl $0x2000,%edi
    movl $32,%ecx
check_backward:
    cmpl $0x87654321,(%edi)
    jne fail
    addl $4,%edi
    loop check_backward
    /* Misaligned source/destination cross different page boundaries. */
    movl $0x01020304,0x4ffd
    movl $0x11223344,0x5001
    movl $0x55667788,0x5005
    movl $0x4ffd,%esi
    movl $0x5ffe,%edi
    movl $3,%ecx
    call *%ebp
    cmpl $0x01020304,0x5ffe
    jne fail
    cmpl $0x11223344,0x6002
    jne fail
    cmpl $0x55667788,0x6006
    jne fail
    xorl %esi,%esi
    movl $0xffffffff,%edi
    xorl %ecx,%ecx
    stc
    call *%ebp
    jnc fail
    cmpl $0xffffffff,%edi
    jne fail
    testl %esi,%esi
    jne fail
    /* Ordinary CPU-store SMC changes the retained RAM command to STOSD.
     * Refill/redecode must observe it after the control transfer. */
#if STATIC_STOS
    /* Independent static page-crossing case; the dynamic second-page SMC
     * case is retained separately because free-running QEMU disagrees with
     * its own single-step execution on that case. */
    movl $TARGET+8,%ebp
#else
    movb $0xab,TARGET+1
#endif
    movl $0xcafebabe,%eax
    movl $0x3000,%edi
    movl $32,%ecx
    call *%ebp
    movl $0x3000,%edi
    movl $32,%ecx
check_stos:
    cmpl $0xcafebabe,(%edi)
    jne fail
    addl $4,%edi
    loop check_stos
    /* Unsupported shapes retain ordinary decoding and partial-register
     * semantics. Upper ECX/ESI/EDI must survive addr16 zero count. */
    movl $0x12340000,%ecx
    movl $0x5678ffff,%esi
    movl $0x9abcffff,%edi
    .global fallback_addr16
fallback_addr16:
    .byte 0x67,0xf3,0xa5
    cmpl $0x12340000,%ecx
    jne fail
    cmpl $0x5678ffff,%esi
    jne fail
    cmpl $0x9abcffff,%edi
    jne fail
    movl $0x2000,%esi
    movl $0x3000,%edi
    movl $3,%ecx
    .global fallback_word
fallback_word:
    rep movsw
    cmpl $0x2006,%esi
    jne fail
    cmpl $0x3006,%edi
    jne fail
    movl $0x2000,%esi
    movl $0x3000,%edi
    movl $3,%ecx
    .global fallback_byte
fallback_byte:
    rep movsb
    cmpl $0x2003,%esi
    jne fail
    cmpl $0x3003,%edi
    jne fail
    /* An actual U/V pair, independent of REP path admission. */
    movl $3,%ecx
    .global pair_u,pair_v,hot_op
    .set hot_op,TARGET
    .balign 32
pair_u:
    movl $0x12345678,%ebx
pair_v:
    movl $0x87654321,%edi
    decl %ecx
    jnz pair_u
    movb $0x42,%al
    jmp exit
fail:
    movb $0x43,%al
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
