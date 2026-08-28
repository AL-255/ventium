/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * psmmmeta — the RSM hidden-metadata restore: the SMI entry shadows
 * seg_pm_loaded[], seg_b[] and ss_b, and RSM must put back the PRE-SMI
 * values, not the SMM handler's. Witness-graded (the qemu gdbstub masks SMI,
 * so no differential trace of SMM is possible -- the psmm oracle
 * infeasibility). The image also runs to the isa-debug-exit under
 * free-running QEMU (exit 133): QEMU implements SMM/RSM with the same
 * architectural restore, so the witnesses match.
 *
 * Five SMI rounds, one image, every check through EXTERNALLY VISIBLE
 * behavior (never a selector/base dump). The SMM handler proves its own view
 * works, then deliberately MUTATES the metadata: it sets CR0.PE, far-jumps
 * into a 32-bit protected-mode code segment, and PM-loads SS with a width
 * the mainline did NOT have (16-bit vs 32-bit, chosen by a round id). A
 * restore that leaks the handler's metadata into the resumed context flips
 * the stack width of the first post-RSM push.
 *
 *   Case A (provenance): DS and SS are NEVER reloaded after CR0.PE -- they
 *     keep their real-mode hidden caches (sel=0, base=0, limit 0xFFFF,
 *     not-PM-loaded). The handler PM-loads a 16-bit SS (ss_b=0) and a flat
 *     DS (PM-marking it). After RSM, a high-ESP push must behave EXACTLY as
 *     the identical pre-SMI push did (same ESP advance, same write target:
 *     SP-relative 16-bit form vs ESP-relative 32-bit form), and in-bounds
 *     uses of the sel=0 segments must not fault. (On this build the
 *     unreloaded SS's width register still holds the reset-time 32-bit
 *     default, so both pushes take the 32-bit form; QEMU takes the 16-bit
 *     form. The check is pre/post EQUALITY, valid on both.)
 *   Case B (16-bit SS): the mainline PM-loads SS with a B=0 descriptor
 *     (16-bit stack). The handler loads a B=1 SS. After RSM the push must
 *     take the 16-bit form again (SP moves within the low 64K, ESP's high
 *     half preserved) -- a leaked ss_b=1 takes the 32-bit form instead.
 *   Case C (32-bit SS): the mainline PM-loads SS with a B=1 descriptor.
 *     The handler loads a B=0 SS. After RSM the push must take the 32-bit
 *     form again.
 *   Case D (data-segment D/B, TWO SMI rounds, expand-down DS): an
 *     expand-down data segment's valid offsets are (limit, upper] with
 *     upper = 0xFFFF for B=0 and 0xFFFFFFFF for B=1, so an access at
 *     0x10000 against limit 0x0FFF is legal for B=1 and a #GP for B=0 --
 *     the only consumer of seg_b[DS] in the enforcing build. Polarity 1:
 *     the mainline loads DS with B=1 (access legal), the handler loads it
 *     with B=0; the post-RSM access must STILL be legal. Polarity 2: the
 *     mainline loads B=0 (access faults), the handler loads B=1; the
 *     post-RSM access must fault exactly as the pre-SMI one did. The
 *     discrimination needs segment-limit enforcement (the +VEN_SEG_ENFORCE
 *     variant build); on a non-enforcing build every access succeeds and
 *     both polarities degrade to vacuous pre/post equality.
 *
 * The image SELF-CALIBRATES enforcement: an early probe loads ES with the
 * expand-down B=0 descriptor and accesses 0x10000 (ES, because case A
 * requires DS/SS never reloaded). If that faults, limits are enforced and
 * case A's high-ESP stack probes would #SS against the unreloaded SS's
 * real-mode 0xFFFF limit, so case A drops ESP to 0x0000FFF0 -- the two
 * stack forms coincide inside 64 KiB, so case A degrades to (still valid)
 * vacuous equality on enforcing builds and keeps full form discrimination
 * on the non-enforcing canonical build and the QEMU free-run.
 *
 * Width observables (one pushl %eax at ESP=0x00010010):
 *   32-bit form: ESP=0x0001000C, the dword lands at SS:0x0001000C.
 *   16-bit form: ESP=0x0001000C but only SP moved (0x000C), the dword lands
 *   at SS:0x000C -- the two forms write DIFFERENT addresses.
 * The post-SMI push re-poisons both candidates and uses a different value,
 * so exactly one form matches.
 *
 * Witnesses (final record): edi=0x42 pass (per-check fail codes in the
 * header map), esi=5 (rounds completed), ebx=0x5AA30003 (handler completed
 * its PM stay), ebp=0x5AA20002 (the handler's own stack worked at ITS
 * mutated width), ecx = fault count (0 on a non-enforcing build, 2 on an
 * enforcing one: polarity 2's pre and post faults; the probe's own fault is
 * accounted for and the counter zeroed before case A), edx=0x600D600D.
 *
 * Check->exit-code map (fail edi; pass = 0x42):
 *   01 case A post push != pre push (ESP advance or write target changed)
 *   02 case A/B/C in-bounds sel=0 DS read clobbered or faulted
 *   03 case A: an unexpected fault fired
 *   11 case B pre push not 16-bit-form   12 case B post push not 16-bit-form
 *   21 case C pre push not 32-bit-form   22 case C post push not 32-bit-form
 *   30 handler-stack sentinel wrong      31 handler never completed
 *   32 SMM-view sentinel wrong
 *   41 case D pol1 pre access faulted (B=1 must be legal: control broken)
 *   43 case D pol1 post-RSM access faulted -- the handler's B=0 LEAKED
 *   44 case D pol2 post-RSM legality != pre-SMI legality -- restore wrong
 *   7D unexpected #GP   7E unexpected #PF   7F unexpected #DF
 *
 * Memory plan (NO paging; linear == physical): GDT @0x500 (code32 0x08,
 * data32/B=1 0x10, data16/B=0 0x18, expand-down B=1 0x20, expand-down B=0
 * 0x28, both limit 0x0FFF), IDT @0x1000, markers @0x2000..0x2360,
 * handler @0x38000 (SMM entry, CS base = SMBASE = 0x30000), save map
 * @0x3FE00, APIC @0xFEE00000. GNU-as; no nasm. Flat 64 KiB -bios image.
 */

