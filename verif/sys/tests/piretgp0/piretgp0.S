/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug3 H-03 — IRET error codes + outer-IRET segment cleanup; also the
 * H-02 "offset past CS.limit" restartability case. THIS IS A WITNESS GATE,
 * NOT A DIFFERENTIAL ONE -- the oracle cannot encode the graded behaviour:
 *
 * ORACLE GAP 1 (measured 2026-08-03 in the pinned harness source, qemu 8.2.2
 * tcg/seg_helper.c:1927 helper_ret_protected): QEMU performs NO check of the
 * popped EIP against CS.limit on RETF or IRET -- the descriptor is validated,
 * env->eip is installed, done -- and TCG has no fetch-time code-limit check
 * either (translate.c has no CS-limit term). So a return with EIP past the
 * limit FAULTS in the RTL (#GP(0) at the return, nothing committed) but
 * TRANSFERS AND RUNS in QEMU: the very next retired record differs in pc/cs/
 * esp and no instruction stream reconverges record-for-record. The H-03(a)
 * past-limit case and the H-02 offset-past-limit restartability case are
 * therefore graded as WITNESSES (RTL faultlog + final-record GPRs), exactly
 * like the ioperm gate grades what QEMU does not model. The image still runs
 * to the isa-debug-exit under QEMU (step 3), and the generated golden pins
 * QEMU's deviant flow honestly (the a2_target/a3_target markers only ever
 * appear in the QEMU stream).
 *
 * ORACLE GAP 2 (H-03(b)): the finding's exact combination -- a data or
 * nonconforming-code selector with DPL >= new CPL but DPL < its own RPL,
 * which the fix nulls via DPL < max(new CPL, RPL) while QEMU's validate_seg
 * checks DPL < new CPL only -- is ARCHITECTURALLY UNREACHABLE through legal
 * loads on BOTH oracles: MOV-to-Sreg requires DPL >= max(CPL, RPL)
 * (ventium_sys_pkg.sv seg_load_fault; qemu helper_load_seg) and the hardware
 * task switch enforces the identical rule (qemu tss_load_seg: dpl < cpl ||
 * dpl < rpl -> #TS), so RPL <= DPL always holds for a loaded data segment
 * and the RPL term can never change a reachable outcome. What IS gradable is
 * the reachable boundary of the cleanup rule, and it matches in every
 * oracle: case B below pins it (DPL3/RPL3 survives, DPL0 nulled, conforming
 * code exempt, DPL3/RPL0 survives).
 *
 * THE CASES:
 *   A1  same-priv IRET with popped EIP == CS.limit EXACTLY (byte-granular
 *       limited code descriptor, base 0): must SUCCEED -- the at-limit
 *       false-positive tripwire. The target is a one-byte `int3` sitting AT
 *       the limit (no fetch ever crosses it); #BP vectors to bp_handler,
 *       which records 0xA1A1A1A1 and returns to the mainline. Oracle-
 *       IDENTICAL in QEMU and the RTL.
 *   A2  same-priv IRET with popped EIP = CS.limit + 1: the RTL must raise
 *       #GP(0) AT the IRET -- error code 0 (H-03: a valid descriptor whose
 *       EIP exceeds the limit is #GP(0), NOT #GP(selector) as the pre-fix
 *       iret_cs_ok supplied) -- with ESP UNCHANGED. QEMU transfers to
 *       a2_target (marker 0xA2A2A2A2) and rejoins. Witness: gp_handler's
 *       error-code-is-0 and ESP-is-staged checks.
 *   A3  same-priv 32-bit RETF with popped EIP = CS.limit + 1 (the H-02
 *       restartability case, regrouped here because it shares oracle gap 1):
 *       #GP(0) at the RETF with ESP preserved (the H-02 deferral). QEMU
 *       transfers to a3_target (marker 0xA3A3A3A3) and rejoins.
 *   B   outer IRET CPL0 -> CPL3 with DS=data DPL3 RPL3 (survives:
 *       DPL3 >= max(3,3)), ES=data0 DPL0 (NULLED: DPL0 < new CPL3), FS=
 *       conforming code DPL0 readable (SURVIVES: the H-08 conforming
 *       exemption), GS=data3 RPL0 (survives: DPL3 >= max(3,0)). Read back
 *       via mov sreg,reg (no data access through a possibly-null segment).
 *
 * WITNESSES (marker page; the CPL3 leg packs them into the GPRs for the
 * final record; the exit clobbers EAX/DX):
 *   edi = 0xA1A1A1A1  A1 executed (at-limit IRET succeeded in this oracle)
 *   esi = (gp<<16)|err0 -- 0x00020002 in the RTL (two #GP(0)); 0 in QEMU
 *   ecx = ESP-preserved confirmations            -- 2 in the RTL; 0 in QEMU
 *   ebp = (ds<<16)|es = 0x002B0000 (case B, identical in every oracle)
 *   ebx = (fs<<16)|gs = 0x00300020 (case B, identical in every oracle)
 *
 * GDT @ 0x500 (10 entries): null + code0 0x08 + data0 0x10 + code3 0x18 (0x1B)
 * + data3 0x20 (0x23) + data DPL3 0x28 (0x2B) + conforming code DPL0 0x30 +
 * limited code 0x38 (limit = a1_int3) + limited code 0x40 (limit =
 * a2_target-1) + limited code 0x48 (limit = a3_target-1). The limited-code
 * descriptors are built at runtime from link-time addresses (base 0, byte
 * gran, D=1, DPL0, 20-bit limit).
 * IDT @ 0x1000: #BP(3) -> bp_handler, #GP(13) -> gp_handler (0x8E DPL0).
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): the HEAD TB raises
 * #GP(0x40) for A2 (selector as the error code -- the H-03 defect) and
 * advances ESP before the fault for A3 (the H-02 defect), so the err0 and
 * ESP-preserved counts stay 0 and the faultlog shows err=00000040.
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

    /* boot GDT (3 entries) at 0x500: ONLY for the PM transition. The full
     * 10-entry GDT is rebuilt at the same spot in 32-bit code (the
     * limited-code descriptors need link-time addresses). */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510
    movl    $0x00CF9200, 0x0514
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
    movl    $0x00090000, %esp           /* CPL0 stack */

    /* ---- the full GDT (10 entries) at 0x500 ---- */
    movl    $0x0000FFFF, 0x0518         /* idx3 0x18 code3 flat */
    movl    $0x00CFFA00, 0x051C
    movl    $0x0000FFFF, 0x0520         /* idx4 0x20 data3 flat */
    movl    $0x00CFF200, 0x0524
    movl    $0x0000FFFF, 0x0528         /* idx5 0x28 data DPL3 flat -> 0x2B */
    movl    $0x00CFF200, 0x052C
    movl    $0x0000FFFF, 0x0530         /* idx6 0x30 CONFORMING code DPL0 readable
                                         * access 0x9E = P|S|code|C|R */
    movl    $0x00CF9E00, 0x0534
    /* idx7 0x38: limited code, limit = a1_int3 */
    movl    $a1_int3, %ebx
    movl    $0x00000538, %edi
    call    set_limited_code
    /* idx8 0x40: limited code, limit = a2_target - 1 */
    movl    $a2_target - 1, %ebx
    movl    $0x00000540, %edi
    call    set_limited_code
    /* idx9 0x48: limited code, limit = a3_target - 1 */
    movl    $a3_target - 1, %ebx
    movl    $0x00000548, %edi
    call    set_limited_code

    movw    $0x004F, 0x0480             /* GDT limit = 80-1 (10 entries) */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    /* zero the marker area 0x2000..0x20C0 (48 dwords) */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $48, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: #BP(3) -> bp_handler, #GP(13) -> gp_handler ---- */
    movl    $0x00001000, %edi
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    movl    $bp_handler, %ebx
    movl    $0x00001018, %edi           /* 0x1000 + 3*8 */
    call    set_gate0
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 */
    call    set_gate0

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ==================== A1: IRET with EIP == CS.limit exactly =========== *
     * Must SUCCEED (EIP within limit means EIP <= limit) -- the false-positive
     * tripwire for the fix's new limit check. The target is a one-byte int3
     * sitting AT the limit, so no fetch ever crosses it; #BP -> bp_handler
     * records A1 and returns to a1_done. Oracle-identical.                */
    pushfl
    pushl   $0x00000038                 /* CS = limited code (limit == a1_int3) */
    pushl   $a1_int3                    /* EIP == the limit exactly */
    iret
    .global a1_int3
