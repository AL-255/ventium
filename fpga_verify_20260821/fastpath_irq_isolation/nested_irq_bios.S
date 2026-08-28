/* Focused live-silicon diagnostic for the conservative VEN_SYS_FASTPATH
 * interrupt-acceptance seam. This is test firmware, not synthesizable RTL.
 *
 * Each INT 13h handler deliberately waits with IF clear until IRQ0 is pending,
 * executes STI plus one shadowed instruction, accepts the nested IRQ0, then
 * returns. The mainline verifies that the nested return restored SS:SP and that
 * every software interrupt completed. Low-RAM counters start at 0000:0500.
 */

    .equ COM1_THR, 0x03F8
    .equ COM1_DLL, 0x03F8
    .equ COM1_DLM, 0x03F9
    .equ COM1_LCR, 0x03FB
    .equ COM1_MCR, 0x03FC

    .equ IRQ_COUNT, 0x0500
    .equ SW_ENTER,  0x0502
    .equ SW_RETURN, 0x0504
    .equ NEST_COUNT,0x0506
    .equ BAD_COUNT, 0x0508
    .equ SW_ACTIVE, 0x050A
    .equ POP_RETURN,0x050C
    .equ POP_BAD,   0x050E
    .equ POP_ACTIVE,0x0510
    .equ POP_NEST,  0x0512
    .equ MAIN_BAD,  0x0514
    .equ MAIN_AX,   0x0516
    .equ MAIN_CX,   0x0518
    .equ MAIN_ES,   0x051A
    .equ MAIN_SP,   0x051C
    .equ ITERATIONS, 256

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    $0x7000, %sp
    movw    %ax, %es
    movw    $0xF000, %ax
    movw    %ax, %ds

#ifdef CLEAR_CD_NW
    /*
     * Silicon discriminator only: force ordinary cacheable RAM traffic after
     * reset.  The acceptance ROM omits this block and therefore keeps the P5
     * reset CR0.CD/NW state, exercising ven_l1d's narrow bypass path.  Building
     * with -DCLEAR_CD_NW routes the identical IRQ/IRET program through cacheable
     * line fills, separating a remaining core handoff error from the HP0 narrow-
     * response replay workaround.  Do not use this variant as acceptance proof.
     */
    movl    %cr0, %eax
    andl    $0x9FFFFFFF, %eax
    movl    %eax, %cr0
#endif

    /* IVT[8] = IRQ0; IVT[13h] = the software handler under test. */
    movw    $irq0_off, %bx
    movw    %bx, %es:0x0020
    movw    $0xF000, %bx
    movw    %bx, %es:0x0022
    movw    $soft13_off, %bx
    movw    %bx, %es:0x004C
    movw    $0xF000, %bx
    movw    %bx, %es:0x004E

    xorw    %bx, %bx
    movw    %bx, %es:IRQ_COUNT
    movw    %bx, %es:SW_ENTER
    movw    %bx, %es:SW_RETURN
    movw    %bx, %es:NEST_COUNT
    movw    %bx, %es:BAD_COUNT
    movw    %bx, %es:SW_ACTIVE
    movw    %bx, %es:POP_RETURN
    movw    %bx, %es:POP_BAD
    movw    %bx, %es:POP_ACTIVE
    movw    %bx, %es:POP_NEST
    movw    %bx, %es:MAIN_BAD
    movw    %bx, %es:MAIN_AX
    movw    %bx, %es:MAIN_CX
    movw    %bx, %es:MAIN_ES
    movw    %bx, %es:MAIN_SP

    /* COM1: 115200 8N1. */
    movw    $COM1_LCR, %dx; movb $0x83, %al; outb %al, %dx
    movw    $COM1_DLL, %dx; movb $0x01, %al; outb %al, %dx
    movw    $COM1_DLM, %dx; movb $0x00, %al; outb %al, %dx
    movw    $COM1_LCR, %dx; movb $0x03, %al; outb %al, %dx
    movw    $COM1_MCR, %dx; movb $0x03, %al; outb %al, %dx

    /* Master/slave 8259: legacy vectors, only IRQ0 unmasked. */
    movw    $0x20, %dx; movb $0x11, %al; outb %al, %dx
    movw    $0x21, %dx; movb $0x08, %al; outb %al, %dx
    movb    $0x04, %al; outb %al, %dx
    movb    $0x01, %al; outb %al, %dx
    movb    $0xFE, %al; outb %al, %dx
    movw    $0xA0, %dx; movb $0x11, %al; outb %al, %dx
    movw    $0xA1, %dx; movb $0x70, %al; outb %al, %dx
    movb    $0x02, %al; outb %al, %dx
    movb    $0x01, %al; outb %al, %dx
    movb    $0xFF, %al; outb %al, %dx

    /* PIT mode 2, divisor 0400h (~1.165 kHz). */
    movw    $0x43, %dx; movb $0x34, %al; outb %al, %dx
    movw    $0x40, %dx; movb $0x00, %al; outb %al, %dx
    movb    $0x04, %al; outb %al, %dx

    movw    $COM1_THR, %dx
    movb    $'A', %al
    outb    %al, %dx

    sti
    nop
