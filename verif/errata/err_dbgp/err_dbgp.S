/* Ventium M6B errata test: err_dbgp — Erratum 79 (242480-041 doc p.50):
 * "Erroneous Debug Exception on POPF/IRET Instructions with a GP Fault" (NoFix).
 *
 * THE ORACLE PROBLEM (M6/M6B): QEMU computes the CORRECT result — it does NOT
 * reproduce this P5 silicon bug.  So this is NOT a differential `--system` golden
 * (qemu would only ever deliver the clean #GP).  Like every M6 erratum it is
 * SELF-CHECKED against the DOCUMENTED behavior, behind the core's errata flag
 * (default OFF), ON asserting the defect and OFF asserting the clean result.  The
 * harness (verif/errata/run-m6.sh) reads the RTL `--system` .vtrace BOTH ways.
 *
 * DOCUMENTED behavior (242480-041 Erratum 79, verbatim):
 *   PROBLEM:  "An erroneous debug exception can occur due to execution of a POPF
 *   or IRET instruction in virtual 8086 mode, if there is a data breakpoint set
 *   on the address pointed to by SS:ESP, and the POPF or IRET triggers a general
 *   protection fault.  This occurs in virtual 8086 mode when the IOPL < 3,
 *   causing POPF and IRET to trap to the GP fault without accessing the stack.
 *   The data breakpoint set on the stack should not be triggered, but in fact it
 *   is incorrectly triggered as soon as the GP fault handler is entered."
 *   IMPLICATION:  "This results in an invalid debug exception where the saved
 *   state (CS:EIP in the stack ...) points to the first instruction of the GP
 *   Fault handler."
 *
 *   => ACTUAL (errata ON):   BOTH a #GP(13) AND an erroneous #DB(1) are delivered;
 *      the #DB's saved CS:EIP points at the FIRST instruction of the #GP handler.
 *   => EXPECTED (errata OFF): ONLY the #GP(13) is delivered; the SS:ESP data
 *      breakpoint does NOT fire (POPF/IRET never accessed the stack).
 *
 * STRUCTURE (this image bootstraps real->protected + PAGING + a TSS, builds an
 * IDT with a #GP gate (vector 13 -> gp_handler) AND a #DB gate (vector 1 ->
 * db_handler), arms DR0 = the V86 SS:ESP LINEAR address with DR7 = a 4-byte
 * data-WRITE breakpoint, then enters V86 at IOPL=0 and executes a POPF — which,
 * being IOPL-sensitive in V86, #GP-traps to the monitor WITHOUT touching the
 * stack).  The witnesses (all in the visible GPRs at the terminate point):
 *   ECX = #GP-from-V86 delivery count  (always >= 1: the POPF #GP + the
 *         terminate INT 0x20 #GP) — proves the V86 trap path ran.
 *   EAX = #DB delivery count           (errata OFF: 0; errata ON: 1) — the
 *         documented Actual vs Expected: the erroneous #DB fires (ON) or not
 *         (OFF).
 *   EBX = the DR6 cause bits the #DB handler observed (errata ON: B0=bit0 set
 *         over the reserved-1 base 0xFFFF0FF0; errata OFF: stays 0 — no #DB).
 *   ESI = the saved EIP the #DB handler popped from its stack frame (errata ON:
 *         == gp_handler's first-instruction linear EIP; errata OFF: stays 0).
 *   EDI = gp_handler's first-instruction linear EIP (the reference value ESI is
 *         compared against — proves the #DB's saved CS:EIP is the #GP handler
 *         entry, the documented Implication).
 *   EDX = the V86 "entered" sentinel (0xCAFE0079) — proves the V86 task ran.
 *
 * NEGATIVE CONTROL: the breakpoint is on the SS:ESP linear address but the POPF
 * NEVER writes it (it traps first).  A faithful clean core therefore must NOT
 * fire the #DB (the data was never accessed) — that is the OFF assertion.  And
 * the erratum is documented ONLY for POPF/IRET; the RTL guard restricts the
 * erroneous-#DB chain to POPF/IRET (CLI/STI/PUSHF/INT n do NOT chain it), so the
 * INT 0x20 terminate #GP never spuriously fires the #DB even with the flag ON.
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios err_dbgp.bin (used only to
 * SANITY-confirm the clean image reaches isa-debug-exit; the erratum self-check
 * runs the RTL --system trace).  Reset vector CS:EIP=F000:FFF0.
 *
 * Memory plan (identical strategy to pv86):
 *   GDT  @ 0x00000500  (null + code0 0x08 + data0 0x10 + clones + TSS32 0x28)
 *   IDT  @ 0x00001000  (256 gates; vector 1 #DB trap gate + vector 13 #GP int gate)
 *   markers @ 0x00002000 (the monitor's per-event counts + the #DB witnesses)
 *   TSS  @ 0x00003000  (32-bit TSS; SS0=0x10, ESP0=0x00088000 monitor stack)
 *   V86 task @ 0x00010000 (segment 0x1000)
 *   V86 data @ 0x00020000 (segment 0x2000)
 *   V86 stack @ 0x0002F000 (segment 0x2000, SP=0xF000 -> SS:ESP linear = 0x2F000)
 *   DR0 = 0x0002F000 (the SS:ESP LINEAR address); DR7 = L0 + write + LEN4.
 *   Page tables: PD @ 0x11000, PT0 @ 0x12000 (identity low + code window).
 *   monitor boot stack @ 0x00090000 ; monitor interrupt (CPL0) stack @ 0x00088000.
 *
 * GNU-as syntax; no nasm.
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

    /* --- build the GDT (6 entries) at linear 0x0500 --- */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 flat */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18 data0 flat clone */
    movl    $0x00CF9200, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20 data0 flat clone */
    movl    $0x00CF9200, 36(%ebx)
    movl    $0x30000067, 40(%ebx)       /* idx5 0x28 TSS32 base 0x3000 limit 0x67 */
    movl    $0x00008900, 44(%ebx)       /* access 0x89 (available 32-bit TSS) */

    movw    $0x002F, 0x0480             /* GDT limit = 48-1 */
    movl    $0x00000500, 0x0482        /* GDT base = 0x0500 */
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* opsize-32 ljmp ptr16:32 */
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax                  /* flat CPL0 data everywhere */
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp           /* monitor boot/main stack */

    /* --- zero the marker area at 0x2000..0x2080 (32 dwords) --- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== build + load the TSS ========================== */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx                   /* 104 bytes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00088000, 0x00003004     /* ESP0 */
    movl    $0x00000010, 0x00003008     /* SS0 = data0 */
    movw    $0x0068, 0x00003066         /* I/O map base (empty map) */

    movw    $0x0028, %ax
    ltr     %ax                         /* TR <- TSS selector 0x28 */

    /* ===================== build the IDT ================================= */
    /* Vector 13 (#GP): 32-bit INTERRUPT gate (attr 0x8E), selector 0x08. */
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* P=1 DPL=0 type=E (32-bit interrupt gate) */
    movl    %eax, 4(%edi)

    /* Vector 1 (#DB): 32-bit TRAP gate (attr 0x8F), selector 0x08.  A trap gate
     * (IF preserved) per Intel for #DB; the erroneous #DB chains through here. */
    movl    $db_handler, %ebx
    movl    $0x00001008, %edi           /* 0x1000 + 1*8 */
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

    /* record gp_handler's first-instruction linear EIP so the success proof can
     * compare it against the #DB's saved EIP (the documented Implication). */
    movl    $gp_handler, %eax
    movl    %eax, 0x0000201C            /* gp_handler entry EIP (reference) */

    /* ============ copy the V86 task blob down to linear 0x10000 ========== */
    movl    $_v86_lma, %esi
    movl    $0x00010000, %edi
    movl    $_v86_blob_len, %ecx
    addl    $3, %ecx
    shrl    $2, %ecx
