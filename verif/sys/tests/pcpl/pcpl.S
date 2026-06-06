/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.4 — bare-metal CROSS-PRIVILEGE (TSS / stack-switch) demonstrator.
 *
 * This is the M2S.4 pcpl gate test.  M2S.3 (pintr/pfault) delivered faults and
 * software interrupts to SAME-privilege (CPL0) handlers with no stack switch.
 * M2S.4 adds the privilege machinery:
 *   - TR / TSS (LTR + a 32-bit TSS with SS0:ESP0 = a dedicated CPL0 stack),
 *   - a transfer DOWN to CPL3 (build a 5-word inter-priv frame and IRET to a
 *     DPL=3 code segment so CPL goes 0 -> 3, SS/ESP switch to the CPL3 stack),
 *   - CROSS-privilege interrupt delivery: from CPL3, INT n through a DPL=3 IDT
 *     gate whose target CS is DPL=0.  Because target CS.DPL (0) < CPL (3), the
 *     CPU loads SS:ESP from TSS.SS0:ESP0 and pushes the LARGER frame
 *       old SS, old ESP, EFLAGS, CS, EIP   (5 words, no error code for INT n)
 *     and runs the handler at CPL0 on the TSS stack,
 *   - inter-privilege IRET: the handler IRETs; because the saved CS has RPL=3 >
 *     CPL=0, IRET additionally pops ESP/SS and switches back to the CPL3 stack,
 *     returning control to CPL3.
 *   - finally CPL3 issues a "syscall"-style INT to a CPL0 routine that performs
 *     the isa-debug-exit (a user task cannot OUT to 0xF4 at CPL3 — it must trap
 *     into CPL0), exercising a second cross-priv delivery that does NOT return.
 *
 * Everything is OBSERVABLE in the system-mode golden:
 *   - CPL transition:  CS.RPL/CPL goes 0 -> 3 (down) and 3 -> 0 (delivery) -> 3
 *     (inter-priv IRET return);
 *   - stack switch:    SS:ESP jumps to the TSS.SS0:ESP0 stack on delivery and
 *     back to the CPL3 stack on IRET;
 *   - the 5-word frame: the handler reads back old SS / old ESP / EFLAGS / CS /
 *     EIP from its CPL0 stack and records them as markers.
 *
 * NO paging in pcpl (linear == physical), so handler/gate offsets are physical.
 * SAME bootstrap shape as pintr/pfault: a flat 64 KiB -bios image, reset vector
 * F000:FFF0, a 16-bit stub at image offset 0xFFF0 jumps to _start16.
 *
 * Memory plan (machine -m 32 => 32 MiB phys):
 *   GDT  @ 0x00000500   null + code0 0x08 + data0 0x10 + code3 0x18(DPL3)
 *                       + data3 0x20(DPL3) + TSS 0x28
 *   IDT  @ 0x00001000   256 gates; only 0x40 (syscall INT) and 0x80 (test INT)
 *                       filled, both DPL=3 so CPL3 may use them, target CS 0x08.
 *   markers @ 0x00002000  (handler-ran sentinels + the captured 5-word frame +
 *                          the CPL/SS proofs the mainline reads back)
 *   TSS  @ 0x00003000   a 104-byte 32-bit TSS; SS0=0x10, ESP0 = the CPL0 INT stack
 *   CPL0 boot/main stack   @ 0x00090000 (descends)
 *   CPL0 interrupt stack   @ 0x00088000 (descends) -- TSS.ESP0; DISTINCT from the
 *                          boot stack so the SS:ESP switch is unambiguous.
 *   CPL3 user stack        @ 0x00080000 (descends)
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pcpl.ld; objcopy -O binary,
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
     * idx1 0x08 code32 flat DPL0  P|DPL0|S|code|R   (access 0x9A, gran 0xCF)
     * idx2 0x10 data32 flat DPL0  P|DPL0|S|data|W   (access 0x92, gran 0xCF)
     * idx3 0x18 code32 flat DPL3  P|DPL3|S|code|R   (access 0xFA, gran 0xCF)
     * idx4 0x20 data32 flat DPL3  P|DPL3|S|data|W   (access 0xF2, gran 0xCF)
     * idx5 0x28 TSS32 (available) base=0x3000 limit=0x67 (104-1) access 0x89
     *      (P|DPL0|type=9 = 32-bit available TSS), gran 0x00.
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18 code3 (DPL3) */
    movl    $0x00CFFA00, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20 data3 (DPL3) */
    movl    $0x00CFF200, 36(%ebx)
    /* idx5 0x28 TSS32 available: base 0x00003000, limit 0x0067, access 0x89 */
    movl    $0x00000067, 40(%ebx)       /* limit[15:0]=0x67, base[15:0]=0x0000 */
    movl    $0x00008900, 44(%ebx)       /* base[23:16]=0, access=0x89, gran=0, base[31:24]=0 ... base[23:16] is 0x00 here, base mid set below */
    /* The TSS descriptor's base is 0x00003000.  Encode base[23:16]=0x00 (already)
     * and base[31:24]=0x00; base[15:0]=0x3000 must go into bytes 2..3 of the desc.
     * Rewrite the low dword to carry base[15:0]=0x3000: limit[15:0]=0x0067,
     * base[15:0]=0x3000 -> low dword = (0x3000<<16)|0x0067 = 0x30000067.        */
    movl    $0x30000067, 40(%ebx)       /* limit=0x0067, base[15:0]=0x3000 */
    /* high dword: base[31:24]=0x00, gran=0x00, limit[19:16]=0x0, access=0x89,
     * base[23:16]=0x00 -> 0x00008900 (already written above). */

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
    movw    $0x10, %ax                  /* flat CPL0 data everywhere */
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp           /* CPL0 boot/main stack */

    /* --- zero the marker area at 0x2000..0x2080 (32 dwords) --- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== build + load the TSS ========================== */
    /* Zero the 104-byte TSS @ 0x3000, then set the fields we use:
     *   SS0 (offset 0x08) = 0x10   (CPL0 flat data)
     *   ESP0(offset 0x04) = 0x00088000 (the dedicated CPL0 interrupt stack top)
     * The other privilege stacks (SS1/SS2) are unused here.  We also leave the
     * I/O map base (offset 0x66) = 0x68 (= TSS limit+1 => empty I/O map => all
     * I/O at CPL>IOPL #GPs; here CPL3 OUT would #GP, which is why CPL3 traps to
     * CPL0 for the exit -- but we never OUT at CPL3, so the empty map is fine). */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx                   /* 26 dwords = 104 bytes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    /* ESP0 @ 0x3004 = 0x00088000 ; SS0 @ 0x3008 = 0x0010 */
    movl    $0x00088000, 0x00003004
    movl    $0x00000010, 0x00003008
    /* I/O map base @ 0x3066 (a 16-bit field) = 0x0068 (>= limit => empty map) */
    movw    $0x0068, 0x00003066

    /* LTR loads TR from GDT selector 0x28 (marks the TSS busy: type 9 -> 0xB). */
    movw    $0x0028, %ax
    ltr     %ax

    /* STR reads it back so the golden shows TR established (selector in AX low). */
    xorl    %eax, %eax
    str     %ax                         /* ax = 0x0028 (proof TR loaded) */
    movl    %eax, 0x00002040            /* marker: STR value */

    /* ===================== build the IDT (2 gates) ====================== */
    /* IDT base 0x1000.  Two 32-bit INTERRUPT gates, target selector 0x08 (CPL0
     * code), but with gate DPL=3 so CPL3 software INT n is permitted:
     *   vector 0x80 -> xcpl_handler  (the test interrupt: cross-priv deliver +
     *                  inter-priv IRET back to CPL3)
     *   vector 0x40 -> sys_exit      (the "syscall" the CPL3 task uses to ask
     *                  CPL0 to perform the isa-debug-exit; does not return)
     * Gate attr 0xEE = P(1) DPL(11=3) 0 type(1110 = 32-bit interrupt gate).   */

    /* vector 0x80 -> xcpl_handler, attr 0xEE */
    movl    $xcpl_handler, %ebx
    movl    $0x00001400, %edi           /* 0x1000 + 0x80*8 = 0x1400 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 in bits 31:16 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x0000EE00, %eax           /* attr 0xEE (32-bit int gate, P, DPL3) */
    movl    %eax, 4(%edi)

    /* vector 0x40 -> sys_exit, attr 0xEE */
    movl    $sys_exit, %ebx
    movl    $0x00001200, %edi           /* 0x1000 + 0x40*8 = 0x1200 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x0000EE00, %eax
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490             /* IDT limit = 256*8-1 */
    movl    $0x00001000, 0x0492        /* IDT base = 0x1000 */
    lidt    0x0490

    /* clear the visible accumulator GPRs so the trace is clean */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %ebp, %ebp

    /* ===================== transfer DOWN to CPL3 ========================= */
    /* Build the inter-privilege IRET frame on the CURRENT (CPL0) stack and IRET
     * to the DPL=3 code segment.  Because the target CS (0x1B = idx3 RPL3) has
     * RPL=3 > CPL=0, IRET pops ESP/SS too, switching to the CPL3 user stack and
     * lowering CPL to 3.  Frame layout pushed (top first popped):
     *   EIP, CS, EFLAGS, ESP, SS
     * We want the CPL3 task to start at user_entry with CS=0x1B, SS=0x23,
     * ESP=0x00080000, EFLAGS with IF set + the reserved bit 1.  Push in reverse:
     *   push SS(0x23), push ESP(0x80000), push EFLAGS, push CS(0x1B), push EIP. */
    pushl   $0x00000023                 /* SS = data3 selector (RPL3) */
    pushl   $0x00080000                 /* ESP = CPL3 user stack top */
    pushfl                              /* EFLAGS (bit1 reserved=1; IF=0 here, cli) */
    orl     $0x00000200, (%esp)         /* set IF in the pushed EFLAGS image */
    pushl   $0x0000001B                 /* CS = code3 selector (RPL3) */
    pushl   $user_entry                 /* EIP */
    iret                                /* -> CPL3 at user_entry, SS:ESP switched */

    /* (CPL0 never falls through to here; sys_exit performs the real exit.) */

    /* ============================ CPL3 USER TASK ========================= */
    /* Runs at CPL 3 with CS=0x1B, SS=0x23.  Loads the user data selectors, then
     * fires INT 0x80 (allowed: gate DPL=3 >= CPL=3).  Delivery switches to the
     * CPL0 handler on the TSS stack; xcpl_handler records the frame + a sentinel
     * and inter-priv IRETs back HERE.  The user task then reads back its own SS
     * (proving it is on the CPL3 stack with RPL3) and finally INT 0x40 to ask
     * CPL0 to perform the isa-debug-exit. */
    .align 16
    .global user_entry
