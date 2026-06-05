/* Ventium M7.2 — bare-metal VIRTUAL-8086 MODE (V86) demonstrator.
 *
 * This is the M7.2 pv86 gate test: it bootstraps real->protected + PAGING + a TSS
 * (reusing the M2S.2 ppage paging bootstrap + the M2S.4 pcpl TSS/cross-priv stack
 * switch), then ENTERS virtual-8086 mode by building a 9-word V86 IRET frame with
 * EFLAGS.VM=1 and IRET-ing into a 16-bit V86 task at CS:EIP=0x1000:0000.  The V86
 * task runs sel<<4 (real-mode-style) segmentation at CPL3 and executes the
 * IOPL-sensitive instructions (CLI/STI/PUSHF/POPF/INT n) which, because IOPL<3,
 * each raise #GP(0) and trap to the CPL0 monitor — the IA-32 SDM Vol.3 "method 1 /
 * VME-OFF" subset (VME/VIF/VIP + the interrupt-redirection bitmap are OUT of scope;
 * method-1 routes every IOPL-sensitive op through the monitor, which is
 * architecturally correct).  The monitor decodes the faulting V86 opcode, records
 * the event, emulates/advances it, and IRETs back into V86.  After the V86 task
 * finishes its IOPL-sensitive sequence it issues a sentinel INT that the monitor
 * recognises as "done" and performs the isa-debug-exit.
 *
 * What the system-mode golden CAPTURES (the V86 contract):
 *   - V86 ENTRY: EFLAGS.VM 0->1, CS:EIP jumps into the V86 task (CS=0x1000), CPL
 *     forced to 3, paging still live (PE=1/PG=1).
 *   - V86 SEGMENTATION: the V86 task's data accesses use sel<<4 bases (DS=0x2000 ->
 *     linear 0x20000) with NO GDT descriptor read.
 *   - IOPL-SENSITIVE #GP: each CLI/STI/PUSHF/POPF/INT n at IOPL<3 -> #GP(0) -> the
 *     CPL0 monitor; the 9-word V86 frame (GS,FS,DS,ES,SS,ESP,EFLAGS,CS,EIP) is
 *     pushed on the TSS.SS0:ESP0 stack, EFLAGS.VM is CLEARED on entry (the
 *     monitor runs in flat protected mode), and DS/ES/FS/GS are zeroed on entry.
 *   - RETURN: the monitor IRETs the (possibly EIP-advanced) V86 frame back to the
 *     V86 task (EFLAGS.VM 0->1 again), control resumes in V86.
 *
 * Freestanding "BIOS" image: qemu-system-i386 -bios pv86.bin .  Reset vector
 * CS:EIP=F000:FFF0; a 16-bit reset stub at image offset 0xFFF0 jumps to _start16.
 *
 * Physical/linear memory plan (machine -m 32 => 32 MiB phys; targets fit):
 *   GDT  @ 0x00000500  (null + code0 0x08 + data0 0x10 + TSS32 0x28 base 0x3000)
 *   IDT  @ 0x00001000  (256 gates; only #GP vector 13 filled, interrupt gate DPL0)
 *   markers @ 0x00002000 (per-event log + counters the monitor writes; the V86
 *                         task's own sentinels go to its DS window 0x20000)
 *   TSS  @ 0x00003000  (104-byte 32-bit TSS; SS0=0x10, ESP0=0x00088000 monitor stk)
 *   V86 task @ 0x00010000 (segment 0x1000; the task code copied here from the image)
 *   V86 data @ 0x00020000 (segment 0x2000; the task's DS scratch + sentinels)
 *   V86 stack @ 0x0002F000 (segment 0x2000, SP=0xF000; the task's SS:SP)
 *   Page tables (built BEFORE CR0.PG):
 *     PD  @ 0x00011000 : PD[0]->PT0 (identity low 4 MiB)
 *     PT0 @ 0x00012000 : identity-map [0,0x40000) (V86 task/data/stack + low
 *                        structures + page tables) + the code window [0xF0000,
 *                        0x100000) so EIP stays valid across CR0.PG and the V86
 *                        entry, and the V86 sel<<4 linear addresses are mapped.
 *   monitor boot stack @ 0x00090000 ; monitor interrupt (CPL0) stack @ 0x00088000.
 *
 * Flow:
 *   1. real mode: flat GDT (+ TSS desc) + lgdt; CR0.PE=1; far-jump to 0x08.
 *   2. flat data selectors + boot stack; zero markers; build IDT (#GP) + lidt;
 *      build TSS (SS0:ESP0) + LTR; copy the V86 task blob down to 0x10000.
 *   3. build PD + PT0 (identity low + code window); CR3; CR0.PG.
 *   4. ENTER V86: build the 9-word V86 IRET frame (GS=FS=DS=ES=0, SS=0x2000,
 *      ESP=0xF000, EFLAGS=VM(bit17)|reserved(bit1), CS=0x1000, EIP=0) and IRET.
 *   5. the V86 task runs: write a sentinel via DS=0x2000; then CLI / STI / PUSHF /
 *      POPF / INT 0x21 (each #GPs to the monitor at IOPL<3); write a done sentinel;
 *      INT 0x20 (the "terminate" sentinel the monitor turns into isa-debug-exit).
 *   6. the monitor #GP handler decodes the faulting V86 opcode, logs it, advances
 *      EIP past it (and for INT n records the vector), IRETs back to V86 — except
 *      INT 0x20 which exits via isa-debug-exit (out 0xf4, 0x42 -> qemu status 133).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,pv86.ld; objcopy -O binary,
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
     * idx1 0x08 code32 flat DPL0  (access 0x9A, gran 0xCF)
     * idx2 0x10 data32 flat DPL0  (access 0x92, gran 0xCF)
     * idx3 0x18 data32 flat clone (unused; keeps the limit comfortable)
     * idx4 0x20 data32 flat clone (unused)
     * idx5 0x28 TSS32 available   base=0x00003000 limit=0x67 access 0x89
     */
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
    /* idx5 0x28 TSS32 available: base 0x00003000, limit 0x0067, access 0x89 */
    movl    $0x30000067, 40(%ebx)       /* limit[15:0]=0x67, base[15:0]=0x3000 */
    movl    $0x00008900, 44(%ebx)       /* base[23:16]=0, access=0x89, gran=0, base[31:24]=0 */

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
    movl    $0x00090000, %esp           /* monitor boot/main stack */

    /* --- zero the marker area at 0x2000..0x2080 (32 dwords) --- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ===================== build + load the TSS ========================== */
    /* 104-byte 32-bit TSS @ 0x3000.  SS0=0x10, ESP0=0x00088000 (the CPL0 monitor
     * stack the #GP-from-V86 delivery switches to).  I/O map base = 0x68 (empty
     * map => any V86 IN/OUT also #GPs, consistent with method-1).               */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx                   /* 26 dwords = 104 bytes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00088000, 0x00003004     /* ESP0 */
    movl    $0x00000010, 0x00003008     /* SS0 = data0 */
    movw    $0x0068, 0x00003066         /* I/O map base (>= limit => empty map) */

    movw    $0x0028, %ax
    ltr     %ax                         /* TR <- TSS selector 0x28 */

    /* ===================== build the IDT (#GP gate) ====================== */
    /* IDT base 0x1000.  Vector 13 (#GP) -> gp_handler.  32-bit INTERRUPT gate
     * (attr 0x8E: P=1 DPL=0 type=E), target selector 0x08 (CPL0 code).  The V86
     * IOPL faults are delivered through this gate to the CPL0 monitor.          */
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 = 0x1068 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 in bits 31:16 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* attr 0x8E (32-bit interrupt gate, P, DPL0) */
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490             /* IDT limit = 256*8-1 */
    movl    $0x00001000, 0x0492        /* IDT base = 0x1000 */
    lidt    0x0490

    /* ============ copy the V86 task blob down to linear 0x10000 ========== */
    /* The V86 task body (.text_v86) is assembled at run-VMA 0x00010000 but its
     * bytes live high in the BIOS image (LMA _v86_lma).  memcpy _v86_blob_len
     * bytes from the image-resident source to 0x00010000 so the V86 task runs
     * with CS=0x1000 / offset 0.  We compute the image source linear address as
     * the LMA (_v86_lma is a full 0x000Fxxxx linear address from the linker).    */
    movl    $_v86_lma, %esi             /* source: image-resident blob (high) */
    movl    $0x00010000, %edi           /* dest:   V86 task run window */
    movl    $_v86_blob_len, %ecx
    addl    $3, %ecx
    shrl    $2, %ecx                    /* dword count (ceil) */
