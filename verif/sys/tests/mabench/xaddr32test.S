/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * xaddr32test.S — real-mode 32-bit-ADDRESSING (0x67) memory probe through L1/AXI.
 *
 * SeaBIOS's IRQ "extra stack" trampoline saves/restores the interrupt frame +
 * registers to a struct via addr32 operands (mov ds,[eax]; push dword [eax+0x1c];
 * mov es,[eax+2]) while in REAL mode. The FreeDOS boot derails when that trampoline
 * IRETs a corrupt frame (cs=0) — and the L1/AXI path is the only difference from the
 * direct-mem build that boots. xwordtest already proved unaligned + cross-LINE 16-bit-
 * addressed accesses are byte-correct; what it did NOT exercise is addr32 (eax-based,
 * 32-bit displacement) accesses in real mode. This isolates that path.
 *
 * Three phases, all using addr32 (0x67) operands, NON-overlapping addresses:
 *   1. ALIGNED span: 64 dwords spaced 1 KiB apart over 64 KiB (>> L1) — forces dirty
 *      line writeback, then read back from DDR. Tests addr32 EA + the cached path.
 *   2. UNALIGNED + CROSS-LINE: addr32 dword stores at byte offsets that straddle a
 *      32-byte cache line, read back.
 *   3. addr32 16-bit (selector-style) store/load — what `mov es,[eax+2]` reduces to.
 * On any mismatch: print "Bn=" (n=phase) then the full 32-bit value read back, so the
 * failing case + actual bytes are visible. All pass -> "AOK".
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw %ax,%es; movw $0x7000,%sp
    /* COM1 8N1 */
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx

/* ---- Phase 1: addr32 ALIGNED dword span over 64 KiB (forces writeback) ---- */
    movl $0x00020000, %eax       /* running linear addr (addr32 base) */
    movl $0xA5A50000, %ebx       /* tag base */
    movw $64, %cx
1:  movl %ebx, (%eax)            /* addr32 store [eax] = tag */
    addl $0x400, %eax            /* +1 KiB */
    addl $1, %ebx
    decw %cx
    jnz 1b
    /* read back */
    movl $0x00020000, %eax
    movl $0xA5A50000, %ebx
    movw $64, %cx
2:  movl (%eax), %edx           /* addr32 load */
    cmpl %ebx, %edx
    jne bad1
    addl $0x400, %eax
    addl $1, %ebx
    decw %cx
    jnz 2b

/* ---- Phase 2: addr32 UNALIGNED + CROSS-LINE dword stores ---- */
    /* fresh region 0x40000. write each, then a second pass reads them all back
       (the writes are >32B apart so they don't overlap; the 64 KiB phase-1 span
       already evicted L1, so these go to fresh lines). */
    movl $0x00040000, %eax
    movl $0x11223344, %ebx
    movl %ebx, 2(%eax)          /* unaligned: [0x40002..0x40005] straddles a word */
    movl $0x55667788, %ebx
    movl %ebx, 0x1e(%eax)       /* cross-LINE: [0x4001e..0x40021] straddles 32B line */
    movl $0x99AABBCC, %ebx
    movl %ebx, 0x3d(%eax)       /* unaligned + cross-line: [0x4003d..0x40040] */
    /* read back */
    movl 2(%eax), %edx;    movl $0x11223344, %ebx; cmpl %ebx, %edx; jne bad2
    movl 0x1e(%eax), %edx; movl $0x55667788, %ebx; cmpl %ebx, %edx; jne bad2
    movl 0x3d(%eax), %edx; movl $0x99AABBCC, %ebx; cmpl %ebx, %edx; jne bad2

/* ---- Phase 3: addr32 16-bit (selector-style) store/load ---- */
    movl $0x00060000, %eax
    movw $0xF000, (%eax)        /* addr32 16-bit store (a CS selector value) */
    movw $0x1234, 2(%eax)
    movw (%eax), %si            /* addr32 16-bit load */
    cmpw $0xF000, %si; jne bad3
    movw 2(%eax), %si
    cmpw $0x1234, %si; jne bad3

    /* all addr32 accesses correct -> "AOK\r\n" */
    movw $0x03F8,%dx
    movb $'A',%al; outb %al,%dx; movb $'O',%al; outb %al,%dx; movb $'K',%al; outb %al,%dx
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx
    jmp done

bad1: movb $'1',%bh; jmp report
bad2: movb $'2',%bh; jmp report
bad3: movzwl %si, %edx; movb $'3',%bh; jmp report   /* phase 3 uses si */
report:
    /* "B<phase>=" then hex32(edx) */
    movw $0x03F8,%dx
    movb $'B',%al; outb %al,%dx
    movb %bh,%al;  outb %al,%dx
    movb $'=',%al; outb %al,%dx
    /* print edx as 8 hex nibbles, high-to-low */
    movw $8, %cx
3:  roll $4, %edx
    movl %edx, %ebx
    andb $0x0F, %bl
    cmpb $10, %bl; jb 4f; addb $87,%bl; jmp 5f
4:  addb $48, %bl
5:  movb %bl,%al; movw $0x03F8,%dx; outb %al,%dx
    decw %cx; jnz 3b
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx
done:
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
