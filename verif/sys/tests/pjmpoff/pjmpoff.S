/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug4 A4-C02 — direct far-transfer target OFFSET vs the code-segment
 * LIMIT: the rejected transfer must install NOTHING.
 *
 * The defect: the far-transfer commit arm scheduled the CS/CPL/EIP writes
 * BEFORE the target-offset-vs-limit check, so a direct far JMP whose offset
 * exceeded the limit raised its #GP(0) from the PARTIALLY INSTALLED target
 * state -- the handler ran with the target's CS/CPL live and the exception
 * frame pushed the TARGET code selector. Architecturally the #GP(0) must be
 * delivered in the SOURCE context: nothing of the rejected target (CS
 * base/limit/attributes, CPL, hidden cache) may become live, and the frame
 * must name the source transfer instruction.
 *
 * Four cases in one image, all at CPL0 (the defect is privilege-independent),
 * all differential against the QEMU golden (helper_ljmp_protected checks
 * new_eip > limit BEFORE cpu_x86_load_seg_cache -- QEMU is an exact oracle
 * for the direct far JMP):
 *
 *   (1) direct far JMP, offset = limit+1: selector 0x18 (code32 DPL0, base
 *       0xF0000, limit 0x8000), target offset 0x8001 -> #GP(0). The handler
 *       records the vector, the error code, the pushed frame's CS/EIP, its
 *       own ESP, and reads back its GDT descriptor INDEXED BY THE PUSHED CS:
 *       pushed CS == the SOURCE 0x08 (not the rejected 0x18), pushed EIP ==
 *       the ljmp, error code == 0. With the defect the frame's CS reads 0x18
 *       and the descriptor read-back returns the TARGET descriptor
 *       (0x00409A0F instead of 0x00CF9A00) -- the diff diverges at the exit.
 *   (2) same-privilege far RETF, offset == limit (BOUNDARY SUCCESS): a
 *       fabricated frame returns to 0x18:0x8000. The transfer must SUCCEED
 *       (offset == limit is legal: valid EIP range is 0..limit inclusive);
 *       the one-byte `lret` marker there pops a second fabricated frame back
 *       to the flat mainline. ESP before the pushes is stashed and compared
 *       against ESP after the round-trip (the pops commit exactly once).
 *   (3) direct far JMP, offset == limit (BOUNDARY SUCCESS): same target, the
 *       same marker `lret` returns through a fabricated frame. No #GP may
 *       fire in EITHER oracle.
 *   (4) 16-bit variant: selector 0x20 (code16 DPL0, D=0, base 0xF0000, limit
 *       0x0040), an operand-16 ljmp (66 EA, ptr16:16) to offset 0x0041 =
 *       limit+1 -> #GP(0), same source-context witnesses as case (1).
 *
 * ORACLE GAP (documented, like piretgp0's): QEMU 8.2.2's helper_ret_protected
 * has NO return-EIP-vs-limit check (neither RETF nor IRET -- piretgp0's
 * oracle gap 1), so the FAULTING same-privilege RETF (offset = limit+1 ->
 * #GP(0), ESP exactly preserved) is NOT differentially testable: QEMU would
 * transfer successfully where the SDM and the fixed RTL #GP. Case (2) covers
 * the RETF commit path on its LEGAL boundary instead; the ESP-preservation
 * property of a REJECTED retf is already pinned differentially by pretfres
 * (H-02, not-present CS). The faulting-RETF offset check is RTL-vs-SDM only.
 *
 * Memory plan (NO paging -- the commit-ordering defect is paging-independent):
 *   GDT  @ 0x00000500   null + code0 0x08 (flat) + data0 0x10 (flat)
 *                       + code32 0x18 (base 0xF0000, limit 0x8000)
 *                       + code16 0x20 (base 0xF0000, limit 0x0040, D=0)
 *   IDT  @ 0x00001000   gate 13 (#GP) -> gp_handler (interrupt gate, CPL0)
 *   markers @ 0x00002000
 *   boundary marker `lret` @ 0x000F8000 (image offset 0x8000 = the limit)
 *   CPL0 stack 0x7000
 *
 * WITNESSES (marker page; the discriminating ones are pulled into GPRs at the
 * exit for the differential -- memory is not traced):
 *   0x2000  0x0000000D -- case (1) vector (edi at exit)
 *   0x2004  0x00000000 -- case (1) error code (#GP(0))
 *   0x2008  0x00000008 -- case (1) PUSHED CS = the SOURCE selector (esi)
 *   0x200C  case (1) pushed EIP = the ljmp's linear address
 *   0x2010  0x00CF9A00 -- GDT descriptor high dword read back via the pushed
 *           CS index: the FLAT source descriptor, proving the frame names the
 *           source (ebp). The defect reads back the target's 0x00409A0F.
 *   0x2014  ESP stashed before case (2)'s pushes
 *   0x2018  case (1) handler-entry ESP
 *   0x2024  ESP after case (2)'s boundary-RETF round-trip (== 0x2014)
 *   0x2030  0x0000000D -- case (4) vector
 *   0x2034  0x00000000 -- case (4) error code
 *   0x2038  0x00000008 -- case (4) PUSHED CS = the SOURCE selector (ecx)
 *   0x203C  case (4) pushed EIP = the 66 EA ljmp's linear address
 *   0x2044  scratch: the current case index for the shared handler
 *   exit ebx = 0xB0B0B0B0 iff err1==0 AND err4==0 AND case-(2) ESP round-trips
 *
 * GNU-as syntax; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    %ax, %ds
    movw    $0x7000, %sp

    /* GDT at 0x0500 (5 entries, limit 0x27):
     *   0x08 code32 DPL0 flat              0x10 data32 DPL0 flat
     *   0x18 code32 DPL0 base 0xF0000 limit 0x8000 (the cases 1-3 target)
     *   0x20 code16 DPL0 base 0xF0000 limit 0x0040 D=0 (the case-4 target) */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 DPL0 flat */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 DPL0 flat */
    movl    $0x00cf9200, 0x0514
    /* base 0x000F0000 -> low = base[15:0]<<16 | limit = 0x00008000;
     * high = base[31:24] | gran(0x40: G=0 D=1, lim[19:16]=0)<<16 | 0x9A00
     *      | base[23:16]=0x0F                                            */
    movl    $0x00008000, 0x0518        /* 0x18 code32 DPL0 limit 0x8000 */
    movl    $0x00409a0f, 0x051c
    movl    $0x00000040, 0x0520        /* 0x20 code16 DPL0 limit 0x0040, D=0 */
    movl    $0x00009a0f, 0x0524

    movw    $0x0027, 0x0480            /* GDT limit = 5*8-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                 /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry
    .word   0x08

    .code32
    .section .text32,"ax"
    .global pm_entry
pm_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x00007000, %esp

    /* ---- zero the marker area 0x2000..0x2048 ---- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $18, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: gate 13 (#GP) -> gp_handler, interrupt gate CPL0 ----
     * low = {sel 0x08}<<16 | off[15:0]; high = off[31:16] | 0x8E00 (P|int32). */
    movl    $gp_handler, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1068               /* 0x1000 + 13*8 */
    movl    $gp_handler, %eax
    andl    $0xffff0000, %eax
    orl     $0x00008e00, %eax
    movl    %eax, 0x106c
    movw    $0x07FF, 0x0490            /* IDT limit */
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- case (1): direct far JMP, offset = limit+1 (0x8001 > 0x8000)
     * -> #GP(0), NOTHING installed. Hand-encoded ljmp ptr16:32 (7 bytes;
     * the handler skips exactly this length). Resumes at the next insn. ---- */
    movl    $1, 0x00002044
    .byte   0xEA
    .long   0x00008001                 /* offset = limit+1 */
    .word   0x0018                     /* the limited code32 segment */
    /* the handler resumes HERE (it advanced the saved EIP by 7) */

    /* ---- case (2): same-privilege far RETF, offset == limit (BOUNDARY
     * SUCCESS). Stack at the lret (top first): [0x8000][0x18][cont2][0x08]
     * -- the lret pops the boundary frame (offset == limit is LEGAL) and the
     * one-byte marker lret at 0x18:0x8000 pops the return frame back here.
     * ESP is stashed before the pushes and re-read after: the two retfs must
     * pop exactly the four dwords (no more, no fewer).                     ---- */
    movl    %esp, 0x00002014           /* stash ESP before the pushes */
    pushl   $0x00000008                /* marker-return frame: CS  (flat) */
    pushl   $cont2                     /* marker-return frame: EIP */
    pushl   $0x00000018                /* boundary frame: CS  (limited seg) */
    pushl   $0x00008000                /* boundary frame: EIP == limit */
    lret                               /* -> 0x18:0x8000 (marker lret) -> cont2 */
cont2:
    movl    %esp, 0x00002024           /* must equal the stashed 0x2014 */

    /* ---- case (3): direct far JMP, offset == limit (BOUNDARY SUCCESS).
     * The JMP keeps the stack; the marker lret pops the fabricated frame. ---- */
    pushl   $0x00000008
    pushl   $cont3
    .byte   0xEA
    .long   0x00008000                 /* offset == limit: must TRANSFER */
    .word   0x0018
cont3:

    /* ---- case (4): 16-bit variant. code16 (D=0) limit 0x0040; an opsize-16
     * ljmp (66 EA, ptr16:16, 6 bytes) to offset 0x0041 = limit+1 -> #GP(0). -- */
    movl    $4, 0x00002044
    .byte   0x66, 0xEA
    .word   0x0041                     /* offset = limit+1 */
    .word   0x0020                     /* the limited code16 segment */
    /* the handler resumes HERE (it advanced the saved EIP by 6) */

    /* ---- exit: fold the memory witnesses into the GPRs for the final-record
     * compare. ebx is the composite: 0xB0B0B0B0 iff both error codes are 0
     * AND case (2)'s ESP round-tripped exactly.                             */
    xorl    %ebx, %ebx
    cmpl    $0, 0x00002004             /* case (1) #GP(0) */
    jne     1f
    cmpl    $0, 0x00002034             /* case (4) #GP(0) */
    jne     1f
    movl    0x00002014, %eax
    cmpl    0x00002024, %eax           /* case (2) ESP preserved across pops */
    jne     1f
    movl    $0xB0B0B0B0, %ebx
1:
    movl    0x00002000, %edi           /* case (1) vector (13) */
    movl    0x00002008, %esi           /* case (1) pushed CS (0x08) */
    movl    0x00002010, %ebp           /* case (1) desc read-back (0x00CF9A00) */
    movl    0x00002038, %ecx           /* case (4) pushed CS (0x08) */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    /* ========================= boundary marker ============================
     * At image offset 0x8000 == linear 0x000F8000 == 0x18:0x8000 (the limit).
     * A single byte: executing AT the limit is legal (the fetch-start check
     * faults only past it, and the default build has no fetch check at all),
     * and the lret transfers out before any further fetch in the segment.  */
    .section .marker,"ax"
    .global boundary_marker
boundary_marker:
    lret

    /* ============================ #GP handler ============================= */
    .section .text32,"ax"
    .global gp_handler
gp_handler:
    /* Same-privilege #GP frame: 0(%esp)=err 4=EIP 8=CS 12=EFLAGS. Dispatch on
     * the case index the mainline stashed. DS is still the flat 0x10 (no
     * privilege change, nothing nulled).                                    */
    cmpl    $1, 0x00002044
    jne     gp_case4
    /* ---- case (1): the 7-byte direct ljmp -------------------------------- */
    movl    $0x0000000D, 0x00002000    /* vector 13 */
    movl    (%esp), %eax
    movl    %eax, 0x00002004           /* error code: expect 0 (#GP(0)) */
    movl    8(%esp), %eax
    movl    %eax, 0x00002008           /* pushed CS: expect SOURCE 0x00000008 */
    movl    4(%esp), %eax
    movl    %eax, 0x0000200C           /* pushed EIP = the ljmp */
    movl    %esp, %eax
    movl    %eax, 0x00002018           /* handler-entry ESP */
    /* Read back the GDT descriptor high dword INDEXED BY THE PUSHED CS: with
     * the source context installed this returns the flat code32 descriptor
     * (0x00CF9A00); with the defect's target context it returns the limited
     * target's (0x00409A0F).                                                */
    movl    8(%esp), %eax
    andl    $0x0000fff8, %eax          /* pushed CS & ~7 (TI=0 -> GDT) */
    movl    0x0504(%eax), %eax         /* GDT @ 0x500, +4 = the high dword */
    movl    %eax, 0x00002010
    addl    $7, 4(%esp)                /* resume past the 7-byte ljmp */
    addl    $4, %esp                   /* pop the error code */
    iretl
    /* ---- case (4): the 6-byte opsize-16 ljmp ----------------------------- */
gp_case4:
    movl    $0x0000000D, 0x00002030    /* vector 13 */
    movl    (%esp), %eax
    movl    %eax, 0x00002034           /* error code: expect 0 */
    movl    8(%esp), %eax
    movl    %eax, 0x00002038           /* pushed CS: expect SOURCE 0x00000008 */
    movl    4(%esp), %eax
    movl    %eax, 0x0000203C           /* pushed EIP = the 66 EA ljmp */
    addl    $6, 4(%esp)                /* resume past the 6-byte ljmp */
    addl    $4, %esp
    iretl

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
