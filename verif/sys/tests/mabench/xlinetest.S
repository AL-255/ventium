/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * xlinetest.S — L1/AXI CROSS-CACHE-LINE store regression (the FreeDOS derail root cause).
 *
 * A 4-byte store whose bytes straddle the 32-byte L1 line end (byte offset 29/30/31 in
 * the line) spills its HIGH bytes into the NEXT line. ven_l1d forwards the full store to
 * the backing (which splits it into word beats), and INVALIDATES the cached line(s) so a
 * re-read refills correct data. The bug: the invalidate fired only when the ADDRESSED
 * line was resident (hit), so when the addressed line MISSED but the NEXT line was
 * RESIDENT (hit==0, hit_n==1), the next line's STALE copy was never invalidated — and a
 * later cross-line read served the stale HIGH bytes. On the KV260 this corrupted SeaBIOS's
 * __call16 iret frame (a `pushl` of the return {cs:ip} to a ...x7E stack slot spilled the
 * CS into a resident-but-stale next line) -> iret popped CS=0 -> FreeDOS derailed into the
 * IVT and HALTed. xwordtest covers cross-WORD (within-line) stores; this covers cross-LINE.
 *
 * Reproduce the exact (hit==0, hit_n==1) shape, then verify both the cross-line read and
 * the next-line read return the spilled high bytes. Prints "XLOK" on success.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw $0x7000,%sp
    movw $0x3000,%ax; movw %ax,%ds; movw %ax,%es   /* ds=es=0x3000 -> linear base 0x30000 */
    /* COM1 8N1 */
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx

    /* line A = linear 0x30000 (set 0), line B = linear 0x30020 (set 1) — distinct sets.
       1. seed the backing at 0x30020 and READ it so line B becomes RESIDENT (stale copy).
          Line A is deliberately NOT touched, so it stays NON-resident. */
    movl $0x11111111, %eax
    movl %eax, 0x20             /* backing[0x30020] = 0x11111111 (write-through)        */
    movl 0x20, %ebx             /* read -> fills/caches line B (resident, holds 1111...) */

    /* 2. CROSS-LINE store: dword 0xCAFEF00D to offset 0x1e. Bytes 0x1e,0x1f -> line A;
          bytes 0x20,0x21 -> line B. addressed line A MISSES (hit=0), next line B HITS
          (hit_n=1) -> the exact buggy shape. */
    movl $0xCAFEF00D, %eax
    movl %eax, 0x1e

    /* 3. cross-line READ back: must be the full 0xCAFEF00D (not 0x1111F00D from stale B) */
    movl 0x1e, %ecx
    cmpl $0xCAFEF00D, %ecx
    jne bad

    /* 4. next-line READ: [0x30020] must be 0x1111CAFE — its low word overwritten by the
          spilled high bytes (0xCA,0xFE), high word still the seed (0x1111). A stale B
          would read 0x11111111. */
    movl 0x20, %ecx
    cmpl $0x1111CAFE, %ecx
    jne bad

    /* pass -> "XLOK\r\n" */
    movw $0x03F8,%dx
    movb $'X',%al; outb %al,%dx; movb $'L',%al; outb %al,%dx
    movb $'O',%al; outb %al,%dx; movb $'K',%al; outb %al,%dx
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx
    jmp done
bad:
    /* "XLBAD " hex32(ecx) */
    movl %ecx, %ebp
    movw $0x03F8,%dx
    movb $'X',%al; outb %al,%dx; movb $'L',%al; outb %al,%dx
    movb $'B',%al; outb %al,%dx; movb $'A',%al; outb %al,%dx; movb $'D',%al; outb %al,%dx
    movb $' ',%al; outb %al,%dx
    movl %ebp, %eax
    movw $8, %cx
1:  roll $4, %eax
    movl %eax, %ebx
    andb $0x0F, %bl
    cmpb $10, %bl; jb 2f; addb $87,%bl; jmp 3f
2:  addb $48, %bl
3:  movb %bl,%al; movw $0x03F8,%dx; outb %al,%dx
    decw %cx; jnz 1b
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx
done:
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
