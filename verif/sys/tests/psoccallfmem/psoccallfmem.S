/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — real-mode FAR INDIRECT CALL (FF /3) + FAR INDIRECT JMP (FF /5) firmware
 * (psoccallfmem.bin).
 *
 * Directed differential for the recently-added far-indirect-through-memory paths,
 * which previously had NO gate (only direct 9A CALLF / CB RETF were gated, M9.5).
 * Every transfer reads a m16:16 far pointer from memory, so this exercises BOTH the
 * 16-bit ModRM EA generation feeding the far-pointer load AND the CS:IP push/pop:
 *
 *   A: call far [bx]      FF 1F        (mod=00 rm=111, DS default)
 *   B: call far [bp+8]    FF 5E 08     (mod=01 rm=110, SS DEFAULT segment!)
 *   C: call far [disp16]  FF 1E dd dd  (mod=00 rm=110, DS default)
 *   D: call far [bx+si]   FF 18        (mod=00 rm=000, two-component EA;
 *                                       a 4-byte DECOY precedes the real entry so
 *                                       an EA that ignores SI reads garbage)
 *   E: NESTED: call far [bx] -> outer callee does call far [disp16] -> inner,
 *      inner RETFs, outer captures SP, RETFs
 *   F: jmp far [bx]       FF 2F        (mod=00 rm=111) -> landF (fall-through = trap)
 *   G: jmp far [bp+6]     FF 6E 06     (mod=01 rm=110, SS default) -> landG (trap)
 *
 * After EVERY RETF return the very next instruction captures SP into DX (DI inside
 * the nested outer callee), so any push/pop width or SP-delta error shows in the
 * per-record register diff immediately. Each callee/landing pad writes a distinct
 * CX marker (0x1111..0x8888) used as non-vacuous landmarks by the gate. All far
 * pointers for the DS-default forms live in a table inside this ROM image (DS=F000);
 * the SS-default forms write their far pointer into stack RAM at runtime first.
 *
 * Fully synchronous (CLI'd, no IRQs), so the gen_trace.py --system single-step
 * golden is a valid per-record oracle. cr0 stays the reset 0x60000010 (pure real
 * mode). All FF-form transfers are emitted as explicit bytes so the ModRM encodings
 * are pinned. Ends with the standard isa-debug-exit OUT.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp
    movw    $0xF000, %ax
    movw    %ax, %ds                    /* DS=F000: the in-image far-ptr tables are readable */

    /* --- A: call far [bx]  (FF /3, mod=00 rm=111, DS default) ------------- */
    movw    $ftabA_off, %bx
    .byte   0xFF, 0x1F                  /* call far [bx] -> calleeA */
    movw    %sp, %dx                    /* capture SP right after the RETF */

    /* --- B: call far [bp+8] (FF /3, mod=01 rm=110, SS DEFAULT!) ----------- */
    movw    $0x6000, %bp
    movw    $calleeB_off, %ax
    movw    %ax, 8(%bp)                 /* SS:0x6008 = callee offset */
    movw    $0xF000, %ax
    movw    %ax, 10(%bp)                /* SS:0x600A = callee segment */
    .byte   0xFF, 0x5E, 0x08            /* call far [bp+8] -> calleeB */
    movw    %sp, %dx

    /* --- C: call far [disp16] (FF /3, mod=00 rm=110, DS default) ---------- */
    .byte   0xFF, 0x1E
    .word   ftabC_off                   /* call far [ftabC] -> calleeC */
    movw    %sp, %dx

    /* --- D: call far [bx+si] (FF /3, mod=00 rm=000, two-component EA) ----- */
    movw    $ftabD_off, %bx
    movw    $4, %si                     /* real entry is at ftabD+4 (decoy at +0) */
    .byte   0xFF, 0x18                  /* call far [bx+si] -> calleeD */
    movw    %sp, %dx

    /* --- E: NESTED far indirect call ---------------------------------------- */
    movw    $ftabE_off, %bx
    .byte   0xFF, 0x1F                  /* call far [bx] -> calleeEo (which nests) */
    movw    %sp, %dx

    /* --- F: jmp far [bx]  (FF /5, mod=00 rm=111) --------------------------- */
    movw    $jtabF_off, %bx
    .byte   0xFF, 0x2F                  /* jmp far [bx] -> landF */
trapF:                                  /* fall-through = far JMP did nothing */
    movw    $0xDEAD, %cx
1:  hlt
    jmp     1b

    .global landF
landF:
    movw    $0x7777, %cx                /* far JMP [bx] landed */
    movw    %sp, %dx
    /* --- G: jmp far [bp+6] (FF /5, mod=01 rm=110, SS default) ------------- */
    movw    $0x6100, %bp
    movw    $landG_off, %ax
    movw    %ax, 6(%bp)                 /* SS:0x6106 = landing offset */
    movw    $0xF000, %ax
    movw    %ax, 8(%bp)                 /* SS:0x6108 = landing segment */
    .byte   0xFF, 0x6E, 0x06            /* jmp far [bp+6] -> landG */
trapG:                                  /* fall-through = far JMP did nothing */
    movw    $0xBEEF, %cx
1:  hlt
    jmp     1b

    .global landG
landG:
    movw    $0x8888, %cx                /* far JMP [bp+6] landed */
    .global done
done:
    movw    $0x1111, %bx                /* final landmark */
    /* isa-debug-exit: out 0xf4, al=0x42 -> process status (0x42<<1)|1 = 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    /* ---- the far-called routines (same segment F000) --------------------- */
    .global calleeA, calleeB, calleeC, calleeD, calleeEo, calleeEi
calleeA:
    movw    $0x1111, %cx
    .byte   0xCB                        /* RETF */
calleeB:
    movw    $0x2222, %cx
    .byte   0xCB
calleeC:
    movw    $0x3333, %cx
    .byte   0xCB
calleeD:
    movw    $0x4444, %cx
    .byte   0xCB
calleeEo:                               /* nested outer: far-indirect-calls inner */
    movw    $0x5555, %cx
    .byte   0xFF, 0x1E
    .word   ftabEi_off                  /* call far [ftabEi] -> calleeEi */
    movw    %sp, %di                    /* capture SP inside outer after inner RETF */
    movw    $0x6655, %cx                /* resumed-inside-outer marker */
    .byte   0xCB
calleeEi:                               /* nested inner */
    movw    $0x6666, %cx
    .byte   0xCB

    /* ---- far-pointer tables (ROM, read via DS=F000) ----------------------- */
    .align  4
    .global ftabA, ftabC, ftabD, ftabE, ftabEi, jtabF
ftabA:  .word calleeA_off,  0xF000
ftabC:  .word calleeC_off,  0xF000
ftabD:  .word 0xDEAD,       0xDEAD      /* +0: DECOY (an EA ignoring SI reads this) */
        .word calleeD_off,  0xF000      /* +4: the real entry (bx+si points here) */
ftabE:  .word calleeEo_off, 0xF000
ftabEi: .word calleeEi_off, 0xF000
jtabF:  .word landF_off,    0xF000

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA                        /* far jmp 0xF000:_start16_off */
    .word   _start16_off
    .word   0xF000