1:  movl    (%esi), %eax
    movl    %eax, (%edi)
    addl    $4, %esi
    addl    $4, %edi
    loop    1b

    /* ===================== build the 2-level page tables ================= */
    /* PT0 @ 0x12000: identity-map [0,0x40000) (64 PTEs) — covers the V86 task
     * (0x10000), the V86 data/stack windows (0x20000/0x2F000), the low structures
     * (GDT/IDT/markers/TSS/page-tables), and the monitor stacks (0x88000/0x90000
     * are above 0x40000, so map those too).  We map [0,0x40000) AND [0x80000,
     * 0x91000) AND the code window [0xF0000,0x100000).                          */
    /* Every PTE/PDE sets U/S=1 (bit2 = 0x4) as well as P|RW (0x3) => 0x7.  V86
     * mode runs at CPL3 (USER), so the V86 task's code/data/stack pages MUST grant
     * user access (U/S=1 in both the PDE and the PTE) or the fetch/data access
     * #PFs with a U/S protection violation.  Supervisor (the CPL0 monitor) can
     * access user pages too, so 0x7 is correct for the whole identity map.        */
    /* [0,0x40000): 64 PTEs identity */
    movl    $0x00012000, %edi           /* &PT0[0] */
    movl    $0x00000007, %eax           /* frame 0 | P|RW|US */
    movl    $64, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    /* [0x80000,0x91000): 17 PTEs (monitor stacks 0x88000/0x90000) */
    movl    $0x00012200, %edi           /* &PT0[0x80] = 0x12000 + 0x80*4 */
    movl    $0x00080007, %eax           /* frame 0x80000 | P|RW|US */
    movl    $17, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    /* code window [0xF0000,0x100000): 16 PTEs */
    movl    $0x000123C0, %edi           /* &PT0[0xF0] = 0x12000 + 0xF0*4 */
    movl    $0x000F0007, %eax           /* frame 0xF0000 | P|RW|US */
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b

    /* PD @ 0x11000: PD[0]->PT0 (identity low 4 MiB).  Only PD[0] is needed since
     * every linear we touch is < 4 MiB.  U/S=1 so the CPL3 V86 task can walk it. */
    movl    $0x00011000, %edi
    movl    $0x00012007, 0(%edi)        /* PD[0] -> PT0 | P|RW|US */

    /* enable paging */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* clear the visible accumulator GPRs */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %ebp, %ebp

    /* ===================== ENTER VIRTUAL-8086 MODE ====================== */
    /* Build the 9-word V86 IRET frame on the current (CPL0) stack and IRET into
     * the V86 task.  When EFLAGS.VM (bit17) is set in the popped EFLAGS, IRET
     * enters V86: it pops EIP, CS, EFLAGS, ESP, SS, ES, DS, FS, GS (the extra four
     * data selectors are the V86-frame additions) and sets CPL=3.  Frame pushed
     * (in reverse pop order, so the FIRST push is GS, the LAST is EIP):
     *   GS, FS, DS, ES, SS, ESP, EFLAGS, CS, EIP
     * V86 register choices:
     *   CS=0x1000 EIP=0x0000  (the V86 task at linear 0x10000)
     *   SS=0x2000 ESP=0xF000  (the V86 stack at linear 0x2F000, descends)
     *   DS=ES=0x2000          (the V86 data window at linear 0x20000)
     *   FS=GS=0x0000
     *   EFLAGS = VM(bit17) | reserved(bit1).  IOPL stays 0 (bits13:12=00) so the
     *            IOPL-sensitive ops in the V86 task all #GP to the monitor.      */
    pushl   $0x00000000                 /* GS = 0x0000 */
    pushl   $0x00000000                 /* FS = 0x0000 */
    pushl   $0x00002000                 /* DS = 0x2000 */
    pushl   $0x00002000                 /* ES = 0x2000 */
    pushl   $0x00002000                 /* SS = 0x2000 */
    pushl   $0x0000F000                 /* ESP = 0xF000 */
    pushl   $0x00020002                 /* EFLAGS: VM(bit17=0x20000) | bit1 ... */
    /* NOTE: the EFLAGS image above must have bit17 (VM) set; 0x20002 = VM | bit1.
     * IF is intentionally LEFT CLEAR (the V86 task will try to STI -> #GP).      */
    pushl   $0x00001000                 /* CS = 0x1000 (V86 task segment) */
    pushl   $0x00000000                 /* EIP = 0x0000 */
    iret                                /* -> V86 mode at 0x1000:0000, CPL3 */

    /* (the monitor never falls through to here; the V86 task's INT 0x20 -> the
     * gp_handler's terminate path performs the isa-debug-exit.) */