.set IDT,      0x00001000
.set EXPECTGP, 0x00002204
.set SKIPGP,   0x00002208
.set ROUND,    0x00002200
.set XPECT,    0x00002348	/* expected-#GP token for the probe + case D */
.set XSKIP,    0x0000234C	/* its resume-past-the-insn skip length */
.set ENF,      0x00002350	/* probe result: 1 iff segment limits are enforced */
.set DPRE,     0x00002354	/* case D pol2: pre-SMI fault delta */

/* ============================ 16-bit entry =============================== */
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

    /* GDT @ 0x500: null, 0x08 code32 (B=1), 0x10 data32 (B=1), 0x18 data16
     * (B=0), 0x20/0x28 expand-down data (B=1 / B=0). All base 0; the first
     * three 4 GiB limit (G=1), the expand-down pair byte-granular limit
     * 0x0FFF. */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* 0x08 code32 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* 0x10 data32, B=1 (gran 0xCF) */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* 0x18 data32-limited, B=0 (gran 0x8F) */
    movl    $0x008F9200, 28(%ebx)
    movl    $0x00000FFF, 32(%ebx)       /* 0x20 expand-down data, B=1, limit 0x0FFF */
    movl    $0x00409700, 36(%ebx)
    movl    $0x00000FFF, 40(%ebx)       /* 0x28 expand-down data, B=0, limit 0x0FFF */
    movl    $0x00009700, 44(%ebx)
    movw    $0x002F, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry
    .word   0x08

/* ============================ 32-bit body ================================ */
    .code32
    .section .text32, "ax"
    .global pm_entry
pm_entry:
    /* DS and SS are deliberately NOT reloaded: they keep the real-mode
     * hidden cache (sel=0, base=0, limit 0xFFFF, not-PM-loaded) for case A.
     * ES gets the flat 32-bit data selector for high-address setup work. */
    movw    $0x10, %ax
    movw    %ax, %es
    movl    $0x00007000, %esp

    /* zero the marker area 0x2000..0x2380 */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $224, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* IDT @ 0x1000: zero all gates; 8->df, 13->gp, 14->pf */
    movl    $IDT, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $df_entry, %ebx
    movl    $(IDT + 8*8), %edi
    call    set_gate0
    movl    $gp_handler, %ebx
    movl    $(IDT + 13*8), %edi
    call    set_gate0
    movl    $pf_entry, %ebx
    movl    $(IDT + 14*8), %edi
    call    set_gate0
    movw    $0x07FF, 0x0490
    movl    $IDT, 0x0492
    lidt    0x0490

    /* install the SMM handler at SMBASE+0x8000 = 0x38000, via ES (the image
     * sits past 64K and DS stays the unreloaded sel=0 form) */
    movl    $smm_handler, %esi
    movl    $0x00038000, %edi
    movl    $smm_handler_end - smm_handler, %ecx
