/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.4 — bare-metal HARDWARE TASK SWITCH demonstrator (STRETCH).
 *
 * This is the M2S.4 ptask STRETCH test.  pcpl exercises the cross-privilege
 * machinery (TSS stack switch + the 5-word frame + inter-priv IRET).  ptask
 * exercises the OTHER big M2S.4 piece: a HARDWARE TASK SWITCH via a far JMP to a
 * TSS descriptor.  On `ljmp $TSS2_sel, $0`:
 *   - the CPU SAVES the outgoing task's state (EIP/EFLAGS/GPRs/segs/ESP/...) into
 *     the CURRENT TSS (the one TR points at, here TSS1),
 *   - LOADS the incoming task's state from the new TSS (TSS2): EIP/EFLAGS/GPRs/
 *     segments/ESP/CR3/LDTR,
 *   - toggles the BUSY bits (clears busy on the old TSS for a JMP; sets busy on
 *     the new one) and points TR at TSS2.  (A JMP does NOT set NT / back-link;
 *     only a CALL/interrupt-task-gate does.  We use JMP to keep it simpler.)
 *
 * The test is made DETERMINISTIC + OBSERVABLE:
 *   - TSS1 (current) is loaded with LTR; its saved-state fields are zeroed (the
 *     CPU fills them on the outgoing save).
 *   - TSS2 (target) is pre-initialised with a full task-state image: EIP=task2,
 *     ESP=a private task2 stack, EFLAGS=0x2, CS=0x08, SS/DS/ES/FS/GS=0x10,
 *     CR3=0 (paging off), LDTR=0, plus a marker GPR pattern (EAX/EBX) so the
 *     golden shows the GPRs RELOAD from the incoming TSS image across the switch.
 *   - `ljmp $0x30,$0` performs the task switch -> task2 runs with the reloaded
 *     state (the golden shows CS:EIP jump to task2 + the GPRs taking the TSS2
 *     image values), records markers, and exits via isa-debug-exit.
 *
 * Why a one-way JMP (not a round trip): a full round trip (task2 JMPs back to
 * TSS1) is the gnarliest variant (it must reload the SAVED TSS1 image the CPU
 * just wrote, with the back-link/NT semantics); we keep ptask to the ONE-WAY
 * switch so it is deterministic and the save+load+busy-toggle is cleanly
 * observable.  The round-trip / CALL-with-NT / interrupt-task-gate variants are
 * noted as deferred.
 *
 * NO paging (linear == physical).  Flat 64 KiB -bios image; reset F000:FFF0.
 *
 * Memory plan (machine -m 32 => 32 MiB phys):
 *   GDT  @ 0x00000500   null + code0 0x08 + data0 0x10 + TSS1 0x20 + TSS2 0x28
 *   markers @ 0x00002000
 *   TSS1 @ 0x00003000   (current task; LTR'd; CPU saves outgoing state here)
 *   TSS2 @ 0x00004000   (target task; pre-initialised state image)
 *   task1 stack @ 0x00090000 ; task2 stack @ 0x00070000
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,ptask.ld; objcopy -O binary,
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

    /* --- build the GDT (6 entries = 48 bytes) at linear 0x0500 ---
     * idx0 null
     * idx1 0x08 code32 flat DPL0   (access 0x9A, gran 0xCF)
     * idx2 0x10 data32 flat DPL0   (access 0x92, gran 0xCF)
     * idx3 0x18 unused (zero)
     * idx4 0x20 TSS1 (available, base 0x3000, limit 0x67, access 0x89)
     * idx5 0x28 TSS2 (available, base 0x4000, limit 0x67, access 0x89)
     * (The two TSS descriptors are at GDT indices 4 and 5 so their selectors are
     *  0x20 and 0x28; idx3 0x18 stays a zero filler so the limit math is simple.)
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x00000000, 24(%ebx)       /* idx3 0x18 filler (zero) */
    movl    $0x00000000, 28(%ebx)
    /* idx4 0x20 TSS1: base 0x00003000, limit 0x67, access 0x89 (32-bit avail TSS) */
    movl    $0x30000067, 32(%ebx)       /* limit=0x0067, base[15:0]=0x3000 */
    movl    $0x00008900, 36(%ebx)       /* base[23:16]=0,access=0x89,gran=0,base[31:24]=0 */
    /* idx5 0x28 TSS2: base 0x00004000, limit 0x67, access 0x89 */
    movl    $0x40000067, 40(%ebx)       /* limit=0x0067, base[15:0]=0x4000 */
    movl    $0x00008900, 44(%ebx)       /* base[23:16]=0,access=0x89,gran=0,base[31:24]=0 */

    movw    $0x002F, 0x0480             /* GDT limit = 48-1 = 0x2F (6 entries) */
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
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp           /* task1 (current) stack */

    /* --- zero the marker area at 0x2000..0x2040 --- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== zero both TSS images ========================== */
    /* TSS1 @ 0x3000 (outgoing-save target) + TSS2 @ 0x4000 (incoming image). */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $52, %ecx                   /* 52 dwords = 208 bytes = both TSSes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* I/O map base of TSS1 (offset 0x66) = 0x68 (empty I/O map). */
    movw    $0x0068, 0x00003066

    /* ===================== pre-init TSS2 (the incoming task) ============== *
     * 32-bit TSS field offsets:
     *   0x1C CR3      0x20 EIP     0x24 EFLAGS  0x28 EAX  0x2C ECX  0x30 EDX
     *   0x34 EBX      0x38 ESP     0x3C EBP     0x40 ESI  0x44 EDI
     *   0x48 ES       0x4C CS      0x50 SS      0x54 DS   0x58 FS   0x5C GS
     *   0x60 LDTR     0x66 IOmapbase
     * Base of TSS2 = 0x4000, so field X is at 0x4000+X.                       */
    movl    $0x00000000, 0x0000401C     /* CR3 = 0 (paging off) */
    movl    $task2,      0x00004020     /* EIP = task2 */
    movl    $0x00000002, 0x00004024     /* EFLAGS = 0x2 (reserved bit; IF=0) */
    movl    $0xAAAAAAAA, 0x00004028     /* EAX (marker: reloaded from TSS2) */
    movl    $0x00000000, 0x0000402C     /* ECX */
    movl    $0x00000000, 0x00004030     /* EDX */
    movl    $0xBBBBBBBB, 0x00004034     /* EBX (marker: reloaded from TSS2) */
    movl    $0x00070000, 0x00004038     /* ESP = task2 private stack top */
    movl    $0x00000000, 0x0000403C     /* EBP */
    movl    $0x00000000, 0x00004040     /* ESI */
    movl    $0x00000000, 0x00004044     /* EDI */
    movl    $0x00000010, 0x00004048     /* ES = 0x10 */
    movl    $0x00000008, 0x0000404C     /* CS = 0x08 */
    movl    $0x00000010, 0x00004050     /* SS = 0x10 */
    movl    $0x00000010, 0x00004054     /* DS = 0x10 */
    movl    $0x00000010, 0x00004058     /* FS = 0x10 */
    movl    $0x00000010, 0x0000405C     /* GS = 0x10 */
    movl    $0x00000000, 0x00004060     /* LDTR = 0 (no LDT) */
    movw    $0x0068,     0x00004066     /* I/O map base (empty) */

    /* LTR TSS1 (selector 0x20): TR now points at the CURRENT task = TSS1. */
    movw    $0x0020, %ax
    ltr     %ax

    /* clear the visible accumulator GPRs (so the GPR RELOAD from TSS2 is stark) */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %edi, %edi

    /* mark "about to task switch" + stash a known value so the OUTGOING SAVE into
     * TSS1 captures a recognisable EAX (the CPU saves the live EAX at the jmp). */
    movl    $0x11111111, 0x00002000     /* "task1 reached the switch point" */
    movl    $0x1A1A1A1A, %eax           /* live EAX the outgoing save records */

    /* ===================== THE HARDWARE TASK SWITCH ====================== */
    /* Far JMP to the TSS2 selector (0x30), offset ignored.  The CPU:
     *   - saves task1 state into TSS1 (TR), incl. EIP=next insn after the jmp,
     *   - clears TSS1 busy (JMP), loads TSS2 state, sets TSS2 busy, TR<-0x30,
     *   - resumes at TSS2.EIP = task2 with the reloaded GPRs/segs/ESP.
     * Hand-encode `ljmp $0x28, $0` (opsize-32 not needed; selector:offset16/32).
     * GNU as: `ljmp $0x28, $task1_after` would jump to a code offset; we instead
     * want a TASK-GATE-style far jmp whose SELECTOR is a TSS -> use ljmp imm. */
    ljmp    $0x28, $0                   /* TASK SWITCH to TSS2 (offset ignored) */

    /* The outgoing task would resume HERE if something ever switched back to
     * TSS1; in this one-way test nothing does, so this is unreachable. */
task1_resumed:
    movl    $0x99999999, 0x00002010     /* (only if a switch-back ever happens) */
hang1:
    hlt
    jmp     hang1

    /* ============================== task2 =============================== *
     * The INCOMING task.  Entered by the hardware task switch with the state
     * loaded from TSS2: EAX=0xAAAAAAAA, EBX=0xBBBBBBBB, ESP=0x00070000, segs=0x10,
     * CS=0x08, EFLAGS=0x2.  It records markers proving the reload happened, then
     * performs the isa-debug-exit.                                              */
    .align 16
    .global task2
task2:
    /* prove the GPR image reloaded from TSS2 */
    movl    %eax, 0x00002020            /* expect 0xAAAAAAAA */
    movl    %ebx, 0x00002024            /* expect 0xBBBBBBBB */
    movl    %esp, 0x00002028            /* expect ~0x00070000 (task2 stack) */
    /* sentinel: task2 is running (post task-switch) */
    movl    $0x22222222, 0x0000202C

    /* BUSY-bit toggle proof: read the access bytes of the two TSS descriptors.
     * After a JMP task switch the OLD TSS (TSS1) busy bit is CLEARED (type 9 ->
     * access 0x89 = available) and the NEW TSS (TSS2) busy bit is SET (type B ->
     * access 0x8B = busy).  GDT base 0x500: TSS1 access @ 0x500+0x20+5 = 0x525,
     * TSS2 access @ 0x500+0x28+5 = 0x52D.  Record both as markers.            */
    movzbl  0x00000525, %eax            /* TSS1 access byte (expect 0x89 avail) */
    movl    %eax, 0x00002030
    movzbl  0x0000052D, %eax            /* TSS2 access byte (expect 0x8B busy)  */
    movl    %eax, 0x00002034

    /* success proof into the GPRs:
     *   ECX = task2 sentinel (0x22222222) -- only set if task2 ran
     *   EDX = the TSS1 SAVED EIP (the CPU wrote task1's resume EIP into TSS1.EIP
     *         at 0x3020 during the outgoing save) -- proof the outgoing SAVE
     *         happened; nonzero == a state save occurred.
     *   ESI = TSS1 SAVED EAX (0x3028) -- expect 0x1A1A1A1A (the live EAX at the
     *         jmp) -- proof the outgoing GPR save captured the live register.
     *   EDI = (TSS1_access << 8) | TSS2_access -- expect 0x898B (TSS1 available,
     *         TSS2 busy) -- proof the busy-bit toggle happened across the JMP.  */
    movl    $0x22222222, %ecx
    movl    0x00003020, %edx            /* TSS1 saved EIP (nonzero) */
    movl    0x00003028, %esi            /* TSS1 saved EAX (expect 0x1A1A1A1A) */
    movl    0x00002030, %edi            /* TSS1 access byte */
    shll    $8, %edi
    orl     0x00002034, %edi            /* edi = (TSS1_acc<<8)|TSS2_acc = 0x898B */

    /* isa-debug-exit: out 0xf4, 0x42 -> qemu status (0x42<<1)|1 = 0x85. */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang2:
    hlt
    jmp     hang2

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off                /* 16-bit offset within segment 0xF000 */
    .word   0xF000                      /* segment */
