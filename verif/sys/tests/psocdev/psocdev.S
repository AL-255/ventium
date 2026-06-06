/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M8.2 — bare-metal SoC PC-PERIPHERAL device differential test.
 *
 * This is the M8.2 SoC-integration gate test. It exercises the three devices
 * M8.2 wires into ventium_soc — the MC146818 RTC/CMOS (0x70/0x71), the 8042
 * keyboard controller (0x60/0x64), and the port-92 fast-A20 (0x92) — plus the
 * combined A20 address mask.
 *
 * --------------------------------------------------------------------------
 * WHY THIS IS A FULL PER-RECORD DIFFERENTIAL (stronger than pirqsoc):
 * --------------------------------------------------------------------------
 * pirqsoc needed a CHECKPOINT-differential because async hardware INTR delivery
 * is structurally invisible to qemu's gdbstub single-step (SSTEP_NOIRQ masks
 * CPU_INTERRUPT_HARD). This test uses NO interrupts: every device interaction is
 * a SYNCHRONOUS IN/OUT (or an A20-masked memory access), which single-steps
 * cleanly. So the standard gen_trace.py --system single-step golden IS a valid
 * per-record oracle, and the gate is plain compare.py EQUIVALENT — exactly like
 * the verify-sys system-mode tests, but running on ventium_soc (with the M8.2
 * devices) instead of ventium_top.
 *
 * --------------------------------------------------------------------------
 * THE DETERMINISM CONTRACT — only TIME-INVARIANT, QUEUE-INDEPENDENT state:
 * --------------------------------------------------------------------------
 * qemu-system derives RTC time bytes / REG_A.UIP / REG_C flags from the host
 * clock, and attaches a live PS/2 keyboard whose async power-on bytes populate
 * the 8042 output buffer. Neither is reproducible by a standalone register
 * model, so NEITHER is on the differential surface. The test reads ONLY:
 *   RTC : REG_D (VRT=0x80), REG_B (control round-trip), a scratch CMOS byte
 *         (index 0x50, plain RAM) round-trip, the index-port read (=0xFF), and
 *         the NMI-disable-bit non-aliasing (writing index|0x80 still reads the
 *         addressed CMOS byte) — all TIME-INVARIANT.
 *   p92 : the outport register read/write (A20 bit1; bit0 kept 0 — never a
 *         reset request) — purely combinational, no time/queue dependence.
 *   8042: ONLY the queue-independent A20 commands 0xDF/0xDD (controller output
 *         port), OBSERVED through the A20 mask. The 8042 OBF/data read path
 *         (0x60) is NOT read here — it is covered by the standalone unit
 *         self-check (a documented oracle boundary, like LAPIC / SMM).
 *
 * --------------------------------------------------------------------------
 * THE A20 MASK FUNCTIONAL TEST (cross-device):
 * --------------------------------------------------------------------------
 * The PC A20 gate is the OR of the 8042 output-port A20 bit and the port-92
 * bit1; ventium_soc OR-combines them and, when A20 is masked, forces physical
 * address bit 20 low (the classic 1 MiB wraparound) on the core's outgoing bus.
 * A20_HI = A20_LO + (1<<20) differ only in bit 20:
 *   - A20 ENABLED  -> distinct physical locations.
 *   - A20 MASKED   -> the high address wraps to the low one.
 * To match qemu-system's last-writer-wins A20 line with the RTL OR-combine, the
 * test drives BOTH A20 sources to the SAME level in every phase where a memory
 * access observes A20 (the one-instruction transition windows between the two
 * source writes contain no bit-20 memory access, so the momentary OR-vs-last-
 * writer disagreement is unobservable). dcache_timing carries NO data (load
 * data always returns via mem_rdata for the masked address), so the wraparound
 * is value-exact vs qemu-system, which has no data cache either.
 *
 * Memory plan (machine -m 32 => 32 MiB; NO paging, linear==physical):
 *   GDT     @ 0x00000500 (null + code32 0x08 + data32 0x10)
 *   results @ 0x00002000 (14 dwords; per-record diff already covers them, the
 *                         store-back just yields a clean self-documenting end)
 *   A20_LO  @ 0x00003000   A20_HI @ 0x00103000  (differ only in bit 20)
 *   stack   @ 0x00090000 (flat 32-bit)
 *
 * Build: gcc -m32 -ffreestanding -nostdlib (see Makefile); objcopy -O binary,
 * padded to exactly 64 KiB. GNU-as (AT&T) syntax.
 */

    .equ RES_RTC_REGD,  0x00002000  /* REG_D (VRT)              = 0x80 */
    .equ RES_RTC_REGB0, 0x00002004  /* REG_B default            = 0x02 */
    .equ RES_RTC_REGB1, 0x00002008  /* REG_B after write 0x82   = 0x82 */
    .equ RES_RTC_SCR1,  0x0000200C  /* CMOS[0x50] = 0x5A read   = 0x5A */
    .equ RES_RTC_SCR2,  0x00002010  /* CMOS[0x50] = 0xA5 read   = 0xA5 */
    .equ RES_RTC_IDX,   0x00002014  /* index-port read          = 0xFF */
    .equ RES_RTC_NMI,   0x00002018  /* REG_D via index|0x80     = 0x80 */
    .equ RES_P92_RST,   0x0000201C  /* port92 reset read        = 0x00 */
    .equ RES_P92_ON,    0x00002020  /* port92 after A20-on write = 0x02 */
    .equ RES_P92_OFF,   0x00002024  /* port92 after A20-off write= 0x00 */
    .equ RES_A20_A,     0x00002028  /* A20 ON : [hi]            = 0x11111111 */
    .equ RES_A20_B,     0x0000202C  /* A20 OFF: [hi]->[lo]      = 0x22222222 */
    .equ RES_A20_B2,    0x00002030  /* A20 OFF: masked write@lo = 0x33333333 */
    .equ RES_A20_C,     0x00002034  /* A20 ON : [hi] untouched  = 0x11111111 */

    .equ A20_LO,        0x00003000
    .equ A20_HI,        0x00103000  /* A20_LO + (1<<20): differs only in bit 20 */

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

    /* ================== RTC (MC146818) — time-invariant regs ============== */
    /* REG_D (0x0D): VRT, constant 0x80 */
    movb    $0x0D, %al
    outb    %al, $0x70                  /* set CMOS index */
    inb     $0x71, %al                  /* read data */
    andl    $0xFF, %eax
    movl    %eax, RES_RTC_REGD

    /* REG_B (0x0B): reset default 0x02 (24H, BCD) */
    movb    $0x0B, %al
    outb    %al, $0x70
    inb     $0x71, %al
    andl    $0xFF, %eax
    movl    %eax, RES_RTC_REGB0

    /* write REG_B = 0x82 (SET freezes the wall clock + 24H; NO IRQ enables) and
     * read it back -> 0x82: a control-register write/read round-trip. */
    movb    $0x0B, %al
    outb    %al, $0x70
    movb    $0x82, %al
    outb    %al, $0x71
    movb    $0x0B, %al
    outb    %al, $0x70
    inb     $0x71, %al
    andl    $0xFF, %eax
    movl    %eax, RES_RTC_REGB1

    /* CMOS scratch RAM round-trip at index 0x50 (plain RAM in qemu + RTL) */
    movb    $0x50, %al
    outb    %al, $0x70
    movb    $0x5A, %al
    outb    %al, $0x71
    movb    $0x50, %al
    outb    %al, $0x70
    inb     $0x71, %al
    andl    $0xFF, %eax
    movl    %eax, RES_RTC_SCR1

    /* a second value at the same index proves it is really stored RAM */
    movb    $0x50, %al
    outb    %al, $0x70
    movb    $0xA5, %al
    outb    %al, $0x71
    movb    $0x50, %al
    outb    %al, $0x70
    inb     $0x71, %al
    andl    $0xFF, %eax
    movl    %eax, RES_RTC_SCR2

    /* the write-only INDEX port reads back 0xFF */
    movb    $0x0D, %al
    outb    %al, $0x70
    inb     $0x70, %al                  /* read the INDEX port (even) */
    andl    $0xFF, %eax
    movl    %eax, RES_RTC_IDX

    /* NMI-disable bit (index bit7): writing 0x8D sets index=0x0D + NMI-disable;
     * the data read still returns REG_D=0x80 (bit7 does NOT alias into CMOS). */
    movb    $0x8D, %al
    outb    %al, $0x70
    inb     $0x71, %al
    andl    $0xFF, %eax
    movl    %eax, RES_RTC_NMI

    /* ===================== port-92 (fast A20 / control port A) ============ */
    /* reset read: outport power-on/init value 0x00 */
    inb     $0x92, %al
    andl    $0xFF, %eax
    movl    %eax, RES_P92_RST

    /* write 0x02 (A20 enable via port92, bit0=0 => NO reset request), read back */
    movb    $0x02, %al
    outb    %al, $0x92
    inb     $0x92, %al
    andl    $0xFF, %eax
    movl    %eax, RES_P92_ON

    /* write 0x00 (A20 disable via port92; bit0 stays 0 => no reset), read back */
    movb    $0x00, %al
    outb    %al, $0x92
    inb     $0x92, %al
    andl    $0xFF, %eax
    movl    %eax, RES_P92_OFF

    /* ===================== A20 mask functional test ======================= */
    /* Drive BOTH A20 sources to the SAME level each phase (port92 bit1 AND the
     * 8042 0xDF/0xDD A20 commands) so the RTL OR-combine matches qemu's a20
     * line in every memory-observable phase. */

    /* ---- Phase A: A20 ENABLED ---- */
    movb    $0x02, %al
    outb    %al, $0x92                  /* port92 A20 on */
    movb    $0xDF, %al
    outb    %al, $0x64                  /* 8042 CMD_ENABLE_A20 */

    movl    $0x11111111, A20_HI         /* -> phys 0x00103000 */
    movl    $0x22222222, A20_LO         /* -> phys 0x00003000 */
    movl    A20_HI, %eax                /* A20 on -> 0x11111111 (distinct) */
    movl    %eax, RES_A20_A

    /* ---- Phase B: A20 MASKED ---- */
    movb    $0xDD, %al
    outb    %al, $0x64                  /* 8042 CMD_DISABLE_A20 */
    movb    $0x00, %al
    outb    %al, $0x92                  /* port92 A20 off (both sources now 0) */

    movl    A20_HI, %eax                /* masked -> phys 0x003000 -> 0x22222222 */
    movl    %eax, RES_A20_B

    movl    $0x33333333, A20_HI         /* masked write -> phys 0x003000 */
    movl    A20_LO, %eax                /* read low -> 0x33333333 (alias proven) */
    movl    %eax, RES_A20_B2

    /* ---- Phase C: A20 ENABLED again ---- */
    movb    $0x02, %al
    outb    %al, $0x92
    movb    $0xDF, %al
    outb    %al, $0x64

    movl    A20_HI, %eax                /* phys 0x103000 -> 0x11111111 (untouched) */
    movl    %eax, RES_A20_C

    /* ====================== deterministic end-state ======================= */
    /* (the per-record diff already grades every instruction; these just leave a
     *  clean, self-documenting final register snapshot) */
    movl    RES_RTC_REGD, %esi          /* 0x00000080 */
    movl    RES_P92_ON,   %edi          /* 0x00000002 */
    movl    RES_A20_B,    %ebp          /* 0x22222222 (the wraparound witness) */
    xorl    %edx, %edx
    addl    RES_RTC_REGD,  %edx
    addl    RES_RTC_REGB1, %edx
    addl    RES_RTC_IDX,   %edx         /* 0x80 + 0x82 + 0xFF = 0x00000201 */
    movl    %edx, %ecx

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