a1_int3:
    int3                                /* #BP -> bp_handler -> a1_done */
a1_done:

    /* ==================== A2: IRET with EIP = CS.limit + 1 ================ *
     * RTL: #GP(0) AT the IRET (H-03: valid descriptor + over-limit EIP ->
     * error code 0, NOT the selector), ESP UNCHANGED (stage the expected
     * handler-entry ESP: 12 bytes of IRET frame + 16 of fault frame).
     * QEMU (oracle gap 1): transfers to a2_target and rejoins.             */
    movl    $a2_done, 0x00002080        /* staged resume */
    movl    %esp, %eax
    subl    $(12+16), %eax
    movl    %eax, 0x0000207C            /* staged expected handler-entry ESP */
    pushfl
    pushl   $0x00000040                 /* CS = limited code (limit = a2_target-1) */
    pushl   $a2_target                  /* EIP = limit + 1 */
    iret
a2_done:
    movl    $0x00090000, %esp           /* reconverge the stack in both flows */

    /* ==================== A3: same-priv RETF, EIP = CS.limit + 1 ========== *
     * The H-02 offset-past-limit restartability case (oracle gap 1): the RTL
     * must #GP(0) at the RETF with ESP UNCHANGED (8 bytes of RETF frame + 16
     * of fault frame below S). QEMU transfers to a3_target and rejoins.    */
    movl    $a3_done, 0x00002080
    movl    %esp, %eax
    subl    $(8+16), %eax
    movl    %eax, 0x0000207C
    pushl   $0x00000048                 /* CS */
    pushl   $a3_target                  /* EIP = limit + 1 */
    lret