1:  movl    (%esi), %eax
    movl    %eax, (%edi)
    addl    $4, %esi
    addl    $4, %edi
    loop    1b

    /* ===================== build the 2-level page tables ================= */
    /* PT0 @ 0x12000: identity-map [0,0x40000) (64 PTEs) + monitor stacks
     * [0x80000,0x91000) + code window [0xF0000,0x100000).  U/S=1 everywhere. */
    movl    $0x00012000, %edi
    movl    $0x00000007, %eax
    movl    $64, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00012200, %edi           /* &PT0[0x80] */
    movl    $0x00080007, %eax
    movl    $17, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x000123C0, %edi           /* &PT0[0xF0] */
    movl    $0x000F0007, %eax
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b

    movl    $0x00011000, %edi
    movl    $0x00012007, 0(%edi)        /* PD[0] -> PT0 */

    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* ===================== arm the SS:ESP data breakpoint =============== */
    /* The V86 task runs with SS=0x2000, ESP=0xF000 -> SS:ESP linear = 0x2F000.
     * Set a 4-byte data-WRITE breakpoint there:
     *   DR0 = 0x0002F000
     *   DR7 = L0(bit0) | R/W0=01(write, bits16-17) | LEN0=11(4 bytes, bits18-19)
     *         | fixed-1(bit10)
     *       = 0x1 | 0x10000 | 0xC0000 | 0x400 = 0x000D0401
     * Per Erratum 79 this breakpoint MUST NOT fire on the POPF (which traps to
     * #GP without touching the stack) on a clean core; an affected stepping
     * erroneously fires it as the #GP handler is entered. */
    movl    $0xFFFF0FF0, %eax           /* clear DR6 first (reserved-1 base) */
    movl    %eax, %dr6
    movl    $0x0002F000, %eax           /* DR0 = the SS:ESP linear address */
    movl    %eax, %dr0
    movl    $0x000D0401, %eax           /* DR7 = L0 + write + LEN4 + fixed-1 */
    movl    %eax, %dr7

    /* clear the visible accumulator GPRs */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %ebp, %ebp
    xorl    %edi, %edi

    /* ===================== ENTER VIRTUAL-8086 MODE ====================== */
    /* 9-word V86 IRET frame: GS,FS,DS,ES,SS,ESP,EFLAGS,CS,EIP.
     *   CS=0x1000 EIP=0  ; SS=0x2000 ESP=0xF000 (SS:ESP linear = 0x2F000)
     *   DS=ES=0x2000 ; FS=GS=0 ; EFLAGS = VM(bit17) | reserved(bit1), IOPL=0. */
    pushl   $0x00000000                 /* GS */
    pushl   $0x00000000                 /* FS */
    pushl   $0x00002000                 /* DS */
    pushl   $0x00002000                 /* ES */
    pushl   $0x00002000                 /* SS */
    pushl   $0x0000F000                 /* ESP (-> SS:ESP linear 0x2F000) */
    pushl   $0x00020002                 /* EFLAGS: VM | reserved(bit1), IOPL=0 */
    pushl   $0x00001000                 /* CS = 0x1000 */
    pushl   $0x00000000                 /* EIP = 0 */
    iret                                /* -> V86 mode at 0x1000:0000, CPL3 */

