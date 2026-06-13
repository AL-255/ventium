    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw $0x7000,%sp
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03F9,%dx; movb $0x00,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $'1',%al; outb %al,%dx
    fninit                          /* FNINIT — no FWAIT prefix */
    movw $0x03F8,%dx; movb $'2',%al; outb %al,%dx
    fldz                            /* a real x87 op */
    movw $0x03F8,%dx; movb $'3',%al; outb %al,%dx
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
1:  hlt; jmp 1b
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