a3_done:
    movl    $0x00090000, %esp

    /* ==================== B: outer IRET segment cleanup =================== *
     * Reachable boundary of the IRET DS/ES/FS/GS cleanup (see the header for
     * why the finding's exact DPL<RPL anomaly is unreachable): DS = 0x2B
     * (data DPL3 RPL3: survives, DPL3 >= max(3,3)), ES = 0x10 (data0 DPL0:
     * NULLED, DPL0 < new CPL3), FS = 0x30 (conforming code DPL0: SURVIVES,
     * conforming is exempt), GS = 0x20 (data3 RPL0: survives). Identical in
     * every oracle -- this is the no-false-nulling regression.             */
    movw    $0x2B, %ax
    movw    %ax, %ds
    movw    $0x10, %ax
    movw    %ax, %es
    movw    $0x30, %ax
    movw    %ax, %fs
    movw    $0x20, %ax
    movw    %ax, %gs
    pushl   $0x00000023                 /* SS = data3 RPL3 */
    pushl   $0x00088000                 /* ESP = user stack */
    pushl   $0x00003002                 /* EFLAGS: IOPL=3 (CPL3 may out 0xF4) */
    pushl   $0x0000001B                 /* CS = code3 */
    pushl   $cpl3_entry
    iret

    .global cpl3_entry
