/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M8.1 — bare-metal ON-DIE TIMER IRQ (8259 PIC + 8254 PIT -> IRQ0)
 * SoC-integration differential-gate demonstrator.
 *
 * This is the M8.1 SoC-integration gate test. It exercises the EXTERNAL-INTERRUPT
 * path the core gains in M8.1 (the new soc_en/intr/inta delivery FSM): the 8254
 * PIT channel-0 raises IRQ0 into the 8259 master PIC, the PIC drives the core
 * INTR pin, the core acknowledges (INTA) + takes the maskable interrupt through an
 * IDT interrupt gate to a handler that counts + RE-ARMS the next IRQ + EOIs, and
 * the mainline SPIN-WAITS until the handler-incremented counter reaches a FIXED N.
 *
 * --------------------------------------------------------------------------
 * WHY A CPU-PACED, BOUNDED ONE-SHOT (PIT mode 0), NOT A FREE-RUNNING RATE-GEN:
 * --------------------------------------------------------------------------
 * Empirically de-risked under qemu-system-i386 8.2.2 single-step (gen_trace.py):
 *   - qemu's gdbstub single-step uses sstep_flags = ENABLE|NOIRQ|NOTIMER (0x7) by
 *     DEFAULT (gdbstub/gdbstub.c). NOIRQ masks CPU_INTERRUPT_HARD (the maskable
 *     INTR path) for the stepped instruction (accel/tcg/cpu-exec.c), and NOTIMER
 *     freezes the virtual clock. So under the STANDARD golden path NO hardware
 *     INTR is EVER deliverable -- synchronous OR asynchronous. The golden then
 *     just shows the spin loop forever.
 *   - With Qqemu.sstep=1 (NOIRQ|NOTIMER cleared) a FREE-RUNNING rate-generator
 *     (mode 2) IRQ0 re-fires on EVERY step and the handler can make NO forward
 *     progress (it is re-interrupted at its first instruction forever) -- the
 *     timer-vs-step clock ratio is pathological.
 *   - A BOUNDED one-shot (mode 0), re-armed once per handler, delivers EXACTLY
 *     ONCE per arm, the handler runs to IRET, control resumes, and the spin
 *     advances. Verified to deliver cleanly + reach the deterministic exit under
 *     BOTH full-speed and Qqemu.sstep=1 single-step.
 *
 * --------------------------------------------------------------------------
 * THE DETERMINISM CONTRACT (the crux of the M8.1 gate):
 * --------------------------------------------------------------------------
 * The EXACT instruction boundary at which each IRQ0 fires is a function of the
 * PIT-clock/CPU-clock ratio (qemu ns/icount cadence vs the RTL clk prescaler) and
 * is NONDETERMINISTIC between the oracle and the RTL -- it is STRUCTURAL, NOT
 * differential.
 *
 * What IS deterministic, CPU-observable, and boundary-INDEPENDENT -- and so is the
 * DIFFERENTIAL surface -- is the post-spin ARCHITECTURAL STATE and each delivery's
 * EFFECT:
 *   - the counter reaches EXACTLY N (we spin until == N, then mask IRQ0 so no
 *     N+1th delivery races the readback);
 *   - each delivery's EFFECT: control reaches the handler entry (CS:EIP into the
 *     interrupt-gate target with IF cleared), and IRET resumes the mainline;
 *   - the PIC master ISR/IMR readback after EOI+mask is a fixed value;
 *   - a deterministic computation over N + the readbacks lands in fixed GPRs;
 *   - the program exits via isa-debug-exit with a fixed code.
 * These match regardless of WHEN each IRQ fired. The spin loop and the exact IRQ
 * boundaries are excluded from the per-record differential (structural).
 *
 * --------------------------------------------------------------------------
 * LAPIC LINT0 = ExtINT (qemu-system platform requirement, RTL-inert):
 * --------------------------------------------------------------------------
 * Under qemu-system `-machine pc` the CPU INTR is driven by the LAPIC; the legacy
 * i8259 INT line only reaches the CPU when LAPIC LVT0 (LINT0) is in ExtINT mode
 * and the APIC is software-enabled. So the test software-enables the LAPIC (SPIV
 * bit 8) and sets LVT0=ExtINT (delivery mode 7). The ventium_soc wires
 * ven_pic.int_out -> core.intr DIRECTLY (no LAPIC), so these two MMIO writes to
 * 0xFEE000F0 / 0xFEE00350 are NO-OPS in the RTL (high-physical addresses the SoC
 * does not decode as a device) and the IRQ0 delivers directly. This is a benign,
 * documented platform divergence -- the LAPIC writes do not alter any RTL-observed
 * architectural state on the differential surface.
 *
 * Memory plan (machine -m 32 => 32 MiB; NO paging, linear==physical):
 *   GDT   @ 0x00000500 (null + code32 0x08 + data32 0x10)
 *   IDT   @ 0x00001000 (256 gates; only vector 0x20 = IRQ0 filled)
 *   vars  @ 0x00002000 (irq0 counter, readback scratch)
 *   stack @ 0x00090000 (flat 32-bit)
 *
 * 8259 remap: master vector base -> 0x20 (so IRQ0 = vector 0x20), slave -> 0x28
 * (standard PC protected-mode remap, avoiding the CPU exception vectors).
 *
 * 8254 PIT: channel 0, MODE 0 (interrupt on terminal count), a SHORT count so
 * IRQ0 fires promptly; the handler re-arms ch0 for the next one-shot. The exact
 * count affects only the CADENCE (structural), not the post-spin state.
 *
 * Build: gcc -m32 -ffreestanding -nostdlib (see Makefile); objcopy -O binary,
 * padded to exactly 64 KiB. GNU-as syntax.
 */

    .equ N_IRQ,       4          /* spin until this many IRQ0s counted */
    .equ PIT_COUNT,   0x0040     /* ch0 mode-0 terminal count (cadence only) */

    .equ VAR_BASE,    0x00002000
    .equ IRQ0_CTR,    0x00002000 /* IRQ0 delivery counter */
    .equ ISR_READ,    0x00002004 /* PIC master ISR readback */
    .equ IMR_READ,    0x00002008 /* PIC master IMR readback */

    .equ LAPIC_BASE,  0xFEE00000 /* local APIC MMIO (qemu-system platform) */

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

    .byte   0x66, 0xEA
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

    /* zero the var area (counter + readbacks) */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $4, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== build the IDT (1 gate: 0x20=IRQ0) ============== */
    /* gate 0x20 (IRQ0 after remap): 32-bit INTERRUPT gate (0x8E), sel 0x08 */
    movl    $irq0_handler, %ebx
    movl    $0x00001100, %edi           /* 0x1000 + 0x20*8 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* attr 0x8E (32-bit interrupt gate) */
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ===================== program the 8259 PIC (remap) ================== */
    movb    $0x11, %al
    outb    %al, $0x20                  /* master ICW1 */
    movb    $0x11, %al
    outb    %al, $0xA0                  /* slave  ICW1 */
    movb    $0x20, %al
    outb    %al, $0x21                  /* master ICW2 (base 0x20) */
    movb    $0x28, %al
    outb    %al, $0xA1                  /* slave  ICW2 (base 0x28) */
    movb    $0x04, %al
    outb    %al, $0x21                  /* master ICW3 (slave on IR2) */
    movb    $0x02, %al
    outb    %al, $0xA1                  /* slave  ICW3 (cascade id 2) */
    movb    $0x01, %al
    outb    %al, $0x21                  /* master ICW4 (8086) */
    movb    $0x01, %al
    outb    %al, $0xA1                  /* slave  ICW4 (8086) */

    /* IMR: unmask ONLY IRQ0 on the master (0xFE), mask everything on the slave */
    movb    $0xFE, %al
    outb    %al, $0x21                  /* master IMR: IRQ0 enabled */
    movb    $0xFF, %al
    outb    %al, $0xA1                  /* slave  IMR: all masked */

    /* ===================== LAPIC LINT0 = ExtINT ========================== */
    /* qemu-system platform: route the legacy i8259 INTR through LAPIC LINT0.
     * RTL-inert (the SoC does not decode 0xFEE000xx as a device). */
    movl    $LAPIC_BASE, %ebx
    movl    0xF0(%ebx), %eax            /* SPIV */
    orl     $0x100, %eax                /* APIC software-enable (bit 8) */
    movl    %eax, 0xF0(%ebx)
    movl    $0x00000700, 0x350(%ebx)    /* LVT0 = ExtINT (delivery 7), unmasked */

    /* ===================== arm the 8254 PIT ch0, MODE 0 ================== */
    /* control: ch0(00) access lo/hi(11) mode0(000) bin(0) = 0x30 */
    movb    $0x30, %al
    outb    %al, $0x43                  /* PIT mode/command: ch0 mode 0 */
    movb    $(PIT_COUNT & 0xFF), %al
    outb    %al, $0x40                  /* ch0 count LSB -> arms the one-shot */
    movb    $((PIT_COUNT >> 8) & 0xFF), %al
    outb    %al, $0x40                  /* ch0 count MSB */

    /* ====================== enable IRQs + spin to N ====================== */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi

    sti                                 /* IF=1: IRQ0 deliveries now flow */