mhang:
    hlt
    jmp     mhang

    /* ============================ #GP HANDLER (MONITOR) ================== */
    /* gp_handler — the V86 MONITOR.  Reached at CPL0 via #GP(0) raised by an
     * IOPL-sensitive instruction in the V86 task (IOPL<3, method-1).  Because the
     * fault is delivered FROM V86 (CPL3) TO a CPL0 handler, the CPU switched to
     * TSS.SS0:ESP0 and pushed the 9-word V86 frame, and CLEARED EFLAGS.VM on entry
     * (so the monitor runs in flat 32-bit protected mode) + zeroed DS/ES/FS/GS.
     * Stack on entry (a #GP DOES push an error code, 0 for these IOPL faults):
     *   [esp+ 0] = error code (0)
     *   [esp+ 4] = EIP   (the faulting V86 offset)
     *   [esp+ 8] = CS    (the V86 code selector, 0x00001000)
     *   [esp+12] = EFLAGS (the V86 EFLAGS, VM still set in the SAVED image)
     *   [esp+16] = ESP   (the V86 SP)
     *   [esp+20] = SS    (the V86 SS, 0x00002000)
     *   [esp+24] = ES    (the V86 ES)
     *   [esp+28] = DS    (the V86 DS)
     *   [esp+32] = FS
     *   [esp+36] = GS
     * The monitor must NOT pop the error code with a bare IRET — IRET from a CPL0
     * handler back to a V86 (VM=1 in the saved EFLAGS) frame pops all 9 words, so
     * we `add $4,%esp` to discard the error code first, leaving a clean 9-word V86
     * frame for IRET to consume.
     *
     * Decode: read the faulting V86 opcode at linear (CS<<4)+EIP.  CS=0x1000 so the
     * linear address is 0x10000+EIP; the identity page table maps it, and the
     * monitor's reloaded flat DS (base 0) addresses it directly.  Opcodes handled:
     *   0xFA CLI, 0xFB STI : record + advance EIP by 1 (1-byte, no operand).
     *   0x9C PUSHF, 0x9D POPF : record + advance EIP by 1.
     *   0xCD INT n : record the vector (next byte); if n==0x20 TERMINATE (exit);
     *                else advance EIP by 2 (skip the INT, method-1 stub redirect).
     * Everything is logged into the marker area so the golden + the success proof
     * can confirm each event delivered.                                          */
    .align 16
    .global gp_handler
