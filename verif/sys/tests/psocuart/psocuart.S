/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M8.5 — bare-metal COM1 UART (NS16550A) differential test.
 *
 * Exercises the serial UART that M8.5 wires into ventium_soc at I/O 0x3F8..0x3FF
 * (COM1, ISA IRQ4). Same per-record-differential shape as psocdev: NO interrupts
 * (IER never enables a source whose condition is met), every interaction a
 * SYNCHRONOUS IN/OUT, so qemu-system's gdbstub single-step (gen_trace.py --system)
 * is a valid per-record oracle and the gate is plain compare.py EQUIVALENT.
 *
 * DETERMINISM CONTRACT — only synchronous, host-clock/queue-independent state:
 *   reset values : LSR = 0x60 (TEMT|THRE), IIR = 0x01 (NO_INT).
 *   round-trips  : SCR (full byte), LCR (full), IER (mask 0x0F), MCR (mask 0x1F),
 *                  divisor latch DLL/DLM via DLAB (LCR bit7).
 *   FIFO bits    : after FCR bit0=1, IIR reads 0xC1 (FIFO-enabled | NO_INT).
 *   THR write    : an OUT to THR is accepted (no HALT); LSR is NOT read after it
 *                  (qemu drains TX via a transmit timer whose THRE/TEMT phase is
 *                  not single-step-synchronous — off the differential surface).
 * EXCLUDED (oracle boundary, covered by the unit/board path, like the 8042 OBF):
 *   the async RX-data path (RBR / LSR.DR), modem-status MSR, loopback, and IRQ4
 *   delivery — qemu drives them off a host chardev + timer the golden can't
 *   reproduce. IER is kept to bits {RX-data, RX-line-status} (0x05) whose sources
 *   (DR / line errors) never occur here, so NO interrupt is ever raised.
 *
 * Memory plan (-m 32, NO paging, linear==physical):
 *   GDT @ 0x0500 (null + code32 0x08 + data32 0x10), results @ 0x2000, stack @ 0x90000.
 * Build: gcc -m32 -ffreestanding -nostdlib; objcopy -O binary padded to 64 KiB.
 */

    .equ RES_LSR0,  0x00002000  /* reset LSR read              = 0x60 */
    .equ RES_IIR0,  0x00002004  /* reset IIR read              = 0x01 */
    .equ RES_SCR1,  0x00002008  /* SCR = 0x5A round-trip       = 0x5A */
    .equ RES_SCR2,  0x0000200C  /* SCR = 0xA5 round-trip       = 0xA5 */
    .equ RES_LCR,   0x00002010  /* LCR = 0x03 round-trip       = 0x03 */
    .equ RES_IER,   0x00002014  /* IER = 0x05 round-trip       = 0x05 */
    .equ RES_DLL,   0x00002018  /* DLL = 0x0C via DLAB         = 0x0C */
    .equ RES_DLM,   0x0000201C  /* DLM = 0x01 via DLAB         = 0x01 */
    .equ RES_MCR1,  0x00002020  /* MCR = 0x0F round-trip       = 0x0F */
    .equ RES_MCR2,  0x00002024  /* MCR = 0xE7 masked to 0x1F   = 0x07 */
    .equ RES_IIRF,  0x00002028  /* IIR after FCR enable        = 0xC1 */
    .equ RES_LSR1,  0x0000202C  /* LSR re-read (pre-THR)       = 0x60 */

    .equ COM1,      0x03F8

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld

    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* --- flat GDT (null + code32 0x08 + data32 0x10) @ 0x0500 --- */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* code32 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* data32 */
    movl    $0x00CF9200, 20(%ebx)

    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* far jmp 0x08:pm32_entry */
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp

    /* ============ reset values (read BEFORE any write) =================== */
    /* LSR (0x3FD) at reset = TEMT|THRE = 0x60 */
    movw    $0x03FD, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_LSR0

    /* IIR (0x3FA) at reset = NO_INT = 0x01 */
    movw    $0x03FA, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_IIR0

    /* ============ SCR scratch round-trip (0x3FF, full byte) ============== */
    movw    $0x03FF, %dx
    movb    $0x5A, %al
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_SCR1

    movb    $0xA5, %al
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_SCR2

    /* ============ LCR round-trip (0x3FB = 8N1, DLAB=0) =================== */
    movw    $0x03FB, %dx
    movb    $0x03, %al
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_LCR

    /* ============ IER round-trip (0x3F9, mask 0x0F; no live source) ====== */
    movw    $0x03F9, %dx
    movb    $0x05, %al                  /* RX-data + RX-line-status enables */
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_IER
    movb    $0x00, %al                  /* disable again (keep fully quiescent) */
    outb    %al, %dx

    /* ============ divisor latch via DLAB (LCR bit7) ====================== */
    movw    $0x03FB, %dx
    movb    $0x83, %al                  /* DLAB=1 (+8N1) */
    outb    %al, %dx
    movw    $0x03F8, %dx                /* DLL */
    movb    $0x0C, %al
    outb    %al, %dx
    movw    $0x03F9, %dx                /* DLM */
    movb    $0x01, %al
    outb    %al, %dx
    movw    $0x03F8, %dx                /* read DLL */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_DLL
    movw    $0x03F9, %dx                /* read DLM */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_DLM
    movw    $0x03FB, %dx                /* DLAB=0 again */
    movb    $0x03, %al
    outb    %al, %dx

    /* ============ MCR round-trip + masking (0x3FC, mask 0x1F) ============ */
    movw    $0x03FC, %dx
    movb    $0x0F, %al                  /* DTR|RTS|OUT1|OUT2 (no LOOP) */
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_MCR1
    movb    $0xE7, %al                  /* high bits set -> masked to 0x07 */
    outb    %al, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_MCR2
    movb    $0x00, %al                  /* clear MCR */
    outb    %al, %dx

    /* ============ FCR enable -> IIR FIFO bits (0x3FA) ==================== */
    movw    $0x03FA, %dx
    movb    $0x01, %al                  /* FCR: FIFO enable */
    outb    %al, %dx
    inb     %dx, %al                    /* IIR -> 0xC1 (FIFO | NO_INT) */
    andl    $0xFF, %eax
    movl    %eax, RES_IIRF

    /* ============ LSR re-read (still 0x60), then THR write =============== */
    movw    $0x03FD, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, RES_LSR1

    /* THR write (0x3F8, DLAB=0): accepted, no HALT. LSR is intentionally NOT
     * read afterwards (TX-drain timing is off the differential surface). */
    movw    $0x03F8, %dx
    movb    $0x41, %al                  /* 'A' */
    outb    %al, %dx

    /* ====================== clean exit via isa-debug-exit ================= */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx                    /* qemu status (0x42<<1)|1 = 133 */
hang:
    hlt
    jmp     hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* far jmp 0xF000:_start16_off */
    .word   _start16_off
    .word   0xF000
