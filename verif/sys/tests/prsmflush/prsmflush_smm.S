/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * prsmflush_smm — REVIEW1_Aug4 R1-H02, case A: the SMM/RSM executable-flush
 * scenario, run TWICE so the stale line sits in way 0 in one round and way 1
 * in the other (the +ven_icflushlog probe log reports the placement; the
 * gate requires both). WITNESS-GRADED (RTL-only + QEMU free-run exit check):
 * the qemu-system gdbstub single-step path cannot trace SMM (the psmm
 * oracle-infeasibility note, reproduced in manifest.json), so no differential
 * golden exists for this image; the flow is architectural, so free-running
 * QEMU runs it to the exit.
 *
 * WHY THE STALE LINE IS AN SMM FILL OF A *REMAPPED* LINEAR ADDRESS: this
 * I-cache is linear-tagged (the per-line physical tag is only a snoop key).
 * If the SMM handler overwrote the stub's backing with CPU stores, the
 * core's own store snoop would invalidate the line by its physical tag and
 * the RSM flush would have nothing left to kill -- an earlier version of
 * this test did exactly that and was vacuous for the I-cache arrays. So the
 * mainline runs with PAGING ON and linear 0x40000 remapped to phys 0x80000
 * (the NEW stub), while SMM fetches are unpaged: the in-SMM fill of phys
 * 0x40000 (the OLD stub) is resident under linear tag 0x40 with physical
 * identity 0x40, and the resumed fetch of linear 0x40000 must NOT be served
 * those bytes. RSM restores CR0/CR3 from the save map (rsm_ctx_restore ->
 * tlb_flush -> tlb_flush_q -> exec_flush_all -- the canonical-build flush
 * source; VEN_L1_AXI builds additionally feed smm_flush). Without the flush
 * the linear lookup hits the SMM-filled line and the OLD stub runs.
 *
 *   1. mainline (paging OFF) installs: the OLD stub at phys 0x40000 (14
 *      bytes: `67 66 C7 05 <moffs32> <imm32> ; 66 C3` == mov dword [0x2104],
 *      OLD32; ret32 -- the 67/66 prefixes make it decode identically in the
 *      16-bit SMM context and in 32-bit protected mode), the NEW stub at phys
 *      0x80000 (movl $NEW32, 0x2100; ret32; nop), lone `66 C3` ret32 dummies
 *      at phys 0x41000/0x42000 (SAME I-cache set as the stub: addr[11:5]
 *      identical, tag differs), the SMM entry trampoline at phys 0x38000 (a
 *      near jump to the body at phys 0x38100 -- a DIFFERENT set, so the
 *      handler's own fetches never perturb the stub set's fill history).
 *   2. page tables: PT0 identity 4 MiB except linear 0x40000 -> phys 0x80000;
 *      PT1 maps the APIC page. CR3 load, paging ON, APIC enabled.
 *   3. round N: the mainline stores the round number to 0x210C, pushes the
 *      continuation address, and fires the SMI (APIC self-IPI, SMI delivery
 *      mode -- same mechanism as psmm).
 *   4. the SMM handler body (16-bit SMM context, CS base = SMBASE, so the
 *      stub is EIP 0x10000 and the dummies EIP 0x11000/0x12000): round 1
 *      CALLs the stub only; round 2 CALLs dummy + dummy2 first. Hit touches
 *      do not move the replacement victim in this I-cache (fills-only age
 *      model), so fills strictly alternate the two ways and the extra dummy
 *      fill in round 2 flips the parity -- the stale stub line sits in the
 *      OPPOSITE way from round 1 at the RSM edge. In both rounds the stub is
 *      the most recently filled line of its set, so the post-flush refill
 *      must land on a DIFFERENT way: a flush that leaves the stale way valid
 *      yields two valid ways sharing the stub's linear tag (the
 *      ICACHE/DUP-TAG assertion) with hit priority serving the OLD bytes.
 *      The handler then writes 0x00040000 into the save-map EIP slot
 *      (SMBASE+0xFFF0 = 0x3FFF0; EIP is at the same offset in the P5 layout
 *      this RTL implements and in QEMU's P6 layout) and RSMs.
 *   5. the resumed fetch at linear 0x40000 must REFILL from phys 0x80000 and
 *      execute the NEW stub; its ret32 pops the continuation. post_rN
 *      verifies:
 *        0x2100 == NEW32 (the refill executed the NEW bytes -- THE
 *                         discriminator; pre-fix it stays 0 and 0x2104 takes
 *                         OLD32)
 *        0x2104 == OLD32 (the OLD stub ran during the in-SMM fill)
 *        ebx    == 0x5A4D900D (RSM restored the interrupted GPRs)
 *      and post_r2 exits with the usual isa-debug-exit witnesses.
 *
 * Memory plan: GDT @0x500 (null + code0 0x08 + data0 0x10 + TSS 0x18),
 * markers @0x2000..0x2110, PD @0x11000, PT0 @0x12000, PT1 @0x13000 (APIC),
 * OLD stub @phys 0x40000, dummies @phys 0x41000/0x42000, NEW stub @phys
 * 0x80000, SMBASE 0x30000 (trampoline 0x38000, body 0x38100, save-map EIP
 * slot 0x3FFF0), APIC @0xFEE00000, stack @0x90000. GNU-as; no nasm.
 * Flat 64 KiB -bios image; reset F000:FFF0.
 */

.set OLD32, 0x5A4D0001
.set NEW32, 0x5A4D0002

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

    /* GDT @ 0x500: null, 0x08 code32 flat, 0x10 data32 flat, 0x18 TSS (as psmm) */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x30000067, 24(%ebx)       /* 0x18: TSS base 0x3000 limit 0x67 */
    movl    $0x00008900, 28(%ebx)       /* P, type 9 (available 32-bit TSS) */
    movw    $0x001F, 0x0480
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

    /* clear CR0.CD/NW (both set out of reset) so fetched lines are retained
     * and the stub line's way occupancy is real (see prsmflush.S) */
    movl    %cr0, %eax
    andl    $0x9FFFFFFF, %eax
    movl    %eax, %cr0

    /* zero the sentinel area 0x2000..0x2110 */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $68, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* arm debug + task state (psmm parity: gives the save map real content) */
    movl    $0x000F0400, %eax
    movl    %eax, %dr7
    movw    $0x0018, %ax
    ltr     %ax

    /* install (paging still OFF -> linear == phys): the OLD stub at phys
     * 0x40000, the NEW stub at phys 0x80000, the dummy ret32s at phys
     * 0x41000/0x42000, the entry trampoline (jmp +0x100) at phys 0x38000,
     * the handler body at phys 0x38100 */
    movl    $x_old_template, %esi
    movl    $0x00040000, %edi
    movl    $14, %ecx
    rep movsb
    movl    $x_new_template, %esi
    movl    $0x00080000, %edi
    movl    $12, %ecx
    rep movsb
    movb    $0x66, 0x00041000
    movb    $0xC3, 0x00041001             /* dummy: ret32 */
    movb    $0x66, 0x00042000
    movb    $0xC3, 0x00042001             /* dummy2: ret32 */
    movb    $0xE9, 0x00038000             /* trampoline: jmp rel16 +0xFD -> */
    movb    $0xFD, 0x00038001             /*   EIP 0x8003 + 0xFD = 0x8100    */
    movb    $0x00, 0x00038002             /*   (phys 0x38100, the body)      */
    movl    $smm_body, %esi
    movl    $0x00038100, %edi
    movl    $smm_body_end - smm_body, %ecx
    rep movsb

    /* page tables: PT0 identity 4 MiB except linear 0x40000 -> phys 0x80000;
     * PT1[0x300] maps the APIC page (PDE 0x3FB covers [0xFEC00000,0xFF000000)) */
    movl    $0x00012000, %edi
    movl    $0x00000003, %eax
    movl    $1024, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00080003, 0x00012000 + 0x40*4   /* linear 0x40000 -> 0x80000 */
    movl    $0xFEE00003, 0x00013000 + 0x200*4  /* the APIC page (idx 0x200) */
    movl    $0x00012003, 0x00011000            /* PD[0] -> PT0 */
    movl    $0x00013003, 0x00011000 + 0x3FB*4  /* PD[0x3FB] -> PT1 (APIC) */

    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0                  /* CR0.PG = 1 */

    /* enable the local APIC (SVR @ 0xFEE000F0, bit 8) -- through paging now */
    movl    $0xFEE000F0, %edi
    movl    (%edi), %eax
    orl     $0x100, %eax
    movl    %eax, (%edi)

    movl    $0x5A4D900D, %ebx           /* state-intact witness GPR */

    /* ============================ round 1 ================================= */
    movl    $1, 0x0000210C              /* handler order: stub only */
    pushl   $post_r1                    /* the stub's post-RSM ret32 target */
    movl    $0xFEE00300, %edi           /* fire a self-IPI, delivery = SMI */
    movl    $0x00040200, %eax
    movl    %eax, (%edi)
    movl    $4096, %ecx                 /* spin so the SMI has room to fire */
1:  pause
    loop    1b

post_r1:
    movl    %ebx, 0x00002108            /* RSM GPR-restore proof */
    cmpl    $NEW32, 0x00002100
    je      2f
    movl    $0x21, %edi                 /* the STALE SMM line ran post-RSM */
    jmp     fail_exit
2:  cmpl    $OLD32, 0x00002104
    je      3f
    movl    $0x22, %edi                 /* the in-SMM fill never executed */
    jmp     fail_exit
3:

    /* ============================ round 2 ================================= */
    movl    $0, 0x00002100              /* re-arm the discriminators (NO stub */
    movl    $0, 0x00002104              /* reinstall: the backing never       */
    movl    $2, 0x0000210C              /* changes in this design -- the      */
    pushl   $post_r2                    /* staleness is the SMM fill's linear */
    movl    $0xFEE00300, %edi           /* tag, not the bytes)                */
    movl    $0x00040200, %eax
    movl    %eax, (%edi)
    movl    $4096, %ecx
1:  pause
    loop    1b

post_r2:
    cmpl    $NEW32, 0x00002100
    je      2f
    movl    $0x24, %edi                 /* round 2: the STALE SMM line ran */
    jmp     fail_exit
2:  cmpl    $OLD32, 0x00002104
    je      3f
    movl    $0x25, %edi                 /* round 2: the in-SMM fill missing */
    jmp     fail_exit
3:  cmpl    $0x5A4D900D, 0x00002108
    je      4f
    movl    $0x23, %edi                 /* RSM GPR restore broken */
    jmp     fail_exit
4:
    movl    0x00002100, %edi            /* NEW32 -- post-RSM refill executed */
    movl    0x00002104, %esi            /* OLD32 -- the in-SMM fill executed */
    movl    0x00002108, %ebp            /* 0x5A4D900D -- RSM restored the GPRs */
    movl    $0x52455421, %ebx           /* 'RET!' mainline resumed */
    movl    $0x42, %ecx
    movl    $0x600D600D, %edx
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx                    /* qemu status = (0x42<<1)|1 = 133 */
9:  hlt
    jmp     9b

    .align 16
    .global fail_exit
fail_exit:                              /* edi = the failing check's code */
    movl    %edi, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

/* ===================== OLD stub template (14 bytes) ====================== *
 * 67 66 C7 05 <moffs32> <imm32> ; 66 C3  ==  mov dword [0x2104], OLD32 ;
 * ret32. The 67/66 prefixes make the body decode identically in 16-bit SMM
 * and in 32-bit protected mode; the 66 C3 matches the handler's 32-bit
 * (4-byte) call push. Executed ONCE per round, in SMM -- the write proves
 * the in-SMM fill happened (and the line went resident under linear tag
 * 0x40 with physical identity 0x40).                                       */
    .align 16
x_old_template:
    .byte   0x67, 0x66, 0xC7, 0x05, 0x04, 0x21, 0x00, 0x00
    .long   OLD32
    .byte   0x66, 0xC3
x_old_template_end:

/* ===================== NEW stub template (12 bytes) ====================== *
 * C7 05 <moffs32> <imm32> ; C3 90  ==  movl $NEW32, 0x2100 ; ret32 ; nop.
 * Lives at phys 0x80000 and runs only in the resumed (paged) context, where
 * linear 0x40000 translates there. Executed once per round -- THE
 * discriminator for the RSM flush.                                         */
    .align 16
x_new_template:
    .byte   0xC7, 0x05, 0x00, 0x21, 0x00, 0x00
    .long   NEW32
    .byte   0xC3, 0x90
x_new_template_end:

/* ============================ SMM HANDLER BODY ===========================
 * Hand-encoded (16-bit SMM default; DS base 0; CS base = SMBASE). Copied to
 * phys 0x38100 (EIP 0x8100 -- NOT the stub's cache set, so the body's own
 * fetches never touch the stub set's fill history between the calls). The
 * entry trampoline at EIP 0x8000 jumps here. Round flag at [0x210C]: 1 =
 * call the stub only, 2 = call the two dummies first (the extra fill flips
 * the way parity, so the stale stub line sits in the OPPOSITE way from
 * round 1 at the RSM edge; in both rounds the stub is the most recently
 * filled line of its set, so the post-flush refill lands on a different
 * way).
 *   67 66 A1 <moffs32>          mov eax, [0x210C]
 *   66 83 F8 02                 cmp eax, 2
 *   66 0F 85 <rel32>            jnz smm_call_stub   (round 1: no dummies)
 *   66 E8 <rel32>               call EIP 0x11000    (dummy: ret32)
 *   66 E8 <rel32>               call EIP 0x12000    (dummy2: ret32)
 * smm_call_stub:
 *   66 E8 <rel32>               call EIP 0x10000    (the stub: fill)
 *   67 66 C7 05 F0 FF 03 00 00 00 04 00   mov dword [0x3FFF0], 0x00040000
 *   0F AA                       rsm
 * Only EAX is clobbered, and the SMM save map restores it; the mainline's EBX
 * witness is never touched. */
    .align 16
    .global smm_body
smm_body:
    .byte   0x67, 0x66, 0xA1
    .long   0x0000210C
    .byte   0x66, 0x83, 0xF8, 0x02
    .byte   0x66, 0x0F, 0x85
    .long   smm_call_stub - . - 4
smm_call_dummy:
    .byte   0x66, 0xE8
    .long   0x00011000 - (0x00008100 + smm_call_dummy - smm_body) - 6
smm_call_dummy2:
    .byte   0x66, 0xE8
    .long   0x00012000 - (0x00008100 + smm_call_dummy2 - smm_body) - 6
smm_call_stub:
    .byte   0x66, 0xE8
    .long   0x00010000 - (0x00008100 + smm_call_stub - smm_body) - 6
    /* save-map EIP slot <- 0x00040000 (resume at linear 0x40000) */
    .byte   0x67, 0x66, 0xC7, 0x05, 0xF0, 0xFF, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00
    .byte   0x0F, 0xAA
    .global smm_body_end
smm_body_end:

/* ===================== 16-bit reset stub @ 0xFFF0 ======================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