1:  movzbl  %es:(%esi), %eax
    movb    %al, %es:(%edi)
    incl    %esi
    incl    %edi
    loop    1b

    /* enable the local APIC (SVR @ 0xFEE000F0, bit 8), via ES */
    movl    $0xFEE000F0, %edi
    movl    %es:(%edi), %eax
    orl     $0x100, %eax
    movl    %eax, %es:(%edi)

    movl    $0x5AA0000A, 0x0000210C     /* in-bounds DS-read marker */

    /* ---- enforcement probe: does this build enforce segment limits? ----
     * ES (case A needs DS/SS pristine) <- expand-down B=0, limit 0x0FFF:
     * an access at 0x10000 is above the B=0 upper bound, so it #GPs iff
     * limits are enforced. The GP handler counts + skips it. */
    movw    $0x28, %ax
    movw    %ax, %es
    movl    0x00002340, %ebx            /* fault count before */
    movl    $0xE0, XPECT
    movl    $6, XSKIP                   /* 26 A1 moffs32: seg override + 5 */
    movl    %es:0x00010000, %eax        /* faults iff limits are enforced */
    movl    $0, XPECT
    xorl    %eax, %eax
    cmpl    %ebx, 0x00002340
    setne   %al
    movl    %eax, ENF                   /* 1 = enforcing build */
    movl    $0, 0x00002340              /* the probe's fault is accounted for;
                                         * the counter now tracks faults from
                                         * case A onward (the final witness) */
    movw    $0x10, %ax                  /* ES <- flat again */
    movw    %ax, %es

    /* ======================= case A: unreloaded DS/SS (provenance) ====== *
     * The handler will PM-load a 16-bit SS (ss_b=0) and PM-mark DS. The
     * post-RSM push must behave EXACTLY like the pre-SMI one. */
    movl    $2, ROUND                   /* handler: load SS with B=0 */
    movl    $0x00010010, %esp
    cmpl    $0, ENF
    je      .La_esp_pre
    movl    $0x0000FFF0, %esp           /* enforcing build: stay inside the
                                         * unreloaded SS's 64K real-mode
                                         * limit; the two forms coincide
                                         * below 64K, so case A degrades to
                                         * (still valid) vacuous equality */
.La_esp_pre:
    movl    $0, 0x0000000C
    movl    $0, %es:0x0001000C
    movl    $0xA1A1A1A1, %eax
    pushl   %eax                        /* the reference push */
    movl    %esp, 0x00002300            /* record: ESP advance ... */
    movl    0x0000000C, %eax
    movl    %eax, 0x00002304            /* ... the 16-bit-form target ... */
    movl    %es:0x0001000C, %eax
    movl    %eax, 0x00002308            /* ... the 32-bit-form target */
    movl    0x0000210C, %eax            /* in-bounds use of the sel=0 DS */
    movl    %eax, 0x0000230C
    call    fire_smi

    movl    $0x00010010, %esp           /* RSM restored the old ESP; reset */
    cmpl    $0, ENF
    je      .La_esp_post
    movl    $0x0000FFF0, %esp           /* same enforcing-build limit stay */
.La_esp_post:
    movl    $0, 0x0000000C
    movl    $0, %es:0x0001000C
    movl    $0xA2A2A2A2, %eax
    pushl   %eax                        /* the post-RSM push */
    movl    %esp, 0x00002310
    movl    0x0000000C, %eax
    movl    %eax, 0x00002314
    movl    %es:0x0001000C, %eax
    movl    %eax, 0x00002318
    movl    0x0000210C, %eax
    movl    %eax, 0x0000231C

    /* case A checks: ESP advance equal, same write FORM both times, the
     * in-bounds reads equal, no faults */
    movl    0x00002300, %eax
    cmpl    0x00002310, %eax
    je      1f
    movl    $0x01, %edi
    jmp     fail_exit