user_entry:
    /* reload DS/ES with the CPL3 data selector (0x23) so user data accesses are
     * well-defined at CPL3.  (SS already = 0x23 from the IRET.) */
    movw    $0x0023, %ax
    movw    %ax, %ds
    movw    %ax, %es

    /* record a CPL3-reached sentinel + the current SS (read via mov from seg).
     * markers are in the flat data region; at CPL3 the flat data segment maps
     * the same linear addresses (base 0, limit 4G), so the writes land at the
     * same physical marker slots the CPL0 code reads back. */
    movl    $0xC3C3C3C3, 0x00002044     /* "CPL3 reached" sentinel */
    xorl    %eax, %eax
    movw    %ss, %ax
    movl    %eax, 0x00002048            /* user SS (expect 0x0023 = data3 RPL3) */
    xorl    %eax, %eax
    movw    %cs, %ax
    movl    %eax, 0x0000204C            /* user CS (expect 0x001B = code3 RPL3) */

    /* clear a couple GPRs the handler will set as a round-trip proof */
    xorl    %esi, %esi
    xorl    %edi, %edi

    /* ---- the cross-privilege INT (the heart of the test) ---- */
    int     $0x80                       /* CPL3 -> gate DPL3 -> CPL0 handler */
    /* after the inter-priv IRET we are HERE, back at CPL3.  Prove the handler
     * ran by reading its sentinel; load it into ESI as a visible accumulator. */
    movl    0x00002050, %esi            /* esi = 0x80808080 (xcpl_handler ran) */

    /* record that control RETURNED to CPL3 after the inter-priv IRET */
    movl    $0x33333333, 0x00002054     /* "returned to CPL3" sentinel */

    /* ---- syscall-style exit: trap to CPL0 to perform isa-debug-exit ---- */
    int     $0x40                       /* CPL3 -> gate DPL3 -> sys_exit (CPL0) */

    /* sys_exit does not return; but guard with a hang just in case. */