.main_loop:
    xorw    %ax, %ax
    movw    %ax, %es
    movw    $0xA55A, %ax
    movw    $0x5AA5, %cx
    int     $0x13
    cmpw    $0xA55A, %ax
    jne     .main_reg_bad
    cmpw    $0x5AA5, %cx
    jne     .main_reg_bad
    movw    %es, %dx
    cmpw    $0, %dx
    jne     .main_reg_bad
    cmpw    $0x7000, %sp
    je      1f
    incw    %es:BAD_COUNT
    movw    $0x7000, %sp
1:
    cmpw    $0, %es:SW_ACTIVE
    je      2f
    incw    %es:BAD_COUNT
    movw    $0, %es:SW_ACTIVE
2:
    cmpw    $ITERATIONS, %es:SW_RETURN
    jb      .main_loop

    cmpw    $0, %es:BAD_COUNT
    jne     .fail
    cmpw    $ITERATIONS, %es:SW_ENTER
    jne     .fail
    /* Require nested IRQ delivery on at least half the iterations. */
    cmpw    $(ITERATIONS / 2), %es:NEST_COUNT
    jb      .fail

    /* Phase 2: reproduce the VGA-ROM tail at C000:1D66 exactly enough to
     * exercise the ordering seam: STI; POP DX (shadow); POP AX; RET. IRQ0 is
     * made pending while IF=0 before every invocation. */
    cli
    movw    $0, %es:POP_RETURN
    movw    $0, %es:POP_BAD
    movw    $0, %es:POP_ACTIVE
    movw    $0, %es:POP_NEST
.pop_loop:
    cli
    movw    $0x1234, %ax
    movw    $0x5678, %dx
    call    sti_pop_tail
    cmpw    $0x1234, %ax
    je      5f
    incw    %es:POP_BAD
5:
    cmpw    $0x5678, %dx
    je      6f
    incw    %es:POP_BAD
6:
    cmpw    $0x7000, %sp
    je      7f
    incw    %es:POP_BAD
    movw    $0x7000, %sp
7:
    cmpw    $1, %es:POP_ACTIVE
    je      8f
    incw    %es:POP_BAD
8:
    movw    $0, %es:POP_ACTIVE
    incw    %es:POP_RETURN
    cmpw    $ITERATIONS, %es:POP_RETURN
    jb      .pop_loop
    cmpw    $0, %es:POP_BAD
    jne     .fail
    cmpw    $(ITERATIONS / 2), %es:POP_NEST
    jb      .fail

    movw    $COM1_THR, %dx
    movb    $'S', %al
    outb    %al, %dx
    movw    $0xF4, %dx
    movb    $0x42, %al
    outb    %al, %dx
    jmp     .park

.main_reg_bad:
    movw    %es, %dx
    xorw    %bx, %bx
    movw    %bx, %es
    incw    %es:MAIN_BAD
    movw    %ax, %es:MAIN_AX
    movw    %cx, %es:MAIN_CX
    movw    %dx, %es:MAIN_ES
    movw    %sp, %es:MAIN_SP
    jmp     .fail

.fail:
    movw    $COM1_THR, %dx
    movb    $'F', %al
    outb    %al, %dx
    movw    $0xF4, %dx
    movb    $0x43, %al
    outb    %al, %dx
.park:
    cli
    hlt
    jmp     .park

    /* Software INT 13h. INT entered with IF clear. The delay guarantees an
     * IRQ0 is pending before STI; CMP is the one shadowed instruction. */
    .global soft13
soft13:
    pushw   %ax
    pushw   %cx
    pushw   %es
    xorw    %ax, %ax
    movw    %ax, %es
    movw    $1, %es:SW_ACTIVE
    incw    %es:SW_ENTER
    movw    $1024, %cx
3:
    nop
    loop    3b
    sti
    cmpw    $1, %es:SW_ACTIVE
    cli
    movw    $0, %es:SW_ACTIVE
    incw    %es:SW_RETURN
    popw    %es
    popw    %cx
    popw    %ax
    iret

    /* VGA C000:1D4B-style subroutine tail. POP DX is the STI-shadowed
     * instruction; a pending IRQ is accepted before POP AX. */
sti_pop_tail:
    pushw   %ax
    pushw   %dx
    pushw   %cx
    cli
    movw    $1, %es:POP_ACTIVE
    movw    $1024, %cx
5:
    nop
    loop    5b
    popw    %cx
    sti
    popw    %dx
    popw    %ax
    ret

    /* IRQ0 handler. IF remains clear, so IRQ0 cannot recursively nest. */
    .global irq0
irq0:
    pushw   %ax
    pushw   %dx
    pushw   %es
    xorw    %ax, %ax
    movw    %ax, %es
    incw    %es:IRQ_COUNT
    cmpw    $0, %es:SW_ACTIVE
    je      9f
    incw    %es:NEST_COUNT
9:
    cmpw    $0, %es:POP_ACTIVE
    je      10f
    incw    %es:POP_NEST
10:
    movw    $0x20, %dx
    movb    $0x20, %al
    outb    %al, %dx
    popw    %es
    popw    %dx
    popw    %ax
    iret

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
