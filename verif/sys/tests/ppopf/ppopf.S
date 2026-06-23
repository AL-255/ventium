/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium — directed POPF EFLAGS-mask demonstrator (the DOS-Quake fix).
 *
 * POPF's writable-flag mask is MODE/CPL-aware (IA-32 SDM Vol.1 "POPF"):
 *   - status flags + TF/DF/NT/AC/ID : always writable (base 0x00244DD5).
 *   - IF   (0x200)                  : writable unless (PM && CPL>IOPL).
 *   - IOPL (0x3000)                 : writable ONLY at the highest privilege —
 *                                     REAL MODE, or PM CPL==0.
 *   - VM/RF                         : NEVER writable by POPF.
 *
 * The DOS-Quake bug: the core hardcoded the CPL>IOPL ("user") mask 0x00244DD5
 * for EVERY POPF, so a REAL-MODE `popfd` (CWSDPMI/go32 runs at cs=0x2593, PE=0)
 * kept IOPL=0 where the architecture (and qemu -cpu pentium) loads IOPL=3 + IF.
 * The stale IOPL propagated into the DPMI register frame and tripped CWSDPMI's
 * exception reporter. This test pins the architectural behaviour both ways:
 *
 *   PHASE A (REAL MODE, PE=0):
 *     push 0x00003202 (IOPL=3, IF=1, status flags clear) ; popfd
 *     -> EFLAGS must show IOPL=3 AND IF=1  (the bug kept IOPL=0).
 *     Then push 0x00000002 ; popfd  -> IOPL back to 0, IF back to 0
 *     (proves IOPL is genuinely writable in real mode, not stuck).
 *
 *   PHASE B (PROTECTED MODE, CPL=0):
 *     push 0x00002202 (IOPL=2, IF=1) ; popfd
 *     -> EFLAGS must show IOPL=2 AND IF=1 (CPL==0 => IOPL writable).
 *     Also try to set VM (0x20000) via popfd: it must STAY 0 (POPF never loads
 *     VM), and ID (0x200000) which IS in the base mask must take.
 *
 * Every retired instruction's EFLAGS is captured in the system golden and diffed
 * per-record vs qemu-system-i386 -cpu pentium. A core using the wrong (always
 * "user") mask diverges on the very POPFs above (IOPL/IF held at their old
 * value) and the diff FAILS; with the mode/CPL-aware mask it matches exactly.
 *
 * Self-check + exit: PHASE B verifies the loaded IOPL/IF via PUSHF read-back and
 * exits via isa-debug-exit (status 133) only if every check holds, so even the
 * final exit code is a guard.
 *
 * Build: gcc -m32 -ffreestanding (GNU-as syntax), objcopy -O binary, pad 64 KiB.
 */

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

    /* ===================== PHASE A — REAL MODE POPF ===================== */
    /* popfd loading IOPL=3 + IF in real mode: both must take. Use a 32-bit
     * operand popfd (0x66 0x9D) so the full EFLAGS image is popped. */
    pushl   $0x00003202             /* IOPL=3 (0x3000) | IF (0x200) | bit1 */
    .byte   0x66
    popf                            /* 66 9D = popfd : EFLAGS <- [esp] */
    /* read EFLAGS back (pushfd) into eax for the self-check later */
    .byte   0x66
    pushf                           /* 66 9C = pushfd */
    .byte   0x66
    popl    %eax                    /* eax = EFLAGS after the real-mode popfd */
    movl    %eax, %edi              /* stash: must have IOPL=3 + IF set */

    /* popfd loading IOPL=0 + IF=0: proves IOPL is genuinely writable (not stuck
     * at 3) in real mode. */
    pushl   $0x00000002
    .byte   0x66
    popf
    .byte   0x66
    pushf
    .byte   0x66
    popl    %ebx                    /* ebx = EFLAGS : IOPL must be 0 now */

    /* ============ PHASE A2 — 16-bit POPF must NOT touch EFLAGS[31:16] ========
     * task #102 (EFLAGS.ID root). A 16-bit popf (0x9D with NO 0x66, the
     * real-mode default) loads ONLY the low 16 EFLAGS bits; ID(21)/VM(17)/AC(18)
     * are UNTOUCHED. The DOS-Quake bug applied the 32-bit writable mask (which
     * includes ID) to the full 32-bit stack dword, so a 16-bit popf whose
     * [esp+2] word had bit21 set LEAKED ID=1. CWSDPMI/go32's switcher runs a
     * 16-bit `popf` (cs=0x0070:0x366) over a frame whose high word carried bit5
     * (=>EFLAGS bit21), wedging ID set vs qemu (which masks `&= 0xffff` for
     * MO_16). Here ID starts CLEAR; we push a dword with bit21 set as the NEXT
     * stack word and 16-bit-popf the low word — ID must stay 0. */
    /* ensure ID is currently 0: 32-bit popfd of a clean image */
    pushl   $0x00000002
    .byte   0x66
    popf
    /* lay [esp]=low 0x0202 to pop, [esp+2]=0x0020 (bit21 of the dword). A
     * 16-bit popf consumes only [esp] (2 bytes); [esp+2] must be ignored. */
    pushl   $0x00200202             /* high word 0x0020 carries bit21 */
    popfw                           /* 16-bit popf : EFLAGS[15:0] <- 0x0202 */
    .byte   0x66
    pushf
    .byte   0x66
    popl    %ecx                    /* ecx = EFLAGS : ID(0x200000) MUST be 0 */
    /* tidy the stack (popfw consumed 2 bytes; drop the leftover high word) */
    addw    $2, %sp

    /* --- build a flat GDT (3 entries) at linear 0x0500, enter protected mode --- */
    movl    $0x00000500, %ebp
    movl    $0x00000000, 0(%ebp)
    movl    $0x00000000, 4(%ebp)
    movl    $0x0000FFFF, 8(%ebp)    /* 0x08 code32 base=0 G=1 D=1 type=0xA */
    movl    $0x00CF9A00, 12(%ebp)
    movl    $0x0000FFFF, 16(%ebp)   /* 0x10 data32 flat */
    movl    $0x00CF9200, 20(%ebp)
    movw    $0x0017, 0x0480         /* gdt limit = 24-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0
    .byte   0x66, 0xEA              /* far jump -> 32-bit code seg 0x08 */
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

    /* ===================== PHASE B — PM CPL=0 POPF ===================== */
    /* CPL==0 => IOPL IS writable. popfd IOPL=2 + IF=1; VM must NOT load; ID
     * (base-mask) must load. Push IOPL=2 | IF | VM(try) | ID. */
    pushl   $0x00222202             /* ID(0x200000)|VM(0x20000 try)|IOPL2|IF|bit1 */
    popf                            /* 9D = popfd (32-bit default in CS.D=1) */
    pushf
    popl    %esi                    /* esi = EFLAGS : IOPL=2, IF=1, ID=1, VM=0 */

    /* ============ verify ============ */
    /* edi (real-mode popfd) must have IOPL=3 (0x3000) AND IF (0x200) set. */
    movl    %edi, %eax
    andl    $0x00003200, %eax
    cmpl    $0x00003200, %eax
    jne     fail

    /* ebx (real-mode popfd #2) must have IOPL=0 AND IF=0. */
    movl    %ebx, %eax
    andl    $0x00003200, %eax
    cmpl    $0x00000000, %eax
    jne     fail

    /* ecx (PHASE A2, 16-bit popf) must have ID(0x200000) CLEAR — the 16-bit
     * popf must NOT leak the stack high word into EFLAGS[31:16]. */
    movl    %ecx, %eax
    andl    $0x00200000, %eax
    cmpl    $0x00000000, %eax
    jne     fail

    /* esi (PM CPL0 popfd) must have IOPL=2 (0x2000), IF (0x200), ID (0x200000)
     * set and VM (0x20000) CLEAR. */
    movl    %esi, %eax
    andl    $0x00222200, %eax       /* mask IOPL|VM|IF|ID fields */
    cmpl    $0x00202200, %eax       /* want IOPL=2 + IF + ID, VM clear */
    jne     fail

    /* success: exit via isa-debug-exit, code 0x42 -> status 133 */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hang:
    hlt
    jmp     hang

fail:
    /* a DIFFERENT exit code so a mask regression is caught even by the exit RC */
    movl    $0x21, %eax             /* -> status (0x21<<1)|1 = 67, != 133 */
    movw    $0xF4, %dx
    outb    %al, %dx
fhang:
    hlt
    jmp     fhang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
