/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug3 H-11b — LTR must write the descriptor BUSY bit before TR
 * commits, and a null LLDT must commit the invalid LDTR with NO descriptor
 * read at all.
 *
 * The defect (two halves, core_tss_priv.svh / core_bus_driver.svh):
 *   (a) LTR loaded the TR hidden cache but never performed the architectural
 *       type-9 -> type-B write at descriptor+5 in the GDT. Software reading
 *       the descriptor back observed an AVAILABLE TSS, and a second LTR on the
 *       same selector SUCCEEDED (a busy TSS is not an available type).
 *   (b) the LLDT bus arm always read GDT[0] first, even for a NULL selector
 *       (which names no descriptor: it invalidates LDTR directly). Under
 *       paging with GDT[0] on a non-present page, that gratuitous read raised
 *       a #PF for an access the architecture never makes.
 *
 * QEMU 8.2.2 implements BOTH behaviours faithfully and is the differential
 * oracle (verified in the pinned harness source):
 *   - helper_ltr (tcg/seg_helper.c:1240): after loading the TR cache it does
 *     `e2 |= DESC_TSS_BUSY_MASK; cpu_stl_kernel_ra(ptr + 4, e2)` -- the busy
 *     bit lands in the GDT. A second LTR then reads type 0xB, which fails the
 *     `type != 1 && type != 9` test -> #GP(selector & 0xFFFC).
 *   - helper_lldt (tcg/seg_helper.c:1186): `(selector & 0xfffc) == 0` ->
 *     ldt.base/limit = 0 with NO descriptor dereference.
 *
 * THE TEST (three cases):
 *   case A  LTR 0x18 (TSS descriptor, access 0x89); read the access byte back
 *           from the GDT at 0x51D: must be 0x8B -- the busy write happened
 *           BEFORE TR committed. (HEAD reads 0x89.)
 *   case B  LTR 0x18 a SECOND time: must fault #GP(0x18) -- the descriptor is
 *           now busy (type 0xB), no longer an available TSS. The #GP handler
 *           records the vector (13) and the error code from the frame and
 *           resumes the mainline. (HEAD: no fault -- the second LTR succeeds.)
 *   case C  under PAGING with the GDT's page (page 0, base 0x500) NOT PRESENT:
 *           `lldt` a NULL selector must complete with NO #PF (the fix commits
 *           the invalid LDTR without touching GDT[0]; HEAD reads GDT[0] and
 *           #PFs -- pf_handler below catches that and exits with a poisoned
 *           witness). A subsequent `sldt` reads 0.
 *
 * Memory plan (no straddles; the page tables are the ptaskpg pattern shrunk):
 *   GDT  @ 0x00000500   null + code0 0x08 + data0 0x10 + TSS 0x18
 *   IDT  @ 0x00001000   #GP(13) -> gp_handler, #PF(14) -> pf_handler (0x8E)
 *   markers @ 0x00002000
 *   TSS  @ 0x00003000   (zeroed; LTR only needs the descriptor)
 *   PD   @ 0x00011000   PD[0] -> PT0
 *   PT0  @ 0x00012000   pages 1,2,3,0x90 and 0xF0-0xFF identity P|RW;
 *                       page 0 (the GDT) ABSENT
 *   CPL0 stack @ 0x00090000
 *
 * WITNESSES (marker page, pulled into the GPRs at the exit so the
 * golden-vs-RTL differential compares them):
 *   0x2000  the TSS access byte after case A  == 0x8B (edi at exit)
 *   0x2004  the case-B fault vector           == 13  (esi)
 *   0x2008  the case-B error code             == 0x18 (ebp) = sel & 0xFFFC
 *   0x200C  sldt after the null lldt          == 0   (ecx)
 *   0x2010  0xC0C0C0C0 -- the null lldt completed with no #PF (ebx).
 *           pf_handler writes 0xEEEEEEEE here instead and jumps to the exit,
 *           so a build that reads GDT[0] (HEAD) diverges on ebx AND on the
 *           whole post-paging record stream.
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): the HEAD TB (no H-11b fix)
 * performs no busy write (case A reads 0x89), accepts the second LTR (no #GP:
 * cases B's handler never runs), and reads GDT[0] for the null lldt -> #PF on
 * the non-present page -> pf_handler -> 0xEEEEEEEE witness + truncated record
 * stream: DIVERGENT at the case-A readback already.
 *
 * GNU-as; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
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

    /* --- build the GDT (4 entries = 32 bytes) at linear 0x0500 ---
     * idx0 null
     * idx1 0x08 code32 flat DPL0   (access 0x9A, gran 0xCF)
     * idx2 0x10 data32 flat DPL0   (access 0x92, gran 0xCF)
     * idx3 0x18 TSS (available, base 0x3000, limit 0x67, access 0x89)
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 */
    movl    $0x00CF9200, 20(%ebx)
    /* idx3 0x18 TSS: base 0x00003000, limit 0x67, access 0x89 (32-bit avail) */
    movl    $0x30000067, 24(%ebx)
    movl    $0x00008900, 28(%ebx)

    movw    $0x001F, 0x0480             /* GDT limit = 32-1 = 0x1F (4 entries) */
    movl    $0x00000500, 0x0482         /* GDT base = 0x0500 */
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
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp           /* CPL0 stack */

    /* zero the marker area 0x2000..0x2020 */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $8, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* zero the TSS (LTR only reads the DESCRIPTOR; keep the target clean) */
    movl    $0x00003000, %edi
    movl    $26, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movw    $0x0068, 0x00003066         /* I/O map base (empty) */

    /* ---- IDT @ 0x1000: #GP(13) -> gp_handler, #PF(14) -> pf_handler ----
     * Zero only vectors 0..15 (32 dwords); the rest of low RAM resets to 0
     * (same convention as ptask). */
    movl    $0x00001000, %edi
    movl    $32, %ecx
1:  movl    $0, (%edi)
    addl    $4, %edi
    loop    1b

    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 */
    call    set_gate0
    movl    $pf_handler, %ebx
    movl    $0x00001070, %edi           /* 0x1000 + 14*8 */
    call    set_gate0

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ==================== case A: LTR writes the busy bit ================== *
     * LTR 0x18. The fix stages the validated descriptor and runs the busy-byte
     * write (type 9 -> B at descriptor+5 = linear 0x51D) BEFORE committing TR.
     * QEMU does the same (helper_ltr's stl of e2|BUSY), so the readback below
     * must show 0x8B in BOTH oracles. HEAD never writes it: 0x89.            */
    movw    $0x0018, %ax
    ltr     %ax

    movzbl  0x0000051D, %eax            /* TSS descriptor access byte */
    movl    %eax, 0x00002000            /* expect 0x0000008B */

    /* ==================== case B: a second LTR must #GP ==================== *
     * The descriptor is now BUSY (type 0xB), which is not an available TSS:
     * #GP(sel & 0xFFFC) = #GP(0x18). QEMU agrees (helper_ltr's type test).
     * HEAD never set the busy bit, so its second LTR SUCCEEDS and gp_handler
     * never runs -- the 0x2004/0x2008 witnesses stay 0 and the stream
     * diverges. */
    movl    $after_ltr2, 0x00002080     /* where the handler resumes us */
    movw    $0x0018, %ax
    ltr     %ax                         /* must #GP(0x18) */
    /* Reached only if the second LTR did NOT fault (the HEAD defect). */
    movl    $0xBADBAD0B, 0x00002004

after_ltr2:
    /* ==================== build the page tables ============================ *
     * PT0 @ phys 0x12000: identity, P|RW supervisor. Page 0 (the GDT page,
     * linear 0x500) is left ABSENT -- the whole point of case C.            */
    movl    $0x00012000, %edi
    movl    $0x00001003, 4(%edi)        /* page 1: IDT */
    movl    $0x00002003, 8(%edi)        /* page 2: markers */
    movl    $0x00003003, 12(%edi)       /* page 3: TSS */
    movl    $0x00090003, 0x240(%edi)    /* page 0x90: CPL0 stack */
    movl    $0x000123C0, %edi           /* &PT0[0xF0] */
    movl    $0x000F0003, %eax           /* identity the image window */
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b

    movl    $0x00012003, 0x00011000     /* PD[0] -> PT0 */

    /* ==================== case C: null LLDT, GDT[0] NOT PRESENT ============ *
     * Enable paging, then `lldt` a NULL selector. A null LLDT names no
     * descriptor: the architecture invalidates LDTR directly. The fix commits
     * the invalid LDTR with NO memory request; HEAD's bus arm reads GDT[0]
     * first -- linear 0x500 on a non-present page -> #PF -> pf_handler. QEMU
     * (helper_lldt) does no read either, so the golden shows no #PF.         */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0                  /* CR0.PG=1: paging ON */

    xorl    %eax, %eax
    lldt    %ax                         /* NULL selector: must NOT read GDT[0] */

    movl    $0xC0C0C0C0, 0x00002010     /* "null lldt completed, no #PF" */
    sldt    %ax
    movzwl  %ax, %eax
    movl    %eax, 0x0000200C            /* expect 0 (LDTR invalid) */

    /* ===================== pull the witnesses and exit ===================== */
do_exit:
    movl    0x00002000, %edi            /* case A busy byte (0x8B) */
    movl    0x00002004, %esi            /* case B vector (13) */
    movl    0x00002008, %ebp            /* case B error code (0x18) */
    movl    0x0000200C, %ecx            /* sldt (0) */
    movl    0x00002010, %ebx            /* 0xC0C0C0C0 no-#PF sentinel */

    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hang1:
    hlt
    jmp     hang1

    /* ============================ handlers ================================= *
     * gp_handler (case B): same-privilege delivery at CPL0, so the frame is
     *   [esp]=err  [esp+4]=EIP  [esp+8]=CS  [esp+12]=EFLAGS.
     * Record the vector + error code, resume the mainline at the staged
     * address, drop the error code. */
    .align 16
    .global gp_handler
gp_handler:
    movl    $13, 0x00002004             /* vector */
    movl    0(%esp), %eax               /* error code from the frame */
    movl    %eax, 0x00002008            /* expect 0x00000018 */
    movl    0x00002080, %eax            /* staged resume address */
    movl    %eax, 4(%esp)               /* overwrite the saved EIP */
    addl    $4, %esp                    /* discard the error code */
    iret

    /* pf_handler (case C, HEAD-only): the null lldt read GDT[0] on the
     * non-present page. Poison the no-#PF witness and exit -- the HEAD trace
     * then diverges from the golden on ebx AND on every record after the
     * lldt. (In the fixed flow this handler never runs.) */
    .align 16
    .global pf_handler
pf_handler:
    movl    $0xEEEEEEEE, 0x00002010
    addl    $4, %esp                    /* discard the #PF error code */
    jmp     do_exit

    /* ---- IDT gate builder (EBX = handler offset, EDI = gate slot) ---- */
set_gate0:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* P, DPL0, 32-bit interrupt gate */
    movl    %eax, 4(%edi)
    ret

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off                /* 16-bit offset within segment 0xF000 */
    .word   0xF000                      /* segment */
