/* Ventium M2S.5 — bare-metal SMM / RSM demonstrator (PARTIAL-ORACLE stage).
 *
 * SMM mechanism: SMI# -> the CPU saves its state to the SMRAM save-state map at
 * SMBASE+0xFE00 (P5 layout), enters SMM (CR0 PE/PG/EM/TS cleared, real-mode-like
 * CS base = SMBASE, EIP = 0x8000, large segment limits), runs the SMM handler,
 * and RSM (0F AA) restores the full saved state and resumes the interrupted
 * context.  Default SMBASE = 0x30000, so the SMM entry point is at SMBASE+0x8000
 * = 0x38000 and the save map at SMBASE+0xFE00 = 0x3FE00.
 *
 * ============================ ORACLE-FEASIBILITY NOTE ========================
 * This stage is a *documented partial oracle*.  The differential golden trace
 * (gen_trace.py --system) is built on the qemu-system-i386 GDB-stub SINGLE-STEP
 * ('s') path, and that path CANNOT observe SMM:
 *
 *   1. SMI is masked during single-step.  QEMU's gdbstub single-steps with
 *      sstep_flags = SSTEP_ENABLE | SSTEP_NOIRQ | SSTEP_NOTIMER (gdbstub.c).
 *      In cpu_handle_interrupt() (accel/tcg/cpu-exec.c), SSTEP_NOIRQ masks out
 *      CPU_INTERRUPT_SSTEP_MASK, and CPU_INTERRUPT_SMI == CPU_INTERRUPT_TGT_EXT_2
 *      IS in that mask.  So SMI# is never delivered between gdb 's' steps.
 *   2. The gdbstub has no SMM awareness (target/i386/gdbstub.c never references
 *      HF_SMM); the g-packet carries no SMM-active flag (it is HMP-only, per
 *      m2s0-system-spec / M2S.0).
 *   3. The save-state map QEMU writes is the P6/SDM-34.4 layout (CR0 @ SMBASE+
 *      0xFFFC, EIP @ +0xFFF0, ...), NOT the Pentium (P5) SMBASE+0xFE00 layout
 *      this RTL stage targets, so even a captured save area would not be byte-
 *      comparable to a P5-faithful RTL.
 *
 * VERIFIED FACTS (see verif/sys/tests/psmm/README.md for the full de-risk):
 *   - FREE-RUNNING (no gdb), an APIC self-IPI with SMI delivery mode DOES fire
 *     SMI deterministically under this qemu-system-i386: the SMM handler runs
 *     (writes its sentinel) and RSM resumes the mainline.  QEMU's APIC honours
 *     APIC_DM_SMI (hw/intc/apic.c -> cpu_interrupt(CPU_INTERRUPT_SMI)).
 *   - A write to the ACPI/APM SMI command port 0xB2 does NOT fire SMI on a raw
 *     -bios image: the PIIX4 APMC->SMI gate (config 0x5b bit 1) is programmed
 *     only by firmware (SeaBIOS), which this image replaces.
 *
 * Therefore: there is NO fabricated psmm.sys.vtrace.golden.  This image is the
 * STRUCTURAL self-check artifact: it is run FREE (verif/sys/run-sys-golden.sh
 * psmm) and the SMM round-trip is proven by reading the post-run physical
 * memory (the handler sentinel + the mainline resume sentinel + the QEMU save
 * area) via QMP.  The RTL --system differential is DEFERRED to the RTL phase,
 * which self-checks the P5 save-map + SMI-entry/RSM mechanism with an RTL-only
 * assertion test (the SMI source is asserted directly in the TB, bypassing the
 * un-traceable gdbstub path).
 * ============================================================================
 *
 * Memory plan (machine -m 32 => 32 MiB phys; NO paging, linear == physical):
 *   GDT       @ linear 0x00000500  (null + code32 0x08 + data32 0x10)
 *   sentinels @ linear 0x00002000  (SMM-ran / resume / state-intact records)
 *   SMBASE    @ 0x00030000 (default); SMM entry 0x00038000; save map 0x0003FE00
 *   APIC MMIO @ 0xFEE00000 (local APIC; SVR @+0xF0, ICR-low @+0x300)
 *   stack     @ 0x00090000 (flat 32-bit)
 *
 * Flow:
 *   1. real mode: build flat GDT + lgdt; CR0.PE=1; far-jump to 32-bit code 0x08.
 *   2. load flat data selectors (0x10) + a flat stack; zero the sentinel area.
 *   3. install the SMM handler bytes at SMBASE+0x8000 (0x38000).
 *   4. enable the local APIC (SVR bit 8) and fire a self-IPI with delivery mode
 *      = SMI (ICR-low = 0x00040200: dest-shorthand=self | delivery-mode=SMI).
 *   5. SMI# -> (free-run) state saved to SMRAM -> SMM handler runs: writes the
 *      'SMM ran' sentinel (0x5A4D5A4D) to linear 0x2000 + RSM (0F AA).
 *   6. RSM resumes the mainline AFTER the ICR write; the mainline records the
 *      'resume' sentinel (0x52455421 'RET!') at 0x2004 and a 'state-intact'
 *      sentinel at 0x2008 (a marker GPR carried across the SMI is read back).
 *   7. exit via isa-debug-exit (out 0xf4, 0x42 -> qemu status 133).
 *
 * Build: gcc -m32 -ffreestanding -nostdlib -Wl,-T,psmm.ld (see Makefile), then
 * objcopy -O binary, padded to exactly 64 KiB.  GNU-as syntax; no nasm.
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

    /* --- build a flat GDT (3 entries = 24 bytes) at linear 0x0500 --- */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx 0: null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx 1 (0x08): code32 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx 2 (0x10): data32 flat */
    movl    $0x00CF9200, 20(%ebx)
    movw    $0x0017, 0x0480             /* gdt pseudo-desc: limit 24-1 */
    movl    $0x00000500, 0x0482         /* base 0x0500 */
    lgdt    0x0480

    /* --- enter protected mode (PE; PG stays 0) --- */
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
    movl    $0x00090000, %esp

    /* --- zero the sentinel area (3 dwords) at 0x2000..0x200B --- */
    movl    $0, 0x00002000             /* [0] SMM-ran sentinel    */
    movl    $0, 0x00002004             /* [1] mainline-resume     */
    movl    $0, 0x00002008             /* [2] state-intact proof  */

    /* === install the SMM handler at SMBASE(0x30000)+0x8000 = 0x38000 === */
    movl    $smm_handler, %esi
    movl    $0x00038000, %edi
    movl    $smm_handler_end - smm_handler, %ecx
    rep movsb

    /* === enable the local APIC via SVR (APIC base 0xFEE00000, SVR @+0xF0) === */
    movl    $0xFEE000F0, %edi
    movl    (%edi), %eax
    orl     $0x100, %eax               /* APIC software-enable (bit 8) */
    movl    %eax, (%edi)

    /* a unique marker carried across the SMI in EBX so the mainline can prove
     * RSM restored the interrupted GPR state intact. */
    movl    $0x5A4D900D, %ebx          /* 'state-intact' witness GPR */

    /* === fire a self-IPI, delivery mode = SMI (free-run -> SMI#) ===
     * ICR-low @ 0xFEE00300:
     *   delivery mode[10:8] = 0b010 (SMI)        -> 0x00000200
     *   dest shorthand[19:18] = 0b01 (self)      -> 0x00040000
     */
    movl    $0xFEE00300, %edi
    movl    $0x00040200, %eax
    movl    %eax, (%edi)               /* dispatch -> SMI# (free-run) */

    /* spin so the SMI (delivered between TBs free-running) has room to fire */
    movl    $4096, %ecx