gp_handler:
    pushl   %eax
    pushl   %ebx
    pushl   %ecx
    pushl   %edx
    /* after 4 pushes, the V86 frame shifts +16:
     *   [esp+16]=errcode [esp+20]=EIP [esp+24]=CS [esp+28]=EFLAGS [esp+32]=ESP
     *   [esp+36]=SS [esp+40]=ES [esp+44]=DS [esp+48]=FS [esp+52]=GS               */

    /* V86->PM delivery ZEROED DS/ES/FS/GS (IA-32) — reload a flat CPL0 data
     * selector so the monitor's absolute-addressed marker accesses + the opcode
     * fetch through DS are well-defined (SS was loaded from TSS.SS0=0x10 already). */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es

    incl    0x00002000                  /* total #GP-from-V86 delivery count */

    /* fetch the faulting V86 opcode: linear = (CS<<4)+EIP.  CS at [esp+24], EIP at
     * [esp+20].  We only need the low 16 bits of CS/EIP. */
    movl    0x18(%esp), %eax            /* CS (V86 code selector) */
    andl    $0x0000FFFF, %eax
    shll    $4, %eax                    /* CS<<4 (segment base) */
    movl    0x14(%esp), %ebx            /* EIP (V86 offset) */
    andl    $0x0000FFFF, %ebx
    addl    %ebx, %eax                  /* eax = linear of the faulting opcode */
    movl    %eax, %edx                  /* keep the linear in edx */
    movzbl  (%eax), %ecx                /* ecx = the faulting opcode byte */

    /* record the opcode into a small ring at 0x2040 (indexed by the delivery
     * count, capped) so the golden shows WHICH ops trapped, in order. */
    movl    0x00002000, %ebx            /* delivery index (1-based) */
    decl    %ebx
    andl    $0x0000000F, %ebx           /* cap to 16 slots */
    shll    $2, %ebx
    addl    $0x00002040, %ebx
    movl    %ecx, (%ebx)                /* opcode log[i] = opcode */

    /* dispatch on the opcode */
    cmpl    $0xCD, %ecx
    je      gp_int_n                    /* 0xCD = INT n */
    cmpl    $0xFA, %ecx
    je      gp_one_byte                 /* 0xFA = CLI */
    cmpl    $0xFB, %ecx
    je      gp_one_byte_sti             /* 0xFB = STI */
    cmpl    $0x9C, %ecx
    je      gp_one_byte_pushf           /* 0x9C = PUSHF */
    cmpl    $0x9D, %ecx
    je      gp_one_byte_popf            /* 0x9D = POPF */
    /* unknown IOPL-sensitive opcode: count it + advance 1 byte (defensive). */
    jmp     gp_one_byte

