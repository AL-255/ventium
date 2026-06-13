/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * xwordtest.S — L1/AXI CROSS-WORD store coherency probe (real-mode -bios).
 *
 * The P2b bug: a store whose bytes straddle a 32-bit word boundary (an UNALIGNED
 * 16/32-bit store — e.g. a dword at an odd address) must be issued to DDR as TWO
 * AXI word-beats (word A + word A+4). The original ven_axi_master shifted the store
 * into one beat and silently dropped the bytes that spilled past lane 3, corrupting
 * DDR. SeaBIOS POST does these stores; on silicon the corruption cascaded into the
 * memset(0xc0000) infinite loop. tb_soc's byte-addressed BFM masked it.
 *
 * This test writes a position-tagged 32-bit pattern at ODD addresses (offset 1 ->
 * every store straddles a word) across a 60 KiB region (>> the ~8 KiB L1 D-cache, so
 * the dirty cross-word lines are EVICTED to DDR), then reads them all back (re-filled
 * from DDR). A mis-placed beat-B byte shows up as a read-back mismatch -> "XBAD".
 * A clean run prints "XOK". The high byte 0x5A of each pattern lives in beat B, the
 * low bytes (the position tag) in beat A, so both halves of the split are checked.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw $0x7000,%sp
    /* COM1 8N1 */
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx

    movw $0x2000, %ax; movw %ax, %es     /* region phys 0x20000.. */

    /* PASS 1: 32-bit store of (0x5A000000 | di) at es:di, di odd (cross-word) */
    movw $1, %di
w1:
    movzwl %di, %eax
    orl  $0x5A000000, %eax
    movl %eax, %es:(%di)                 /* unaligned 4-byte store -> 2 word beats */
    addw $8, %di
    cmpw $0xF000, %di
    jb   w1

    /* PASS 2: read back + verify (re-fills from DDR; checks the backing write) */
    movw $1, %di
r1:
    movzwl %di, %ebx
    orl  $0x5A000000, %ebx               /* expected */
    movl %es:(%di), %eax                  /* actual */
    cmpl %ebx, %eax
    jne  xbad
    addw $8, %di
    cmpw $0xF000, %di
    jb   r1

    /* all match -> "XOK\r\n" */
    movw $0x03F8,%dx
    movb $'X',%al; outb %al,%dx
    movb $'O',%al; outb %al,%dx
    movb $'K',%al; outb %al,%dx
    movb $13,%al;  outb %al,%dx
    movb $10,%al;  outb %al,%dx
    jmp done

xbad:
    /* "XBAD " hex16(di) " " hex16(eax_hi) hex16(eax_lo) "\r\n" */
    movl %eax, %ebp                        /* stash actual */
    movw $0x03F8,%dx
    movb $'X',%al; outb %al,%dx
    movb $'B',%al; outb %al,%dx
    movb $'A',%al; outb %al,%dx
    movb $'D',%al; outb %al,%dx
    movb $' ',%al; outb %al,%dx
    movw %di, %ax;  call puthex16          /* offset that failed */
    movb $' ',%al; movw $0x03F8,%dx; outb %al,%dx
    movl %ebp, %eax; shrl $16, %eax; call puthex16   /* actual high word */
    movl %ebp, %eax; call puthex16                    /* actual low word */
    movw $0x03F8,%dx
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx

done:
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b

/* print AX as 4 hex digits to COM1 (clobbers AX,BX,CX,DX) */
puthex16:
    movw $4, %cx
1:  rolw $4, %ax
    movb %al, %bl; andb $0x0F, %bl
    cmpb $10, %bl; jb 2f; addb $87,%bl; jmp 3f
2:  addb $48, %bl
3:  pushw %ax; movb %bl,%al; movw $0x03F8,%dx; outb %al,%dx; popw %ax
    decw %cx; jnz 1b
    ret

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