1:  xorl    %eax, %eax
    cmpl    $0, 0x00002304
    setne   %al
    cmpl    $0, 0x00002314
    setne   %ah
    cmpb    %ah, %al
    je      2f
    movl    $0x01, %edi
    jmp     fail_exit
2:  xorl    %eax, %eax
    cmpl    $0, 0x00002308
    setne   %al
    cmpl    $0, 0x00002318
    setne   %ah
    cmpb    %ah, %al
    je      3f
    movl    $0x01, %edi
    jmp     fail_exit
3:  movl    0x0000230C, %eax
    cmpl    $0x5AA0000A, %eax
    jne     4f
    cmpl    0x0000231C, %eax
    je      5f
4:  movl    $0x02, %edi
    jmp     fail_exit
5:  cmpl    $0, 0x00002340
    je      6f
    movl    $0x03, %edi
    jmp     fail_exit
6:

    /* ======================= case B: 16-bit SS -> handler loads 32-bit === */
    movw    $0x18, %ax                  /* SS <- data16 (B=0): 16-bit stack */
    movw    %ax, %ss
    movl    $1, ROUND                   /* handler: load SS with B=1 */
    movl    $0x00010010, %esp
    movl    $0, 0x0000000C
    movl    $0, %es:0x0001000C
    movl    $0xB1B1B1B1, %eax
    pushl   %eax
    cmpl    $0xB1B1B1B1, 0x0000000C     /* 16-bit form: lands at SP (low 64K) */
    jne     11f
    cmpl    $0, %es:0x0001000C          /* nothing at the 32-bit-form target */
    jne     11f
    cmpl    $0x0001000C, %esp           /* SP moved, ESP high half preserved */
    je      12f
11: movl    $0x11, %edi
    jmp     fail_exit
12: call    fire_smi

    movl    $0x00010010, %esp
    movl    $0, 0x0000000C
    movl    $0, %es:0x0001000C
    movl    $0xB2B2B2B2, %eax
    pushl   %eax
    cmpl    $0xB2B2B2B2, 0x0000000C     /* post-RSM: STILL the 16-bit form */
    jne     13f
    cmpl    $0, %es:0x0001000C
    jne     13f
    cmpl    $0x0001000C, %esp
    je      14f
13: movl    $0x12, %edi
    jmp     fail_exit
14:

    /* ======================= case C: 32-bit SS -> handler loads 16-bit === */
    movw    $0x10, %ax                  /* SS <- data32 (B=1): 32-bit stack */
    movw    %ax, %ss
    movl    $2, ROUND                   /* handler: load SS with B=0 */
    movl    $0x00010010, %esp
    movl    $0, 0x0000000C
    movl    $0, %es:0x0001000C
    movl    $0xC1C1C1C1, %eax
    pushl   %eax
    cmpl    $0xC1C1C1C1, %es:0x0001000C /* 32-bit form: lands at SS:ESP-4 */
    jne     21f
    cmpl    $0, 0x0000000C              /* nothing at the 16-bit-form target */
    jne     21f
    cmpl    $0x0001000C, %esp
    je      22f
21: movl    $0x21, %edi
    jmp     fail_exit
22: call    fire_smi

    movl    $0x00010010, %esp
    movl    $0, 0x0000000C
    movl    $0, %es:0x0001000C
    movl    $0xC2C2C2C2, %eax
    pushl   %eax
    cmpl    $0xC2C2C2C2, %es:0x0001000C /* post-RSM: STILL the 32-bit form */
    jne     23f
    cmpl    $0, 0x0000000C
    jne     23f
    cmpl    $0x0001000C, %esp
    je      24f
23: movl    $0x22, %edi
    jmp     fail_exit