gp_one_byte_sti:
    incl    0x00002008                  /* STI count */
    jmp     gp_one_byte
gp_one_byte_pushf:
    incl    0x0000200C                  /* PUSHF count */
    jmp     gp_one_byte
gp_one_byte_popf:
    incl    0x00002010                  /* POPF count */
    jmp     gp_one_byte

gp_one_byte:
    /* CLI (0xFA) falls in here directly; the STI/PUSHF/POPF labels jumped here
     * after bumping their own counters.  Bump the CLI counter ONLY for 0xFA.   */
    cmpl    $0xFA, %ecx
    jne     1f
    incl    0x00002004                  /* CLI count */
1:
    /* advance the saved V86 EIP past the 1-byte instruction */
    incl    0x14(%esp)                  /* EIP += 1 */
    jmp     gp_return

gp_int_n:
    /* INT n: the vector is the byte AFTER the 0xCD at linear edx+1. */
    incl    0x00002014                  /* INT n count */
    movzbl  1(%edx), %ecx               /* ecx = the INT vector */
    movl    %ecx, 0x00002018            /* record the most-recent INT vector */
    /* INT 0x20 is the TERMINATE sentinel -> perform the isa-debug-exit. */
    cmpl    $0x20, %ecx
    je      gp_terminate
    /* otherwise record + advance EIP past the 2-byte INT n (method-1 redirect). */
    addl    $2, 0x14(%esp)              /* EIP += 2 */
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
     * into the visible GPRs (a deterministic function of "every event delivered")
     * and perform the isa-debug-exit at CPL0.
     *   ECX = total #GP-from-V86 deliveries (0x2000) = 6 (CLI/STI/PUSHF/POPF +
     *         INT 0x21 + INT 0x20)
     *   EAX = CLI count (0x2004) = 1
     *   EBX = (STI<<0)|(PUSHF<<8)|(POPF<<16)|(INTn<<24) packed counts
     *   EDX = the last INT vector recorded (0x2018) = 0x20 (this terminate INT)
     *   ESI = the V86 task's "entered" sentinel at linear 0x20000 (=0xCAFEBABE;
     *         proves the task actually ran in V86 with DS<<4 segmentation BEFORE
     *         any IOPL trap, i.e. the V86 entry + V86 segmentation both worked).  */
    movl    0x00002000, %ecx            /* total deliveries (=6) */
    movl    0x00002004, %eax            /* CLI count (=1) */
    movl    0x00002008, %ebx            /* STI count */
    movl    0x0000200C, %edx
    shll    $8, %edx
    orl     %edx, %ebx                  /* | PUSHF<<8 */
    movl    0x00002010, %edx
    shll    $16, %edx
    orl     %edx, %ebx                  /* | POPF<<16 */
    movl    0x00002014, %edx
    shll    $24, %edx
    orl     %edx, %ebx                  /* | INTn<<24 */
    movl    0x00002018, %edx            /* last INT vector (=0x20) */
    movl    0x00020000, %esi            /* the V86 task's "entered" sentinel (0xCAFEBABE) */

    movl    $0x42, %eax                 /* isa-debug-exit code */
    /* NOTE: eax is clobbered by the exit code; the accumulators above are for the
     * record(s) PRECEDING this final out.  The golden's success proof reads them
     * at the gp_terminate body, before the exit. */
    movw    $0xF4, %dx
    outb    %al, %dx