uhang:
    jmp     uhang

    /* ============================== HANDLERS ============================= */

    /* xcpl_handler — the CROSS-PRIVILEGE interrupt handler.  Reached at CPL0 via
     * INT 0x80 from CPL3 through a DPL=3 interrupt gate whose target CS is DPL=0.
     * Because target CS.DPL (0) < CPL (3), the CPU switched to TSS.SS0:ESP0 and
     * pushed the LARGER 5-word frame.  Stack on entry (no error code for INT n):
     *   [esp+ 0] = saved EIP   (return address in the CPL3 task)
     *   [esp+ 4] = saved CS    (0x001B, RPL3)
     *   [esp+ 8] = saved EFLAGS
     *   [esp+12] = saved ESP   (the CPL3 ESP at the INT)
     *   [esp+16] = saved SS    (0x0023, RPL3)
     * The handler records the whole frame + the SS:ESP it is RUNNING on (proving
     * the switch to the TSS.ESP0 stack), sets a sentinel, then inter-priv IRETs.
     * It saves/restores EAX so the CPL3 accumulators stay meaningful.            */
    .align 16
    .global xcpl_handler
xcpl_handler:
    pushl   %eax                        /* save EAX; frame fields now shift +4 */

    /* sentinel: this handler ran */
    movl    $0x80808080, %eax
    movl    %eax, 0x00002050

    /* capture the running SS:ESP (proof we are on the TSS CPL0 stack, ~0x88000).
     * record ESP first (value just after the push, i.e. handler-entry ESP-4). */
    movl    %esp, %eax
    movl    %eax, 0x00002058            /* handler ESP (in the 0x00088000 region) */
    xorl    %eax, %eax
    movw    %ss, %ax
    movl    %eax, 0x0000205C            /* handler SS (expect 0x0010 = data0, CPL0) */

    /* capture the pushed 5-word inter-priv frame (offsets +4 after the push) */
    movl    0x04(%esp), %eax            /* saved EIP */
    movl    %eax, 0x00002060
    movl    0x08(%esp), %eax            /* saved CS  (expect 0x0000001B) */
    movl    %eax, 0x00002064
    movl    0x0C(%esp), %eax            /* saved EFLAGS */
    movl    %eax, 0x00002068
    movl    0x10(%esp), %eax            /* saved ESP (the CPL3 ESP) */
    movl    %eax, 0x0000206C
    movl    0x14(%esp), %eax            /* saved SS  (expect 0x00000023) */
    movl    %eax, 0x00002070

    /* count this delivery */
    incl    0x00002074                  /* xcpl delivery counter */

    popl    %eax                        /* restore EAX */
    iret                                /* INTER-PRIV IRET: pops EIP/CS/EFLAGS and
                                         * (RPL=3 > CPL=0) also ESP/SS -> CPL3. */

    /* sys_exit — the CPL0 "syscall" the CPL3 task traps into to perform the
     * isa-debug-exit (a CPL3 task cannot OUT to 0xF4).  Reached cross-priv via
     * INT 0x40 (gate DPL3, target CS DPL0).  Does NOT return: it accumulates the
     * success proof into the GPRs and OUTs to 0xF4 at CPL0.
     *
     * On entry the CPU has already switched to the TSS CPL0 stack and pushed the
     * 5-word frame.  We do NOT IRET; we just verify + exit.                      */
    .align 16
    .global sys_exit