spin:
    movl    IRQ0_CTR, %eax              /* poll handler-incremented counter */
    cmpl    $N_IRQ, %eax
    jb      spin                        /* spin while ctr < N */

    /* ctr == N. Mask IRQ0 so no further delivery races the readback, then read
     * the PIC master ISR (OCW3 0x0B) + IMR (data port). After EOI in the handler
     * the ISR bit for IRQ0 is cleared, so master ISR readback == 0x00; after
     * masking IRQ0 below the master IMR == 0xFF. */
    cli                                 /* close the window before mask/readback */
    movb    $0xFF, %al
    outb    %al, $0x21                  /* mask all master IRQs (IMR=0xFF) */

    /* read master ISR via OCW3 (0x0B selects ISR on next read of 0x20) */
    movb    $0x0B, %al
    outb    %al, $0x20
    inb     $0x20, %al
    andl    $0xFF, %eax
    movl    %eax, ISR_READ              /* expect 0x00 (all serviced + EOIed) */

    /* read master IMR (data port 0x21) */
    inb     $0x21, %al
    andl    $0xFF, %eax
    movl    %eax, IMR_READ              /* expect 0xFF (we just masked all) */

    /* ============ deterministic result computation ============
     * esi = N (counter); edi = ISR readback; ebp = IMR readback;
     * edx = N*0x1000 + ISR + IMR  (a fixed function of the deterministic state).
     * Boundary-INDEPENDENT: a function of "exactly N IRQ0s delivered, each EOIed,
     * then all masked". */
    movl    IRQ0_CTR, %esi
    movl    ISR_READ,  %edi
    movl    IMR_READ,  %ebp
    movl    %esi, %edx
    shll    $12, %edx
    addl    %edi, %edx
    addl    %ebp, %edx                 /* edx = N*0x1000 + 0x00 + 0xFF */
    movl    %edx, %ecx                 /* ecx mirrors the result for visibility */

    /* ====================== clean exit via isa-debug-exit ================= */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx                   /* qemu status 133 */

hang:
    hlt
    jmp     hang

    /* ============================= IRQ0 HANDLER ============================= */
    /* Increments the IRQ0 counter, RE-ARMS the PIT ch0 one-shot for the next
     * delivery, sends a non-specific EOI to the master PIC, and IRETs. Touches
     * only EAX (saved/restored). The interrupt gate cleared IF on entry so the
     * handler is not re-entered; IRET restores IF=1. Re-arming inside the handler
     * (mode 0 is a single terminal-count one-shot) is what BOUNDS the cadence:
     * exactly one delivery per arm, so N arms -> N deliveries, no free-running
     * re-fire storm. */
    .align 16
    .global irq0_handler
irq0_handler:
    pushl   %eax
    incl    IRQ0_CTR                    /* count this delivery */
    /* re-arm ch0 mode-0 one-shot for the NEXT IRQ0 */
    movb    $0x30, %al
    outb    %al, $0x43
    movb    $(PIT_COUNT & 0xFF), %al
    outb    %al, $0x40
    movb    $((PIT_COUNT >> 8) & 0xFF), %al
    outb    %al, $0x40
    movb    $0x20, %al
    outb    %al, $0x20                  /* non-specific EOI to master */
    popl    %eax
    iret

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
