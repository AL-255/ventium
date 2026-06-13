    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw $0x7000,%sp
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx
    movb $'S',%al; outb %al,%dx          /* start marker */
    call sub                              /* near CALL/RET x3 */
    call sub
    call sub
    movb $'Z',%al; movw $0x03F8,%dx; outb %al,%dx   /* got past 3 calls */
    /* nested call test */
    call outer
    movb $'Y',%al; movw $0x03F8,%dx; outb %al,%dx
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b
sub:
    pushw %ax
    movw $0x03F8,%dx; movb $'A',%al; outb %al,%dx
    popw %ax
    ret
outer:
    pushw %ax
    movw $0x03F8,%dx; movb $'(',%al; outb %al,%dx
    call sub                              /* nested -> 'A' */
    movb $')',%al; movw $0x03F8,%dx; outb %al,%dx
    popw %ax
    ret
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
