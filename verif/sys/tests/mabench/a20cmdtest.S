/* A20 DD/DF: warmed data/executable aliases and D1-to-DF handoff.
 * Software-only witness: no internal state injection or BIOS timing shortcuts.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ss
    movw %ax,%ds
    movw $0x7000,%sp
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    movl %eax,%cr0
    movw $0x3fb,%dx
    movb $0x83,%al
    outb %al,%dx
    movw $0x3f8,%dx
    movb $1,%al
    outb %al,%dx
    movw $0x3fb,%dx
    movb $3,%al
    outb %al,%dx
    movw $0xffff,%ax
    movw %ax,%es
    movw $0x600,%di

    movw $0x1111,0x500
    movw $0x2222,%es:0x510
    movw 0x500,%ax
    call record
    movw %es:0x510,%ax
    call record
    /* Distinct physical snippets: mov ax,imm16; retf. */
    movl $0xcb1111b8,0x6000
    movl $0xcb2222b8,%es:0x6010
    lcall $0xffff,$0x6010
    call record

    movw $0x64,%dx
    movb $0xdd,%al
    outb %al,%dx
    movw %es:0x510,%ax
    call record
    lcall $0xffff,$0x6010
    call record
    movw $0x3333,%es:0x510
    movw 0x500,%ax
    call record

    movw $0x64,%dx
    movb $0xdf,%al
    outb %al,%dx
    movw %es:0x510,%ax
    call record
    lcall $0xffff,$0x6010
    call record
    movw $0x4444,%es:0x510
    movw 0x500,%ax
    call record

    /* Crossing control paths: D1 disables, DF must re-enable. */
    movw $0x64,%dx
    movb $0xd1,%al
    outb %al,%dx
    movw $0x60,%dx
    movb $1,%al                 /* reset deasserted, A20 disabled */
    outb %al,%dx
    movw %es:0x510,%ax
    call record
    movw $0x64,%dx
    movb $0xdf,%al
    outb %al,%dx
    movw %es:0x510,%ax
    call record

    movw $0x3f8,%dx
    movb $'@',%al
    outb %al,%dx
    movw $0x600,%si
    movw $11,%bp
1:  lodsw
    call puthex16
    movb $':',%al
    outb %al,%dx
    decw %bp
    jnz 1b
    movb $10,%al
    outb %al,%dx
    movw $0xf4,%dx
    movb $0x42,%al
    outb %al,%dx
2:  hlt
    jmp 2b

record:
    movw %ax,(%di)              /* DS, not ES (which deliberately stays FFFF) */
    addw $2,%di
    ret
puthex16:
    movw $4,%cx
3:  rolw $4,%ax
    movb %al,%bl
    andb $15,%bl
    cmpb $10,%bl
    jb 4f
    addb $87,%bl
    jmp 5f
4:  addb $48,%bl
5:  pushw %ax
    movb %bl,%al
    outb %al,%dx
    popw %ax
    loop 3b
    ret

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
