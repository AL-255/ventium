/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M8.6 — bare-metal VGA mode-13h CHAIN-4 framebuffer differential test.
 *
 * Exercises the CPU-visible VGA *video memory* (0xA0000) that M8.6 adds to
 * ventium_soc as a real on-die VRAM module (ven_vga_fb). Same per-record-
 * differential shape as psocdev/pvga: NO interrupts, every interaction a
 * SYNCHRONOUS IN/OUT or memory access, so qemu-system's gdbstub single-step
 * (gen_trace.py --system) is a valid per-record oracle (compare.py --mode func
 * grades GPRs per retired instruction, so a load of a written pixel into a GPR
 * is directly diffable).
 *
 * THE CHAIN-4-FIRST CONTRACT (oracle boundary):
 *   qemu's VGA memory at 0xA0000 takes the LINEAR chain-4 path only after the
 *   sequencer is put in chain-4 mode (SR4.CHN_4M=1) with a memory-map window
 *   covering 0xA0000. Before that it is the PLANAR/latched path (NOT modelled by
 *   this slice). The test therefore sets chain-4 mode FIRST and NEVER touches
 *   0xA0000 until after — and the RTL gates its VRAM intercept on the SAME
 *   chain-4-enable bits, so a pre-chain-4 access would fall through to backing
 *   RAM (it never happens here). The DAC palette, scan-out/pixel rendering, the
 *   planar/latched write-modes 0-3, read-mode 1, rotate/bit-mask/set-reset/odd-
 *   even, and the 0xB0000/0xB8000 windows are all EXCLUDED (board/unit boundary).
 *
 * WHAT IT PROVES byte-identical to qemu-system over every retired instruction:
 *   * the 0xA0000 window is recognised as VRAM (writes land, reads return them),
 *   * chain-4 linear identity: a byte written at 0xA0000+N reads back at +N,
 *   * per-byte PLANE GATING: with SR2 (plane-write mask) != 0x0F, a write only
 *     lands in the lanes whose plane bit (addr&3) is enabled; the masked lanes
 *     keep their prior value EXACTLY as qemu does (the property that a plain-RAM
 *     0xA0000 would get WRONG — the reason the dedicated VRAM module exists).
 *
 * Memory plan (-m 32, NO paging, linear==physical):
 *   GDT @ 0x0500, results @ 0x2000, stack @ 0x90000, VRAM @ 0xA0000 (chain-4).
 */

    .equ RES_P0,   0x00002000  /* [0xA0000] = 0x11 */
    .equ RES_P1,   0x00002004  /* [0xA0001] = 0x22 */
    .equ RES_P2,   0x00002008  /* [0xA0002] = 0x33 */
    .equ RES_P3,   0x0000200C  /* [0xA0003] = 0x44 */
    .equ RES_P4,   0x00002010  /* [0xA0010] = 0x55 */
    .equ RES_P5,   0x00002014  /* [0xAF000] = 0x66 (high offset) */
    .equ RES_G0,   0x00002018  /* plane-gated [0xA0100] (plane0 on)  = 0x11 */
    .equ RES_G1,   0x0000201C  /* plane-gated [0xA0101] (plane1 off) = 0xBB (kept) */
    .equ RES_G2,   0x00002020  /* plane-gated [0xA0102] (plane2 on)  = 0x33 */
    .equ RES_G3,   0x00002024  /* plane-gated [0xA0103] (plane3 off) = 0xDD (kept) */

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
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
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

    /* ============ put the VGA into mode-13h CHAIN-4 (linear @ 0xA0000) ===== */
    /* Sequencer index 2 (plane write mask) = 0x0F (all four planes) */
    movw    $0x03C4, %dx
    movb    $0x02, %al
    outb    %al, %dx
    movw    $0x03C5, %dx
    movb    $0x0F, %al
    outb    %al, %dx
    /* Sequencer index 4 (memory mode) = 0x0E (extended | CHN_4M(bit3) | seq) */
    movw    $0x03C4, %dx
    movb    $0x04, %al
    outb    %al, %dx
    movw    $0x03C5, %dx
    movb    $0x0E, %al
    outb    %al, %dx
    /* Graphics index 6 (misc) = 0x05 (graphics + memory-map mode 1 = 0xA0000 64K) */
    movw    $0x03CE, %dx
    movb    $0x06, %al
    outb    %al, %dx
    movw    $0x03CF, %dx
    movb    $0x05, %al
    outb    %al, %dx
    /* Graphics index 5 (mode) = 0x40 (256-colour shift, write mode 0) */
    movw    $0x03CE, %dx
    movb    $0x05, %al
    outb    %al, %dx
    movw    $0x03CF, %dx
    movb    $0x40, %al
    outb    %al, %dx

    /* ============ chain-4 LINEAR write / read-back (SR2=0x0F all planes) === */
    movb    $0x11, 0x000A0000        /* plane 0 */
    movb    $0x22, 0x000A0001        /* plane 1 */
    movb    $0x33, 0x000A0002        /* plane 2 */
    movb    $0x44, 0x000A0003        /* plane 3 */
    movb    $0x55, 0x000A0010
    movb    $0x66, 0x000AF000        /* high offset within the 64K window */

    movzbl  0x000A0000, %eax
    movl    %eax, RES_P0
    movzbl  0x000A0001, %eax
    movl    %eax, RES_P1
    movzbl  0x000A0002, %eax
    movl    %eax, RES_P2
    movzbl  0x000A0003, %eax
    movl    %eax, RES_P3
    movzbl  0x000A0010, %eax
    movl    %eax, RES_P4
    movzbl  0x000AF000, %eax
    movl    %eax, RES_P5

    /* ============ per-byte PLANE GATING (the plain-RAM-divergent case) ===== */
    /* establish a known prior value at 0xA0100..0xA0103 with all planes on */
    movb    $0xAA, 0x000A0100
    movb    $0xBB, 0x000A0101
    movb    $0xCC, 0x000A0102
    movb    $0xDD, 0x000A0103
    /* restrict plane-write mask to planes 0 and 2 (SR2 = 0x05) */
    movw    $0x03C4, %dx
    movb    $0x02, %al
    outb    %al, %dx
    movw    $0x03C5, %dx
    movb    $0x05, %al
    outb    %al, %dx
    /* overwrite all four: only planes 0,2 (offsets &3 == 0,2) may change */
    movb    $0x11, 0x000A0100        /* plane 0: ON  -> 0x11 */
    movb    $0x22, 0x000A0101        /* plane 1: OFF -> keeps 0xBB */
    movb    $0x33, 0x000A0102        /* plane 2: ON  -> 0x33 */
    movb    $0x44, 0x000A0103        /* plane 3: OFF -> keeps 0xDD */
    /* restore all planes */
    movw    $0x03C4, %dx
    movb    $0x02, %al
    outb    %al, %dx
    movw    $0x03C5, %dx
    movb    $0x0F, %al
    outb    %al, %dx

    movzbl  0x000A0100, %eax
    movl    %eax, RES_G0
    movzbl  0x000A0101, %eax
    movl    %eax, RES_G1
    movzbl  0x000A0102, %eax
    movl    %eax, RES_G2
    movzbl  0x000A0103, %eax
    movl    %eax, RES_G3

    /* ====================== clean exit via isa-debug-exit ================= */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hang:
    hlt
    jmp     hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