mhang:
    hlt
    jmp     mhang

    /* ============================ #GP HANDLER (MONITOR) ================== */
    /* Reached at CPL0 via #GP(0) raised by an IOPL-sensitive instruction in the
     * V86 task (IOPL<3, method-1).  Stack on entry (a #GP pushes an error code):
     *   [esp+0]=errcode [esp+4]=EIP [esp+8]=CS [esp+12]=EFLAGS [esp+16]=ESP
     *   [esp+20]=SS [esp+24]=ES [esp+28]=DS [esp+32]=FS [esp+36]=GS
     * After 4 pushes the frame shifts +16. */
    .align 16
    .global gp_handler
gp_handler:
    pushl   %eax
    pushl   %ebx
    pushl   %ecx
    pushl   %edx

    movw    $0x10, %ax                  /* reload flat CPL0 data (V86->PM zeroed them) */
    movw    %ax, %ds
    movw    %ax, %es

    incl    0x00002000                  /* total #GP-from-V86 delivery count */

    /* fetch the faulting V86 opcode: linear = (CS<<4)+EIP. CS@[esp+24] EIP@[esp+20] */
    movl    0x18(%esp), %eax            /* CS (V86 code selector) */
    andl    $0x0000FFFF, %eax
    shll    $4, %eax
    movl    0x14(%esp), %ebx            /* EIP (V86 offset) */
    andl    $0x0000FFFF, %ebx
    addl    %ebx, %eax                  /* eax = linear of the faulting opcode */
    movl    %eax, %edx                  /* keep the linear in edx */
    movzbl  (%eax), %ecx                /* ecx = the faulting opcode byte */

    /* dispatch */
    cmpl    $0xCD, %ecx
    je      gp_int_n                    /* 0xCD = INT n */
    /* otherwise a 1-byte IOPL-sensitive op (POPF 0x9D etc.): advance EIP by 1. */
    incl    0x14(%esp)                  /* saved V86 EIP += 1 */
    jmp     gp_return

