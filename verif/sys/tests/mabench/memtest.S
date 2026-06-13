/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * memtest.S — L1/AXI byte-memset write-back coherency probe (real-mode -bios).
 *
 * Mirrors the SeaBIOS POST pattern that hangs on the deployed KV260 bitstream:
 * a large region is filled, then zeroed BYTE-AT-A-TIME with a descending index
 * (`for(i=N-1;i>=0;i--) base[i]=0`), then read back. The region (60 KiB) is far
 * larger than the L1 D-cache (~4-8 KiB), so the zeroing forces many dirty-line
 * write-backs through ven_axi_master. If a write-back mis-places byte lanes (or a
 * read-back reads stale DDR), the read-back sees a non-zero byte -> "MBAD". A
 * clean run prints "MOK". This isolates the SeaBIOS memset(0xc0000) infinite loop.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw $0x7000,%sp
    /* COM1 8N1 115200 */
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx

    /* region: ES = 0x2000 (phys 0x20000), N = 0xF000 bytes (60 KiB) */
    movw $0x2000, %ax; movw %ax, %es

    /* 1. FILL with 0xAA (rep stosb -> es:[di++]) */
    xorw %di,%di
    movw $0xF000, %cx
    movb $0xAA, %al
    rep stosb

    /* 2. ZERO descending, byte-at-a-time: for(bx=N; bx>0;) { bx--; es:[bx]=0; } */
    movw $0xF000, %bx
zloop:
    testw %bx,%bx
    jz zdone
    decw %bx
    movb $0, %es:(%bx)
    jmp zloop
zdone:

    /* 3. READ BACK ascending; first non-zero byte -> BAD */
    xorw %si,%si
rloop:
    movb %es:(%si), %al
    testb %al,%al
    jnz bad
    incw %si
    cmpw $0xF000, %si
    jb rloop

    /* all zero -> "MOK\r\n" */
    movw $0x03F8,%dx
    movb $'M',%al; outb %al,%dx
    movb $'O',%al; outb %al,%dx
    movb $'K',%al; outb %al,%dx
    movb $13,%al;  outb %al,%dx
    movb $10,%al;  outb %al,%dx
    jmp done

bad:
    /* "MBAD " hex(si) " " hex(al) "\r\n" — si=offset, al=stale byte */
    movw %ax, %bp              /* stash the stale byte (low 8) */
    movw $0x03F8,%dx
    movb $'M',%al; outb %al,%dx
    movb $'B',%al; outb %al,%dx
    movb $'A',%al; outb %al,%dx
    movb $'D',%al; outb %al,%dx
    movb $' ',%al; outb %al,%dx
    /* print SI as 4 hex digits */
    movw %si, %ax
    movw $4, %cx
ph1:
    rolw $4, %ax
    movb %al, %bl; andb $0x0F, %bl
    cmpb $10, %bl; jb ph2; addb $87,%bl; jmp ph3
ph2: addb $48, %bl
ph3: pushw %ax; movb %bl,%al; movw $0x03F8,%dx; outb %al,%dx; popw %ax
    decw %cx; jnz ph1
    movb $'=',%al; outb %al,%dx
    /* print stale byte (BP low) as 2 hex digits */
    movw %bp, %ax
    movw $2, %cx
ph4:
    rolb $4, %al
    movb %al, %bl; andb $0x0F, %bl
    cmpb $10, %bl; jb ph5; addb $87,%bl; jmp ph6
ph5: addb $48, %bl
ph6: pushw %ax; movb %bl,%al; movw $0x03F8,%dx; outb %al,%dx; popw %ax
    decw %cx; jnz ph4
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx

done:
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