1:  pause
    loop    1b

    /* === post-SMI: record resume + state-intact sentinels === */
    movl    $0x52455421, 0x00002004    /* 'RET!' proof mainline resumed after RSM */
    movl    %ebx, 0x00002008           /* must read back 0x5A4D900D if RSM intact */

    /* === clean exit via isa-debug-exit === */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx                   /* qemu status = (0x42<<1)|1 = 133 */
hang:
    hlt
    jmp     hang

    /* ============================ SMM HANDLER ============================
     * Runs in the SMM real-mode-like context (16-bit default, CS base=SMBASE,
     * DS base=0).  Hand-encoded so the operand/address-size overrides are exact:
     *   mov eax, 0x5A4D5A4D : 66 B8 4D 5A 4D 5A      (opsize32 + imm32)
     *   mov [0x2000], eax   : 67 66 A3 00 20 00 00   (addr32 + opsize32 + moffs)
     *   rsm                 : 0F AA
     * The handler touches only EAX; EBX (the state-intact witness) is untouched
     * here and is saved/restored by the SMI/RSM save map, so the mainline reads
     * it back unchanged -- proving RSM restored the interrupted GPR state. */
    .align 16
    .global smm_handler
smm_handler:
    .byte 0x66, 0xB8, 0x4D, 0x5A, 0x4D, 0x5A
    .byte 0x67, 0x66, 0xA3, 0x00, 0x20, 0x00, 0x00
    .byte 0x0F, 0xAA
    .global smm_handler_end
smm_handler_end:

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                       /* ljmp ptr16:16 */
    .word   _start16_off               /* 16-bit offset within segment 0xF000 */
    .word   0xF000                     /* segment */