gp_int_n:
    movzbl  1(%edx), %ecx               /* ecx = the INT vector */
    cmpl    $0x20, %ecx
    je      gp_terminate                /* INT 0x20 -> terminate */
    addl    $2, 0x14(%esp)              /* advance past the 2-byte INT n */
    jmp     gp_return

gp_return:
    popl    %edx
    popl    %ecx
    popl    %ebx
    popl    %eax
    addl    $4, %esp                    /* discard the #GP error code */
    iret                                /* IRET back into V86 (VM=1 in saved EFLAGS) */

gp_terminate:
    /* The V86 task signalled completion (INT 0x20).  Accumulate the success proof
     * into the visible GPRs and perform the isa-debug-exit at CPL0. */
    movl    0x00002000, %ecx            /* #GP-from-V86 delivery count */
    movl    0x00002004, %eax            /* #DB delivery count (OFF: 0, ON: 1) */
    movl    0x00002008, %ebx            /* DR6 cause bits seen by the #DB handler */
    movl    0x00002010, %esi            /* the saved EIP the #DB handler popped */
    movl    0x0000201C, %edi            /* gp_handler entry EIP (reference) */
    movl    0x00020000, %edx            /* the V86 "entered" sentinel */

    movl    $0x42, %eax                 /* isa-debug-exit code (eax clobbered AFTER
                                         * the accumulators above are read) */
    movw    $0xF4, %dx
    outb    %al, %dx

ehang:
    hlt
    jmp     ehang

    /* ============================== #DB HANDLER ========================= */
    /* Reached ONLY on the affected stepping (Erratum 79): the erroneous #DB is
     * delivered AS the #GP handler is entered, with the saved CS:EIP pointing at
     * gp_handler's first instruction.  A trap gate (no error code); the #DB is
     * delivered same-privilege (CPL0->CPL0), so the stack on entry is:
     *   [esp+0]=EIP [esp+4]=CS [esp+8]=EFLAGS
     * After 1 push (eax) the saved EIP is at [esp+4]. */
    .align 16
    .global db_handler
db_handler:
    pushl   %eax
    incl    0x00002004                  /* #DB delivery count (the erroneous one) */
    movl    %dr6, %eax
    orl     %eax, 0x00002008            /* accumulate the DR6 cause bits (expect B0) */
    movl    0x04(%esp), %eax            /* saved EIP (the #GP handler's first insn) */
    movl    %eax, 0x00002010            /* witness the saved EIP */
    /* clear DR6 + fully disarm DR7 so the returned-to #GP handler does not loop
     * (it will go on to read/store, none of which is the armed SS:ESP, but be
     * safe). */
    movl    $0xFFFF0FF0, %eax
    movl    %eax, %dr6
    movl    $0x00000400, %eax
    movl    %eax, %dr7
    popl    %eax
    iret                                /* return to the #GP handler's first insn */

    /* ============================ V86 TASK BODY ========================= */
    .code16
    .section .text_v86, "ax"
    .global v86_entry
v86_entry:
    /* stamp a "V86 entered" sentinel via DS=0x2000 -> linear 0x20000 (DS<<4). */
    movw    $0x2000, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movl    $0xCAFE0079, %eax           /* the "V86 entered" sentinel value */
    movl    %eax, %ds:0x0000            /* store to linear 0x20000 (DS<<4 + 0) */
v86_after_sentinel:
    /* the ERRATUM TRIGGER: POPF is IOPL-sensitive in V86 (IOPL=0 < 3) -> #GP to
     * the monitor WITHOUT accessing the stack.  A data breakpoint is armed on
     * SS:ESP (linear 0x2F000); per Erratum 79 it must NOT fire on a clean core,
     * but an affected stepping erroneously delivers a #DB at the #GP handler. */
    popf                                /* 0x9D -> #GP (the documented trigger) */
    /* signal completion + terminate (INT 0x20 -> monitor exits).  This INT 0x20
     * ALSO #GPs (INT n is IOPL-sensitive) but the RTL erroneous-#DB chain is
     * restricted to POPF/IRET, so it must NOT fire a #DB even with the flag on —
     * the implicit negative control. */
    int     $0x20                       /* 0xCD 0x20 -> #GP -> monitor terminates */
v86_hang:
    jmp     v86_hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off
    .word   0xF000