24:

    /* ======================= case D: data-segment D/B (seg_b[DS]) ========
     * Expand-down DS, limit 0x0FFF: an access at 0x10000 is legal for B=1
     * and a #GP for B=0 -- on an enforcing build this is the only consumer
     * of seg_b[DS]. Both polarities, pre/post grading keyed off the pre-SMI
     * outcome so the same image is valid with and without enforcement. The
     * handler loads DS with the OPPOSITE B (round 3: B=0, round 4: B=1).
     * EXPECTGP is zeroed after each SMI: the handler stashes the round id
     * in the same dword, and a stale nonzero there would make a genuinely
     * unexpected #GP look expected. */
    /* ---- polarity 1: mainline B=1 (legal), handler B=0 ---- */
    movw    $0x20, %ax
    movw    %ax, %ds                    /* DS = expand-down, B=1 */
    movl    $0, EXPECTGP
    movl    0x00002340, %ebx            /* fault count before */
    movl    $0xD1, XPECT
    movl    $5, XSKIP
    movl    0x00010000, %eax            /* pre-SMI access: legal for B=1 */
    movl    $0, XPECT
    cmpl    %ebx, 0x00002340
    je      .Ld_p1pre_ok
    movl    $0x41, %edi                 /* B=1 access faulted: control broken */
    jmp     fail_exit
.Ld_p1pre_ok:
    movl    $3, ROUND                   /* handler: DS <- expand-down B=0 */
    call    fire_smi
    movl    $0, EXPECTGP
    movl    $0xD2, XPECT
    movl    $5, XSKIP
    movl    0x00010000, %eax            /* post-RSM: must STILL be legal */
    movl    $0, XPECT
    cmpl    %ebx, 0x00002340
    je      .Ld_p1post_ok
    movl    $0x43, %edi                 /* faulted: the handler's B=0 LEAKED */
    jmp     fail_exit
.Ld_p1post_ok:
    /* ---- polarity 2: mainline B=0 (illegal), handler B=1 ---- */
    movw    $0x28, %ax
    movw    %ax, %ds                    /* DS = expand-down, B=0 */
    movl    0x00002340, %ebx
    movl    $0xD3, XPECT
    movl    $5, XSKIP
    movl    0x00010000, %eax            /* pre-SMI: faults iff enforced */
    movl    $0, XPECT
    movl    0x00002340, %eax
    subl    %ebx, %eax
    movl    %eax, DPRE                  /* pre delta: 1 enforcing, 0 not */
    movl    $4, ROUND                   /* handler: DS <- expand-down B=1 */
    call    fire_smi
    movl    $0, EXPECTGP
    movl    $0xD4, XPECT
    movl    $5, XSKIP
    movl    0x00010000, %eax            /* post-RSM: same legality as pre */
    movl    $0, XPECT
    movl    0x00002340, %eax
    subl    %ebx, %eax
    subl    DPRE, %eax                  /* post delta */
    cmpl    DPRE, %eax
    je      .Ld_p2_ok
    movl    $0x44, %edi                 /* post legality != pre: restore wrong */
    jmp     fail_exit
.Ld_p2_ok:
    movw    $0x10, %ax                  /* DS <- flat for the sentinel fold */
    movw    %ax, %ds

    /* ======================= sentinels + fold + exit ===================== */
    cmpl    $0x5AA20002, 0x00002104     /* the handler's own stack worked */
    je      1f
    movl    $0x30, %edi
    jmp     fail_exit
1:  cmpl    $0x5AA30003, 0x00002108     /* the handler completed its PM stay */
    je      2f
    movl    $0x31, %edi
    jmp     fail_exit
2:  cmpl    $0x5AA10001, 0x00002100     /* the handler's SMM view worked */
    je      3f
    movl    $0x32, %edi
    jmp     fail_exit
3:
    movl    $0x42, %edi                 /* PASS */
    movl    $5, %esi                    /* five SMI rounds completed */
    movl    0x00002108, %ebx
    movl    0x00002104, %ebp
    movl    0x00002340, %ecx            /* fault count (0 on this build) */
    movl    $0x600D600D, %edx
    movl    %edi, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

/* ======================= helpers =========================================
 * fire_smi: dispatch the APIC self-IPI in SMI mode, then spin so the SMI
 * has room to land. RSM resumes inside the spin, which then runs out. */
fire_smi:
    movl    $0xFEE00300, %edi
    movl    $0x00040200, %eax           /* dest-shorthand=self | mode=SMI */
    movl    %eax, %es:(%edi)
    movl    $4096, %ecx
1:  pause
    loop    1b
    ret

    .align 16
    .global gp_handler
gp_handler:                             /* unexpected on this build */
    cmpl    $0, EXPECTGP
    je      1f
    incl    0x00002340                  /* fault count */
    movl    EXPECTGP, %eax
    movl    %eax, 0x00002344            /* last fault marker */
    movl    $0, EXPECTGP
    movl    SKIPGP, %eax
    addl    %eax, 4(%esp)               /* resume past the faulting insn */
    addl    $4, %esp                    /* discard the error code */
    iretl
