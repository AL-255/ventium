/* Diagnostic FreeDOS TSR: replace real-mode IRQ0 with a minimal BIOS tick.
 * It updates the BDA tick counter, handles the once-per-day rollover, sends
 * master-PIC EOI, and returns.  This avoids the prohibitively long DOS/DPMI
 * IRQ0 chain at a 3.125 MHz FPGA clock while retaining time progression.
 */
.code16
.global _start
_start:
    cli
    xorw %ax, %ax
    movw %ax, %es
    movw $tick_handler, %es:0x20
    movw %cs, %ax
    movw %ax, %es:0x22
    sti

    /* DOS terminate-and-stay-resident. DX includes the 0x100-byte PSP. */
    /* Keep 0x20 paragraphs (512 bytes), including the PSP.  This explicit
     * constant avoids a non-absolute relocation in the flat .COM link. */
    movw $0x20, %dx
    movw $0x3100, %ax
    int  $0x21

tick_handler:
    pushw %ax
    pushw %ds
    xorw  %ax, %ax
    movw  %ax, %ds
    addw  $1, 0x046c
    adcw  $0, 0x046e
    /* 0x1800b0 ticks per day: reset count and set midnight flag. */
    cmpw  $0x0018, 0x046e
    jne   1f
    cmpw  $0x00b0, 0x046c
    jb    1f
    movw  $0, 0x046c
    movw  $0, 0x046e
    movb  $1, 0x0470
1:
    movb  $0x20, %al
    outb  %al, $0x20
    popw  %ds
    popw  %ax
    iret
resident_end:
