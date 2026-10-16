/* Cold real-mode nested INT/IRET: real IVT reads, stack frames and flags. */
    .code16
    .section .text,"ax"
    .global _start
_start:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw $0x8000,%sp
    movw $outer_off,0x0180
    movw $0xf000,0x0182
    movw $inner_off,0x0184
    movw $0xf000,0x0186
    movw $0x1234,%ax
    movw $0x2000,%bx
    movw $0x3000,%cx
    stc
    int $0x60
    jnc fail
    cmpw $0x2001,%bx
    jne fail
    cmpw $0x3001,%cx
    jne fail
    cmpw $0x8000,%sp
    jne fail
    cmpw $0x1234,%ax
    jne fail
    movw $0x42,%ax
    jmp done
fail:
    movw $0x43,%ax
done:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
outer:
    incw %bx
    clc
    int $0x61
    iret
inner:
    incw %cx
    stc
    iret
    .section .reset,"ax"
    ljmp $0xf000,$start_off
