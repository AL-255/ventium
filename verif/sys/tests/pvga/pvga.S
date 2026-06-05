/* Ventium M8.3 — bare-metal SoC VGA-register-file differential test (+ ACPI PM
 * write-inert).  This is the M8.3 SoC-integration gate test. It exercises the
 * two devices M8.3 wires into ventium_soc — the VGA register file (0x3B0..0x3DF)
 * and the ACPI PM timer (0x608).
 *
 * --------------------------------------------------------------------------
 * FULL PER-RECORD DIFFERENTIAL (like psocdev, stronger than pirqsoc):
 * --------------------------------------------------------------------------
 * Every interaction is a SYNCHRONOUS IN/OUT — no interrupts — so qemu's gdbstub
 * single-step (gen_trace.py --system) IS a valid per-record oracle, and the gate
 * is plain compare.py EQUIVALENT, running on ventium_soc (with the M8.3 devices).
 *
 * The VGA register file is CPU-observable register state ONLY (no framebuffer /
 * scan-out).  Modeled + matched to qemu hw/display/vga.c (vga_ioport_read/write,
 * QEMU 8.2.2).  EVERY read here was first observed under qemu-system-i386 to
 * confirm the ven_vgaregs model is byte-identical, including:
 *   - MISC/ST00 reset values (0x3cc / 0x3c2 = 0x00)
 *   - SEQUENCER per-index write masks (sr_mask: sr[1]&0x3d, sr[4]&0x0e)
 *   - GRAPHICS per-index write masks (gr_mask: gr[5]&0x7b, gr[8]&0xff)
 *   - DAC 3-byte palette write + read auto-increment (R/G/B, write-index ++)
 *   - ATTRIBUTE index/data flip-flop + per-index write mask (ar[0x0A]&0x3f,
 *     ar[0x10]&~0x10), and 0x3c0 index-read with ff=0
 *   - MISC color/mono port aliasing: write 0x3c2 bit0 flips which of
 *     0x3b0..0x3bf / 0x3d0..0x3df are INVALID (read 0xff) — vga_ioport_invalid
 *   - CRTC index/data in BOTH color (0x3d4/0x3d5) and mono (0x3b4/0x3b5) banks
 *   - CRTC CR0-7 write-lock (CR11 bit7) incl. the CR7-bit4-always-writable case
 *   - IS1 dumb-retrace toggle (0x3da/0x3ba reads alternate 0x09/0x00 — verified
 *     deterministic across qemu runs, i.e. dumb not host-clock precise retrace)
 *
 * The ACPI PM timer (0x608) is wired for connectivity; its READ is a documented
 * oracle boundary (qemu's default -machine pc leaves the PIIX4 PM I/O region
 * DISABLED -> 0x608 reads 0xffffffff as unassigned I/O, and the PM value is
 * host-clock-derived anyway).  So this test never READS 0x608; it only does an
 * OUT 0x608 (write-inert): a no-op in BOTH qemu (unassigned-write-ignored) and
 * the RTL (acpi_pm_tmr_write does nothing), so it retires identically.  The PM
 * value-read is covered by the standalone ven_acpipm unit self-check.
 *
 * Memory plan (machine -m 32; NO paging, linear==physical):
 *   GDT     @ 0x00000500 (null + code32 0x08 + data32 0x10)
 *   results @ 0x00002000 (per-record diff already covers them; the store-back
 *                         just yields a clean self-documenting end-state)
 *   stack   @ 0x00090000 (flat 32-bit)
 *
 * Build: gcc -m32 -ffreestanding -nostdlib (see Makefile); objcopy -O binary,
 * padded to exactly 64 KiB. GNU-as (AT&T) syntax.
 */

    .equ R_MSR0,     0x00002000  /* 0x3cc misc read (mono reset)   = 0x00 */
    .equ R_ST00,     0x00002004  /* 0x3c2 st00 read                = 0x00 */
    .equ R_SEQ1,     0x00002008  /* sr[1] = 0xFF & 0x3d            = 0x3d */
    .equ R_SEQ4,     0x0000200C  /* sr[4] = 0xFF & 0x0e            = 0x0e */
    .equ R_GFX5,     0x00002010  /* gr[5] = 0xFF & 0x7b            = 0x7b */
    .equ R_GFX8,     0x00002014  /* gr[8] = 0xAA & 0xff            = 0xAA */
    .equ R_DAC0,     0x00002018  /* palette[0] R                  = 0x11 */
    .equ R_DAC1,     0x0000201C  /* palette[1] G                  = 0x22 */
    .equ R_DAC2,     0x00002020  /* palette[2] B                  = 0x33 */
    .equ R_DAC3,     0x00002024  /* palette[3] R (entry 1)        = 0x44 */
    .equ R_DAC4,     0x00002028  /* palette[4] G                  = 0x55 */
    .equ R_DAC5,     0x0000202C  /* palette[5] B                  = 0x66 */
    .equ R_DACST,    0x00002030  /* 0x3c7 dac_state               = 0x03 */
    .equ R_DACWI,    0x00002034  /* 0x3c8 dac_write_index         = 0x02 */
    .equ R_ISMONO,   0x00002038  /* 0x3ba mono IS1 #1 (toggle)    = 0x09 */
    .equ R_ATTRA,    0x0000203C  /* ar[0x0A] = 0xFF & 0x3f        = 0x3f */
    .equ R_ATTRM,    0x00002040  /* ar[0x10] = 0xFF & ~0x10       = 0xEF */
    .equ R_ATTI,     0x00002044  /* 0x3c0 read (ff=0 -> ar_index) = 0x10 */
    .equ R_MSR1,     0x00002048  /* 0x3cc after write 0x01        = 0x01 */
    .equ R_CRTC_C1,  0x0000204C  /* color cr[1] = 0x5A            = 0x5A */
    .equ R_MONOINV,  0x00002050  /* 0x3b5 in color mode (INVALID) = 0xFF */
    .equ R_IS1_A,    0x00002054  /* 0x3da color IS1 #1            = 0x09 */
    .equ R_IS1_B,    0x00002058  /* 0x3da color IS1 #2            = 0x00 */
    .equ R_MSR2,     0x0000205C  /* 0x3cc after write 0x00        = 0x00 */
    .equ R_CRTC_M2,  0x00002060  /* mono cr[2] = 0xA5             = 0xA5 */
    .equ R_COLORINV, 0x00002064  /* 0x3d5 in mono mode (INVALID)  = 0xFF */
    .equ R_CR0_PRE,  0x00002068  /* cr[0] = 0x12 (unlocked)       = 0x12 */
    .equ R_CR0_LK,   0x0000206C  /* cr[0] after locked write 0x99 = 0x12 */
    .equ R_CR7_B4,   0x00002070  /* cr[7] locked: only bit4 wrote = 0x10 */
    .equ R_CR0_UL,   0x00002074  /* cr[0] after unlock + write    = 0x99 */

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

    /* ============ VGA: MISC / ST00 reset reads (mono mode) ============ */
    movw    $0x3CC, %dx                 /* MSR read */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_MSR0
    movw    $0x3C2, %dx                 /* ST00 read */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_ST00

    /* ============ SEQUENCER per-index write masks ============ */
    movb    $0x01, %al                  /* seq idx 1 */
    movw    $0x3C4, %dx
    outb    %al, %dx
    movb    $0xFF, %al                  /* sr[1] = 0xFF & 0x3d = 0x3d */
    movw    $0x3C5, %dx
    outb    %al, %dx
    movw    $0x3C5, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SEQ1

    movb    $0x04, %al                  /* seq idx 4 */
    movw    $0x3C4, %dx
    outb    %al, %dx
    movb    $0xFF, %al                  /* sr[4] = 0xFF & 0x0e = 0x0e */
    movw    $0x3C5, %dx
    outb    %al, %dx
    movw    $0x3C5, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SEQ4

    /* ============ GRAPHICS per-index write masks ============ */
    movb    $0x05, %al                  /* gfx idx 5 */
    movw    $0x3CE, %dx
    outb    %al, %dx
    movb    $0xFF, %al                  /* gr[5] = 0xFF & 0x7b = 0x7b */
    movw    $0x3CF, %dx
    outb    %al, %dx
    movw    $0x3CF, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_GFX5

    movb    $0x08, %al                  /* gfx idx 8 */
    movw    $0x3CE, %dx
    outb    %al, %dx
    movb    $0xAA, %al                  /* gr[8] = 0xAA & 0xff = 0xAA */
    movw    $0x3CF, %dx
    outb    %al, %dx
    movw    $0x3CF, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_GFX8

    /* ============ DAC palette 3-byte write + read auto-increment ====== */
    movb    $0x00, %al                  /* PEL write index = 0 */
    movw    $0x3C8, %dx
    outb    %al, %dx
    movw    $0x3C9, %dx                  /* write entry 0 R,G,B */
    movb    $0x11, %al
    outb    %al, %dx
    movb    $0x22, %al
    outb    %al, %dx
    movb    $0x33, %al
    outb    %al, %dx
    movb    $0x44, %al                  /* write entry 1 R,G,B (idx auto-inc'd) */
    outb    %al, %dx
    movb    $0x55, %al
    outb    %al, %dx
    movb    $0x66, %al
    outb    %al, %dx

    movb    $0x00, %al                  /* PEL read index = 0 (state -> 3) */
    movw    $0x3C7, %dx
    outb    %al, %dx
    movw    $0x3C9, %dx                  /* read 6 bytes (auto-inc across entries) */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DAC0
    movw    $0x3C9, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DAC1
    movw    $0x3C9, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DAC2
    movw    $0x3C9, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DAC3
    movw    $0x3C9, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DAC4
    movw    $0x3C9, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DAC5
    movw    $0x3C7, %dx                  /* dac_state read = 3 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DACST
    movw    $0x3C8, %dx                  /* dac_write_index read = 2 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DACWI

    /* ============ ATTRIBUTE flip-flop + per-index masks =============== */
    movw    $0x3BA, %dx                  /* mono IS1 read: resets attr ff -> 0 */
    inb     %dx, %al                     /* (also a mono dumb-retrace toggle) */
    andl    $0xFF, %eax
    movl    %eax, R_ISMONO

    movb    $0x0A, %al                   /* ATTR index phase: ar_index=0x0A */
    movw    $0x3C0, %dx
    outb    %al, %dx
    movb    $0xFF, %al                   /* ATTR data phase: ar[0x0A]=0xFF&0x3f */
    movw    $0x3C0, %dx
    outb    %al, %dx
    movw    $0x3C1, %dx                  /* read ar[0x0A] = 0x3f */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_ATTRA

    movb    $0x10, %al                   /* ATTR index phase: ar_index=0x10 */
    movw    $0x3C0, %dx
    outb    %al, %dx
    movb    $0xFF, %al                   /* ATTR data phase: ar[0x10]=0xFF&~0x10 */
    movw    $0x3C0, %dx
    outb    %al, %dx
    movw    $0x3C1, %dx                  /* read ar[0x10] = 0xEF */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_ATTRM

    movw    $0x3C0, %dx                  /* 0x3c0 read (ff=0) -> ar_index = 0x10 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_ATTI

    /* ============ MISC color-mode switch + port aliasing ============= */
    movb    $0x01, %al                   /* msr bit0=1 -> COLOR mode */
    movw    $0x3C2, %dx
    outb    %al, %dx
    movw    $0x3CC, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_MSR1                 /* = 0x01 */

    movb    $0x01, %al                   /* color CRTC idx 1 (CR1) */
    movw    $0x3D4, %dx
    outb    %al, %dx
    movb    $0x5A, %al                   /* cr[1] = 0x5A (CR11 unlocked) */
    movw    $0x3D5, %dx
    outb    %al, %dx
    movb    $0x01, %al
    movw    $0x3D4, %dx
    outb    %al, %dx
    movw    $0x3D5, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_CRTC_C1              /* = 0x5A */

    movw    $0x3B5, %dx                  /* mono port now INVALID -> 0xff */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_MONOINV

    movw    $0x3DA, %dx                  /* color IS1 toggle: 0x09 then 0x00 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_IS1_A
    movw    $0x3DA, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_IS1_B

    /* ============ switch back to mono + mono CRTC bank =============== */
    movb    $0x00, %al                   /* msr bit0=0 -> MONO mode */
    movw    $0x3C2, %dx
    outb    %al, %dx
    movw    $0x3CC, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_MSR2                 /* = 0x00 */

    movb    $0x02, %al                   /* mono CRTC idx 2 (CR2) */
    movw    $0x3B4, %dx
    outb    %al, %dx
    movb    $0xA5, %al                   /* cr[2] = 0xA5 */
    movw    $0x3B5, %dx
    outb    %al, %dx
    movb    $0x02, %al
    movw    $0x3B4, %dx
    outb    %al, %dx
    movw    $0x3B5, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_CRTC_M2              /* = 0xA5 */

    movw    $0x3D5, %dx                  /* color port now INVALID -> 0xff */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_COLORINV

    /* ============ CRTC CR0-7 write-lock (CR11 bit7) ================== */
    /* (mono bank, msr=0; CR0-7 lock + CR7-bit4-always-writable + unlock) */
    movb    $0x00, %al                   /* CR0 idx, write 0x12 while UNLOCKED */
    movw    $0x3B4, %dx
    outb    %al, %dx
    movb    $0x12, %al
    movw    $0x3B5, %dx
    outb    %al, %dx
    movb    $0x00, %al
    movw    $0x3B4, %dx
    outb    %al, %dx
    movw    $0x3B5, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_CR0_PRE              /* = 0x12 */

    movb    $0x11, %al                   /* CR11 idx, write 0x80 (set lock bit7) */
    movw    $0x3B4, %dx
    outb    %al, %dx
    movb    $0x80, %al
    movw    $0x3B5, %dx
    outb    %al, %dx

    movb    $0x00, %al                   /* CR0 idx, try write 0x99 -> LOCKED */
    movw    $0x3B4, %dx
    outb    %al, %dx
    movb    $0x99, %al
    movw    $0x3B5, %dx
    outb    %al, %dx
    movb    $0x00, %al
    movw    $0x3B4, %dx
    outb    %al, %dx
    movw    $0x3B5, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_CR0_LK              /* still 0x12 (write ignored) */

    movb    $0x07, %al                   /* CR7 idx, write 0xFF -> only bit4 takes */
    movw    $0x3B4, %dx
    outb    %al, %dx
    movb    $0xFF, %al
    movw    $0x3B5, %dx
    outb    %al, %dx
    movb    $0x07, %al
    movw    $0x3B4, %dx
    outb    %al, %dx
    movw    $0x3B5, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_CR7_B4             /* = 0x10 */

    movb    $0x11, %al                   /* CR11 idx, write 0x00 (clear lock) */
    movw    $0x3B4, %dx
    outb    %al, %dx
    movb    $0x00, %al
    movw    $0x3B5, %dx
    outb    %al, %dx

    movb    $0x00, %al                   /* CR0 idx, write 0x99 now UNLOCKED */
    movw    $0x3B4, %dx
    outb    %al, %dx
    movb    $0x99, %al
    movw    $0x3B5, %dx
    outb    %al, %dx
    movb    $0x00, %al
    movw    $0x3B4, %dx
    outb    %al, %dx
    movw    $0x3B5, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_CR0_UL             /* = 0x99 */

    /* ============ ACPI PM timer write-inert (OUT 0x608 = no-op) ====== */
    /* A 32-bit OUT to 0x608 is ignored in BOTH qemu (PM region disabled /
     * unassigned-write-ignored) and the RTL (acpi_pm_tmr_write does nothing),
     * so it retires identically. We never READ 0x608 (documented boundary). */
    movl    $0xDEADBEEF, %eax
    movw    $0x608, %dx
    outl    %eax, %dx
    movl    $0x01234567, %eax
    movw    $0x608, %dx
    outl    %eax, %dx

    /* ====================== deterministic end-state ======================= */
    movl    R_CRTC_C1, %esi             /* 0x5A (color CRTC witness)        */
    movl    R_CR0_UL,  %edi             /* 0x99 (CRTC unlock witness)       */
    movl    R_ATTI,    %ebp             /* 0x10 (attr flip-flop witness)    */
    xorl    %edx, %edx
    addl    R_SEQ1,  %edx               /* 0x3d */
    addl    R_GFX5,  %edx               /* + 0x7b */
    addl    R_DAC5,  %edx               /* + 0x66 = 0x011e */
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