sys_exit:
    /* success proof in the GPRs (deterministic function of "everything ran"):
     *   ECX = xcpl delivery counter (must be 1)
     *   EDX = captured handler SS  (must be 0x10 = CPL0 data, proving stack switch)
     *   EBX = captured saved CS    (must be 0x1B = CPL3 code RPL3, proving the
     *                               cross-priv frame held the CPL3 return CS)
     *   ESI = xcpl sentinel        (0x80808080)
     *   EDI = "returned to CPL3" sentinel (0x33333333) -- set by the CPL3 task
     *         AFTER the inter-priv IRET, so reaching here at all proves the
     *         IRET returned to CPL3 and the task continued.                      */
    movl    0x00002074, %ecx            /* delivery counter (=1) */
    movl    0x0000205C, %edx            /* handler SS (=0x10) */
    movl    0x00002064, %ebx            /* saved CS in frame (=0x1B) */
    movl    0x00002050, %esi            /* xcpl sentinel (=0x80808080) */
    movl    0x00002054, %edi            /* returned-to-CPL3 sentinel (=0x33333333) */

    /* isa-debug-exit at CPL0: out 0xf4, 0x42 -> qemu status (0x42<<1)|1 = 0x85. */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx

hang:
    hlt
    jmp     hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off                /* 16-bit offset within segment 0xF000 */
    .word   0xF000                      /* segment */