1:  cmpl    $0, XPECT                   /* the probe / case D arm (own slots) */
    je      2f
    incl    0x00002340
    movl    XPECT, %eax
    movl    %eax, 0x00002344
    movl    $0, XPECT
    movl    XSKIP, %eax
    addl    %eax, 4(%esp)
    addl    $4, %esp
    iretl
2:  movl    $0x7D, %edi
    jmp     fail_exit

    .align 16
    .global pf_entry
pf_entry:
    movl    $0x7E, %edi
    jmp     fail_exit
    .align 16
    .global df_entry
df_entry:
    movl    $0x7F, %edi
    jmp     fail_exit

    .align 16
    .global fail_exit
fail_exit:                              /* edi = the failing check's code */
    movl    %edi, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

set_gate0:                              /* EBX = handler offset, EDI = gate */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, (%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)
    ret

/* ============================ SMM HANDLER ================================
 * 16-bit SMM prologue (hand-encoded): write the SMM-view sentinel, stash
 * the round id, set CR0.PE, far-jump into the 32-bit protected-mode part
 * (absolute address -- the handler is copied to 0x38000). The PM part
 * PM-loads SS with the width the mainline did NOT have (round 1 -> B=1,
 * rounds 2/3/4 -> B=0) and loads DS per the round (3 -> expand-down B=0,
 * 4 -> expand-down B=1, else flat, PM-marking it), pushes/pops a sentinel
 * through ITS OWN (mutated) stack, writes the completion sentinel, and
 * RSMs. The save map
 * is restored whole by RSM, so the handler may clobber GPRs freely. */
    .align 16
    .global smm_handler
smm_handler:
    .byte   0x67, 0x66, 0xC7, 0x05, 0x00, 0x21, 0x00, 0x00
    .long   0x5AA10001                  /* mov dword [0x2100], 0x5AA10001 */
    .byte   0x67, 0x66, 0xA1, 0x00, 0x22, 0x00, 0x00   /* mov eax, [ROUND] */
    .byte   0x67, 0x66, 0x89, 0x05, 0x04, 0x22, 0x00, 0x00 /* mov [0x2204], eax */
    .byte   0x0F, 0x20, 0xC0            /* mov eax, cr0 */
    .byte   0x66, 0x83, 0xC8, 0x01      /* or eax, 1 */
    .byte   0x0F, 0x22, 0xC0            /* mov cr0, eax */
    .byte   0x66, 0xEA                  /* ljmp ptr16:32 to the PM part */
    .long   0x00038000 + handler_pm32 - smm_handler
    .word   0x0008

    .code32
handler_pm32:
    movl    0x00002204, %eax            /* the round id */
    cmpl    $1, %eax
    je      1f
    movw    $0x18, %ax                  /* rounds 2/3/4: SS <- B=0 (16-bit) */
    jmp     2f
1:  movw    $0x10, %ax                  /* round 1: SS <- B=1 (32-bit) */
2:  movw    %ax, %ss
    /* DS mutation for case D: round 3 -> expand-down B=0, round 4 ->
     * expand-down B=1, anything else -> flat (PM-marks it). The handler's
     * own sentinel accesses (0x2104/0x2108) sit above the expand-down
     * limit 0x0FFF, so they stay legal under either mutation. */
    movl    0x00002204, %eax
    cmpl    $3, %eax
    jne     3f
    movw    $0x28, %ax                  /* round 3: DS <- expand-down B=0 */
    jmp     5f
3:  cmpl    $4, %eax
    jne     4f
    movw    $0x20, %ax                  /* round 4: DS <- expand-down B=1 */
    jmp     5f
4:  movw    $0x10, %ax                  /* DS <- flat data (PM-marks it) */
5:  movw    %ax, %ds
    movl    $0x5AA20002, %eax
    pushl   %eax                        /* the handler's own stack works */
    popl    0x00002104                  /* (8F 05 disp32) */
    movl    $0x5AA30003, 0x00002108     /* completion sentinel */
    .byte   0x0F, 0xAA                  /* rsm */
    .code16
    .global smm_handler_end
smm_handler_end:

/* ===================== 16-bit reset stub @ 0xFFF0 ======================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off
    .word   0xF000
