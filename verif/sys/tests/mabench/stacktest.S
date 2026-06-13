    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw %ax,%es; movw $0x7000,%sp
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx
    /* mirror call/ret's EXACT stack usage WITHOUT control flow:
       outer push (= the return addr CALL pushes), then sub's body
       (push ax / out 'A' / pop ax), then outer pop (= what RET reads). */
    movw $0x1234, %bx
    pushw %bx                 /* outer push -> [SP]=0x1234 (like CALL's ret-addr) */
    pushw %ax                 /* sub: push ax */
    movw $0x03F8,%dx; movb $'A',%al; outb %al,%dx   /* sub: out 'A' */
    popw %ax                  /* sub: pop ax */
    popw %cx                  /* outer pop -> CX should be 0x1234 (what RET reads) */
    /* print "P=" hex(cx) */
    movw $0x03F8,%dx; movb $'P',%al; outb %al,%dx; movb $'=',%al; outb %al,%dx
    movw %cx, %ax
    movw $4, %cx
1:  rolw $4, %ax; movb %al, %bl; andb $0x0F, %bl; cmpb $10, %bl; jb 2f; addb $87,%bl; jmp 3f
2:  addb $48, %bl
3:  pushw %ax; movb %bl,%al; movw $0x03F8,%dx; outb %al,%dx; popw %ax; decw %cx; jnz 1b
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
