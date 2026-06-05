/* Ventium M2S.6 — bare-metal DEBUG-REGISTER / #DB (IDT delivery) demonstrator.
 *
 * PROBE/CORPUS for the M2S.6 partial-oracle stage.  Bootstraps real->protected
 * (reusing the M2S.3 pfault bootstrap, NO paging), stands up an IDT with a #DB
 * gate at vector 1 (db_handler), and exercises the four M2S.6 debug features so
 * the de-risk phase can EMPIRICALLY classify each as differential / structural:
 *
 *   (a) MOV DRn<->GPR round-trip (ALWAYS DIFFERENTIAL): write known patterns to
 *       DR0/DR1/DR2/DR3/DR7/DR6, read them back into GPRs.  The DR *values* are
 *       not in the gdbstub g-packet, but the round-trip deposits them into GPRs
 *       which ARE in the g-packet (the M2S.1 hidden-base trick).
 *   (b) TF single-step #DB (LIKELY DIFFERENTIAL): set EFLAGS.TF, execute one
 *       instruction -> #DB trap -> db_handler reads DR6 (expect BS=bit14) into a
 *       GPR + counts, clears TF in the saved EFLAGS, IRETs.
 *   (c) DR0 instruction breakpoint #DB (RISKY): arm DR0=&bp_target, DR7 L0+type00
 *       (execute), jump to bp_target -> #DB fault -> db_handler reads DR6 (expect
 *       B0=bit0), disarms DR7, IRETs (fault -> restarts the now-unarmed insn).
 *   (d) DR1 data-write breakpoint #DB (RISKY): arm DR1=&wp_target, DR7 L1+type01
 *       (write) + LEN=4, store to wp_target -> #DB trap -> db_handler reads DR6
 *       (expect B1=bit1), disarms DR7, IRETs.
 *
 * The db_handler is a SINGLE shared vector-1 handler.  On entry it reads DR6 into
 * EAX, ORs the live DR6 bits into a running witness at marker 0x2010, bumps the
 * #DB count at 0x2014, and dispatches on which DR6 bit is set:
 *   - BS (single-step trap): clear TF in the pushed EFLAGS so we don't loop;
 *     clear DR6; IRET (TF was already cleared by the trap-gate entry, but we also
 *     scrub the *saved* EFLAGS so the resumed mainline runs with TF=0).
 *   - B0 (instruction bp, FAULT): disarm DR7 (so the restarted insn does not
 *     re-fault), clear DR6, IRET -> restarts bp_target.
 *   - B1 (data-write bp, TRAP): disarm DR7, clear DR6, IRET -> resumes past the
 *     store (trap pushes NEXT eip).
 * Per-cause counters live at 0x2018 (BS), 0x201C (B0), 0x2020 (B1) so the de-risk
 * trace shows EXACTLY which causes actually delivered under single-step.
 *
 * #DB is vector 1, NO error code.  We use a TRAP gate (attr 0x8F) at vector 1 so
 * IF is preserved on entry (a #DB delivered as a trap, per Intel).
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pdebug.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Physical/linear memory plan (machine -m 32 => 32 MiB phys; targets fit):
 *   GDT  @ 0x00000500  (null + flat code 0x08 + flat data 0x10)
 *   IDT  @ 0x00001000  (256 gates; only vector 1 #DB filled)
 *   markers @ 0x00002000 (the DR round-trip read-backs + #DB witnesses/counters)
 *   stack   @ 0x00090000
 *   wp_data @ 0x00003000 (the DR1 data-write breakpoint target)
 *   NO paging (CR0.PG stays 0).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pdebug.ld; objcopy -O binary,
 * padded to exactly 64 KiB.  GNU-as syntax; no nasm.
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

    /* --- build the GDT (3 entries) at linear 0x0500 --- */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code32 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data32 flat */
    movl    $0x00CF9200, 20(%ebx)

    movw    $0x0017, 0x0480             /* limit = 24-1 = 0x17 (3 entries) */
    movl    $0x00000500, 0x0482        /* base  = 0x0500 */
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

    /* zero the marker area at 0x2000..0x2040 */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== build the IDT (#DB trap gate) ================= */
    /* IDT base 0x1000.  Vector 1 (#DB) -> db_handler.  TRAP gate (attr 0x8F) so
     * IF is preserved on entry. selector 0x08, DPL=0. */
    movl    $db_handler, %ebx
    movl    $0x00001008, %edi           /* 0x1000 + 1*8 = 0x1008 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008F00, %eax           /* P=1 DPL=0 type=F (32-bit trap gate) */
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490             /* IDT limit = 256*8-1 */
    movl    $0x00001000, 0x0492        /* IDT base = 0x1000 */
    lidt    0x0490

    /* clear the visible accumulator GPRs */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %ebp, %ebp

    /* ================== (a) MOV DRn <-> GPR round-trip =================== */
    /* Write known patterns to DR0..DR3, DR7, DR6; read them back into GPRs.
     * DR6 reads back with the documented reserved-1 pattern (0xFFFF0FF0 base);
     * DR7 reads back with bit10 fixed-1 (0x00000400).  We pick write values that
     * survive: for the round-trip proof we use addresses for DR0..DR3 and a
     * DR7 value whose reserved bits we set to their fixed values, and a DR6 value
     * we OR with the fixed-1 mask so the read-back is deterministic.
     *
     * Observed-through-GPR layout (the differential witnesses):
     *   0x2000 = DR0 read-back   (0x11111111)
     *   0x2004 = DR1 read-back   (0x22222222)
     *   0x2008 = DR2 read-back   (0x33333333)
     *   0x200C = DR3 read-back   (0x44444444)
     *   (DR7/DR6 read-backs go into 0x2024/0x2028 below)
     */
    movl    $0x11111111, %eax
    movl    %eax, %dr0
    movl    $0x22222222, %eax
    movl    %eax, %dr1
    movl    $0x33333333, %eax
    movl    %eax, %dr2
    movl    $0x44444444, %eax
    movl    %eax, %dr3
    /* read them back into GPRs and store to markers */
    movl    %dr0, %eax
    movl    %eax, 0x00002000
    movl    %dr1, %ebx
    movl    %ebx, 0x00002004
    movl    %dr2, %ecx
    movl    %ecx, 0x00002008
    movl    %dr3, %edx
    movl    %edx, 0x0000200C

    /* DR7 round-trip: write a benign control value (all breakpoints disabled),
     * read back (bit10 fixed-1 -> 0x00000400 base).  Write 0x00000400 explicitly
     * so the read-back is exactly 0x00000400. */
    movl    $0x00000400, %eax
    movl    %eax, %dr7
    movl    %dr7, %esi
    movl    %esi, 0x00002024            /* DR7 read-back (expect 0x00000400) */

    /* DR6 round-trip: write the fixed-1 pattern, read back (expect 0xFFFF0FF0). */
    movl    $0xFFFF0FF0, %eax
    movl    %eax, %dr6
    movl    %dr6, %ebp
    movl    %ebp, 0x00002028            /* DR6 read-back (expect 0xFFFF0FF0) */

    /* ===================== (b) TF single-step #DB ======================= */
    /* Set EFLAGS.TF (bit8) via PUSHF/POPF, then execute ONE instruction; the #DB
     * trap fires AFTER it, vectoring to db_handler.  The handler clears TF in the
     * saved EFLAGS so we resume normally.  We mark before/after so the trace shows
     * the single-step trap delivered.  EDI holds a sentinel the stepped insn sets;
     * the handler must see DR6.BS. */
    movl    $0x5EED0001, %edi           /* sentinel: pre-TF marker */
    pushf
    orl     $0x00000100, (%esp)         /* set TF in the to-be-popped EFLAGS */
    popf                                 /* TF now armed; #DB after the NEXT insn */
    nop                                  /* <-- single-stepped; #DB trap after it */
tf_resume:
    movl    $0x5EED0002, %edi           /* post-TF marker (proves resume) */
    movl    %edi, 0x0000202C            /* witness the resume */

    /* ============== (c) DR0 instruction breakpoint #DB (FAULT) ========== */
    /* Arm DR0 = &bp_target, DR7 = L0(bit0) + type00(execute) + LEN00.  Jumping to
     * bp_target should #DB-fault BEFORE the instruction at bp_target.  db_handler
     * disarms DR7 and IRETs -> restarts bp_target (which then runs).
     * DR7 value: L0=bit0=1; bits16-17 (R/W0)=00 execute; bits18-19 (LEN0)=00;
     * bit10 fixed-1.  => 0x00000401. */
    movl    $bp_target, %eax
    movl    %eax, %dr0
    movl    $0xFFFF0FF0, %eax           /* clear DR6 before arming */
    movl    %eax, %dr6
    movl    $0x00000401, %eax           /* DR7: L0 + type00(exec) + fixed-1 */
    movl    %eax, %dr7
    movl    $0xB00B0001, %esi           /* pre-bp marker */
    jmp     bp_target                    /* control reaches the armed address */
bp_target:
    movl    $0xB00B0002, %esi           /* post-bp marker (runs after restart) */
    movl    %esi, 0x00002030            /* witness the instruction-bp resume */
    /* disarm any residual DR7 just in case the handler path differed */
    movl    $0x00000400, %eax
    movl    %eax, %dr7

    /* =============== (d) DR1 data-write breakpoint #DB (TRAP) =========== */
    /* Arm DR1 = wp_data(0x3000), DR7 = L1(bit2) + type01(write) + LEN11(4 bytes).
     * Storing to wp_data should #DB-trap AFTER the store.  db_handler disarms DR7
     * and IRETs -> resumes past the store.
     * DR7: L1=bit2=1; R/W1 (bits20-21)=01 write; LEN1 (bits22-23)=11 4 bytes;
     * bit10 fixed-1.  => bit2(0x4) | (01<<20)=0x100000 | (11<<22)=0xC00000 | 0x400
     *  = 0x00D00404. */
    movl    $0x00003000, %eax
    movl    %eax, %dr1
    movl    $0xFFFF0FF0, %eax           /* clear DR6 before arming */
    movl    %eax, %dr6
    movl    $0x00D00404, %eax           /* DR7: L1 + R/W1=write + LEN1=4 + fixed-1 */
    movl    %eax, %dr7
    movl    $0xDA7A0001, %ebx           /* pre-wp marker */
    movl    %ebx, 0x00003000            /* store to wp_data -> #DB trap AFTER */
wp_resume:
    movl    $0xDA7A0002, %ebx           /* post-wp marker (proves resume) */
    movl    %ebx, 0x00002034            /* witness the data-wp resume */
    movl    $0x00000400, %eax           /* fully disarm DR7 */
    movl    %eax, %dr7

    /* ============== (e) DR7.GD general-detect (STRUCTURAL) ============== */
    /* INFEASIBLE differentially: qemu 8.2.2 does NOT implement GD (DR7_GD/DR6_BD
     * are defined but NEVER tested/set in target/i386 — empirically a MOV from
     * DRn with GD=1 does NOT #DB).  A P5-faithful RTL WOULD #DB here (DR6.BD set,
     * fault BEFORE the access), so the two diverge -> this part is NOT in the
     * differential gate; the RTL self-checks it structurally.
     *
     * The corpus still EXERCISES the path so both oracles run the same code: arm
     * DR7.GD (bit13) + fixed-1, do a MOV from DR0, and record at 0x2038 whether a
     * #DB fired.  Under qemu the gd_handler witness is NOT written (no fault); the
     * #DB count at 0x2014 therefore stays 3 in the qemu golden.  The handler also
     * counts BD (bit13) at 0x203C so the structural RTL check can assert the RTL
     * (and only the RTL) takes the GD #DB. */
    movl    $0x00000000, 0x00002038     /* GD-fire witness preset: 0 = no #DB */
    movl    $0xFFFF0FF0, %eax           /* clear DR6 before the GD probe */
    movl    %eax, %dr6
    movl    $0x00002400, %eax           /* DR7: GD(bit13) + fixed-1(bit10) */
    movl    %eax, %dr7
    movl    %dr0, %eax                   /* MOV from DR0: P5 -> #DB(BD); qemu -> no fault */
gd_resume:
    /* disarm GD so the trailing accumulation MOV-DRn reads do not trap on a
     * GD-faithful RTL (the RTL would otherwise re-fault on every DR access). */
    movl    $0x00000400, %eax
    movl    %eax, %dr7

    /* ===================== accumulate the success proof ================== */
    /* The differential proof set the de-risk reads (qemu golden values):
     *   ecx = total #DB count (0x2014)            -> 3 (BS + B0 + B1; GD does NOT
     *                                                  fire under qemu)
     *   edx = the cause witness OR-accumulator (0x2010) -> 0xFFFF4FF3 (BS|B1|B0
     *                                                  over the DR6 reserved-1 base)
     *   eax/ebx/esi: the per-cause counts (each 1). */
    movl    0x00002014, %ecx            /* total #DB delivered (qemu: 3) */
    movl    0x00002010, %edx            /* OR of all DR6 causes observed */
    movl    0x00002018, %eax            /* BS count (qemu: 1) */
    movl    0x0000201C, %ebx            /* B0 count (qemu: 1) */
    movl    0x00002020, %esi            /* B1 count (qemu: 1) */

    /* ====================== clean exit via isa-debug-exit ================== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ============================= #DB HANDLER ============================= */
    /* Shared vector-1 handler.  TRAP gate (IF preserved).  #DB has NO error code,
     * so the stack on entry is [esp]=EIP, [esp+4]=CS, [esp+8]=EFLAGS.
     * We save EAX/EBX (push 2) so the saved frame shifts +8:
     *   [esp+8]=EIP  [esp+12]=CS  [esp+16]=EFLAGS  (after 2 pushes)
     */
    .align 16
    .global db_handler
db_handler:
    pushl   %eax
    pushl   %ebx
    movl    %dr6, %eax                  /* read DR6 (the cause status) */
    orl     %eax, 0x00002010            /* accumulate the causes seen (witness) */
    incl    0x00002014                  /* total #DB count */

    /* BD (bit13): GD general-detect (FAULT) — fires ONLY on a GD-faithful core
     * (qemu does NOT implement GD, so this branch is never taken in the golden;
     * it lets the structural RTL self-check observe the GD #DB). */
    testl   $0x00002000, %eax
    jz      0f
    incl    0x0000203C                  /* BD count (qemu golden: stays 0) */
    movl    $0xBDBDBDBD, 0x00002038     /* GD-fire witness (RTL-only) */
    /* disarm GD so the restarted MOV-DRn does not re-fault, then IRET (FAULT
     * restarts the GD-faulting MOV; with GD cleared it now completes). */
    pushl   %eax
    movl    $0x00000400, %eax
    movl    %eax, %dr7
    popl    %eax
    jmp     9f
0:
    /* BS (bit14): TF single-step trap */
    testl   $0x00004000, %eax
    jz      1f
    incl    0x00002018                  /* BS count */
    /* scrub TF in the *saved* EFLAGS so the resumed mainline runs TF=0
     * (trap-gate entry already cleared the live TF, but the SAVED copy still has
     * it; without scrubbing, IRET would restore TF=1 and single-step forever). */
    andl    $0xFFFFFEFF, 0x10(%esp)     /* saved EFLAGS &= ~TF (bit8) */
    jmp     9f
1:
    /* B0 (bit0): DR0 instruction breakpoint (FAULT) */
    testl   $0x00000001, %eax
    jz      2f
    incl    0x0000201C                  /* B0 count */
    /* disarm DR7 so the restarted faulting instruction does not re-fault */
    pushl   %eax
    movl    $0x00000400, %eax
    movl    %eax, %dr7
    popl    %eax
    /* set RF in the saved EFLAGS so even if DR7 stayed armed the restart would
     * suppress the instruction breakpoint for one insn (belt-and-suspenders). */
    orl     $0x00010000, 0x10(%esp)     /* saved EFLAGS |= RF (bit16) */
    jmp     9f
2:
    /* B1 (bit1): DR1 data-write breakpoint (TRAP) */
    testl   $0x00000002, %eax
    jz      9f
    incl    0x00002020                  /* B1 count */
    pushl   %eax
    movl    $0x00000400, %eax
    movl    %eax, %dr7                  /* disarm DR7 */
    popl    %eax
9:
    /* clear DR6 (sticky bits) so the next #DB shows a clean cause */
    pushl   %eax
    movl    $0xFFFF0FF0, %eax
    movl    %eax, %dr6
    popl    %eax
    popl    %ebx
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
