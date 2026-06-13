    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld; xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw $0x7000,%sp
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx
    fninit
    movl $1234, %ebx
    movl %ebx, 0x600            /* mem = 1234 */
    fildl 0x600                 /* st0 = 1234.0 */
    fld1
    faddp %st,%st(1)            /* st0 = 1235.0 */
    fistpl 0x604                /* store int -> 0x604 (expect 1235=0x4d3) */
    movl 0x604, %ebp           /* read FP result */
    fildl 0x600
    fbstp 0x610                 /* BCD of 1234 -> 0x610 (expect 34 12 00..) */
    movl 0x610, %esi           /* read BCD low dword (expect 0x00001234) */
    /* print "F=" hex(ebp) " B=" hex(esi) */
    movw $0x03F8,%dx; movb $'F',%al; outb %al,%dx; movb $'=',%al; outb %al,%dx
    movl %ebp,%eax; call phex
    movb $' ',%al; outb %al,%dx; movb $'B',%al; outb %al,%dx; movb $'=',%al; outb %al,%dx
    movl %esi,%eax; call phex
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b
phex:
    movw $8,%cx
1:  roll $4,%eax; movb %al,%bl; andb $0x0F,%bl; cmpb $10,%bl; jb 2f; addb $87,%bl; jmp 3f
2:  addb $48,%bl
3:  pushw %ax; movb %bl,%al; movw $0x03F8,%dx; outb %al,%dx; popw %ax; decw %cx; jnz 1b
    ret
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