cpl3_entry:
    /* DS survived (0x2B, data DPL3) so stores through it work. Read the
     * selectors back via mov sreg,reg (register form: NO data access through
     * a possibly-null segment). */
    movw    %ds, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x0000200C            /* expect 0x2B */
    movw    %es, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x00002010            /* expect 0 (nulled) */
    movw    %fs, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x00002014            /* expect 0x30 (conforming survives) */
    movw    %gs, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x00002018            /* expect 0x20 */

    /* pack the witnesses into the GPRs (edi/esi/ecx/ebp/ebx survive the exit) */
    movl    0x00002000, %edi            /* A1 marker (0xA1A1A1A1) */
    movl    0x000020B0, %eax            /* #GP count */
    shll    $16, %eax
    orl     0x000020B4, %eax            /* err==0 count */
    movl    %eax, %esi                  /* (gp<<16)|err0: 0x00020002 RTL, 0 QEMU */
    movl    0x000020B8, %ecx            /* ESP-preserved count (2 RTL, 0 QEMU) */
    movl    0x0000200C, %eax            /* ds */
    shll    $16, %eax
    orl     0x00002010, %eax            /* es */
    movl    %eax, %ebp                  /* (ds<<16)|es = 0x002B0000 */
    movl    0x00002014, %eax            /* fs */
    shll    $16, %eax
    orl     0x00002018, %eax            /* gs */
    movl    %eax, %ebx                  /* (fs<<16)|gs = 0x00300020 */

    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* CPL==IOPL==3 */
9:  jmp     9b

    /* ==================== QEMU-only re-entry targets ====================== *
     * Reached ONLY in an oracle that does not check the return EIP against
     * CS.limit (QEMU; oracle gap 1). The RTL #GP(0)s at the return and never
     * runs these. The markers document the oracle gap inside the golden.    */
    .align 16
    .global a2_target
a2_target:
    movl    $0xA2A2A2A2, 0x00002004     /* "this oracle transferred past the limit" */
    ljmp    $0x08, $a2_done
    .align 16
    .global a3_target
a3_target:
    movl    $0xA3A3A3A3, 0x00002008
    ljmp    $0x08, $a3_done

    /* ============================ handlers ================================ *
     * bp_handler (A1): #BP frame [esp]=EIP,+4 CS,+8 EFLAGS (no error code).
     * Record A1 and return to a1_done on the FLAT code selector.           */
    .align 16
    .global bp_handler
bp_handler:
    movl    $0xA1A1A1A1, 0x00002000
    movl    $a1_done, 0(%esp)
    movl    $0x00000008, 4(%esp)
    iret

    /* gp_handler (A2/A3): same-priv frame [esp]=err,+4 EIP,+8 CS,+12 EFLAGS.
     * Count the fault; count it again if the error code is 0 (H-03: a valid
     * descriptor with an over-limit EIP is #GP(0), not #GP(selector)); count
     * once more if the entry ESP matches the staged value (the return
     * advanced nothing). Resume at the staged address, drop the error code. */
    .align 16
    .global gp_handler
gp_handler:
    incl    0x000020B0
    cmpl    $0, 0(%esp)
    jne     1f
    incl    0x000020B4
1:  cmpl    %esp, 0x0000207C
    jne     2f
    incl    0x000020B8
2:  movl    0x00002080, %eax
    movl    %eax, 4(%esp)
    addl    $4, %esp
    iret

    /* ---- builders ---------------------------------------------------------
     * set_gate0: EBX = handler offset, EDI = gate slot (P, DPL0, int32).
     * set_limited_code: EBX = limit, EDI = GDT slot: base 0, byte gran, D=1,
     * DPL0 present code (access 0x9A). */
set_gate0:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)
    ret
set_limited_code:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax           /* limit[15:0] (base[15:0] = 0) */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0x000F0000, %eax           /* limit[19:16] -> dword1[19:16] */
    orl     $0x00409A00, %eax           /* G=0 D=1, access 0x9A, base 0 */
    movl    %eax, 4(%edi)
    ret

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