ehang:
    hlt
    jmp     ehang

    /* ============================ V86 TASK BODY ========================= */
    /* Assembled as 16-bit code at run-VMA 0x00010000 (segment 0x1000, offset 0).
     * Runs at CPL3 in V86 mode with sel<<4 segmentation: DS=ES=0x2000 (linear
     * 0x20000), SS=0x2000 (stack at 0x2F000), CS=0x1000.  Each IOPL-sensitive
     * instruction below #GPs to the CPL0 monitor (IOPL=0 < 3); the monitor logs +
     * advances it and IRETs back here.  The task is deliberately short + linear so
     * the single-stepped golden is small.                                        */
    .code16
    .section .text_v86, "ax"
    .global v86_entry
v86_entry:
    /* stamp a "V86 entered" sentinel via DS=0x2000 -> linear 0x20000.  This write
     * uses V86 sel<<4 segmentation (no GDT read) and runs BEFORE any IOPL fault,
     * proving the task executes in V86 with the data segment base = DS<<4.  In
     * 16-bit (.code16) code, `movl $imm32, %eax` auto-emits the 0x66 operand-size
     * prefix; `addr32 movl %eax, (addr)` writes the dword.  We use DS-relative
     * stores (offset 0 in segment 0x2000) so the linear target is DS<<4 + off.   */
    movw    $0x2000, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movl    $0xCAFEBABE, %eax           /* the "V86 entered" sentinel value */
    movl    %eax, %ds:0x0000            /* store to linear 0x20000 (DS<<4 + 0) */
v86_after_sentinel:
    /* the IOPL-sensitive sequence — each #GPs to the monitor */
    cli                                 /* 0xFA -> #GP */
    sti                                 /* 0xFB -> #GP */
    pushf                               /* 0x9C -> #GP */
    popf                                /* 0x9D -> #GP */
    int     $0x21                       /* 0xCD 0x21 -> #GP (record vector 0x21) */
    /* signal completion + terminate */
    int     $0x20                       /* 0xCD 0x20 -> #GP -> monitor exits */
v86_hang:
    jmp     v86_hang

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off                /* 16-bit offset within segment 0xF000 */
    .word   0xF000                      /* segment */
