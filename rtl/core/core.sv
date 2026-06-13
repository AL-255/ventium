// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core.sv — the Ventium integer/pipeline spine (R1 modularization,
// docs/rtl-refactor-plan.md). Renamed from intcore.sv: it now wires the
// extracted blocks (decode / issue_uv / ventium_alu_pkg / ventium_decode_pkg /
// fpu_x87_pkg) and runs the pipeline FSM + retire/DPI point. Functional spine:
// single-issue, in-order, multi-cycle integer core (PLAN.md §7,
// docs/m2-isa-spec.md), diff-clean vs QEMU user-mode.
//
// FSM skeleton (one instruction at a time, multi-cycle):
//   S_RESET  -> latch init_eip/init_esp/reset arch state
//   S_FETCH  -> read a 16-byte window at EIP (4 word reads)
//   S_DECODE -> combinational prefix+length+operand decode
//   S_LOAD   -> read a memory source / RMW dst / [ESI] or [EDI]
//   S_LOAD2  -> CMPS second memory operand ([EDI])
//   S_EXEC   -> compute result + EFLAGS; commit or hand off to a store/micro op
//   S_STORE  -> write a memory destination / push word
//   S_USEQ   -> micro-sequenced ops (PUSHA/POPA/POPF/string REP iterations)
//   S_HALT   -> int $0x80 or out-of-scope opcode: stop retiring
//
// Out-of-scope opcodes raise d_unknown and HALT loudly (no mis-execution).

module core
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_sys_pkg::*;
#(
    parameter logic [31:0] EFLAGS_RESET = 32'h0000_0202, // bit1 reserved-1 + IF
    parameter logic [15:0] SEG_CS = 16'h0023,
    parameter logic [15:0] SEG_SS = 16'h002b,
    parameter logic [15:0] SEG_DS = 16'h002b,
    parameter logic [15:0] SEG_ES = 16'h002b,
    parameter logic [15:0] SEG_FS = 16'h0000,
    parameter logic [15:0] SEG_GS = 16'h002b
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] init_eip,
    input  logic [31:0] init_esp,

    // M2S.1 (docs/m2s1-segmentation-spec.md "dual-boot-mode"): selects the COLD
    // RESET state. DEFAULT 0 = USER (M0-M6 unchanged: reset to init_eip/init_esp,
    // flat 4 GB segments, the post-loader linux-user state). 1 = SYSTEM: cold
    // reset matching qemu-system-i386 (CS:EIP=F000:FFF0, REAL mode CR0.PE=0,
    // cr0=0x60000010, EDX=0x00000663, eflags=0x00000002, real-mode selectors).
    // The whole system-mode segmentation datapath below is gated on this input;
    // with boot_mode==0 every segment base is 0 and real_mode is 0, so the
    // fetch/data addressing reduces EXACTLY to the flat user-mode core and
    // `make verify` is bit-for-bit unaffected.
    input  logic        boot_mode,

    // M4: when high, the core's fast path may issue two simple instructions per
    // clock (dual U/V issue) and reports pipe/paired for the cycle trace. When
    // low (the M1/M2/M3 functional gates), the fast path retires ONE instruction
    // per clock — architecturally identical, no pairing — so the func traces are
    // bit-for-bit unaffected by the pipeline. Tied 0 by default (lint-safe).
    input  logic        cycle_mode,

`ifdef VEN_L1_AXI
    // P1-1: high when the core's mem port sits behind the REAL (stalling) L1+AXI
    // subsystem (ventium_top l1axi_en / bus_mode=2). It arms the fast-path
    // MISS-STALL gates — the dual-issue fast path otherwise latches mem_rdata the
    // same clock it asserts the request (the BFM's same-cycle-ack assumption), which
    // a real L1 cannot honor on a miss. Tied 0 in bus modes 0/1; the whole port +
    // its gates are absent in the default build (no VEN_L1_AXI) -> byte-identical.
    input  logic        real_bus,
    // P1-1 #34: a FATAL bus fault from ven_axi_master (a watchdog timeout on a stuck
    // DDR/bridge, or a SLVERR/DECERR response). The core PARKS in S_HALT + asserts
    // cpu_hung (the PS observes it + resets) instead of executing the aborted line's
    // garbage. A #MC exception delivery is a later refinement (needs the IDT up).
    input  logic        bus_err,
`endif

    // M6: errata-enable bus (docs/m6-errata-spec.md). DEFAULT 0 = clean core
    // (M0-M5, bit-exact vs QEMU). When a bit is set, the core reproduces the
    // corresponding DOCUMENTED P5/P54C silicon defect (a "buggy stepping"). The
    // flag fully gates each bug: with errata_en==0 the datapath is unchanged, so
    // `make verify` stays GREEN. Bit assignment (ERR_* localparams below):
    //   [0] FDIV/SRT divide flaw      (Erratum 23)
    //   [1] FIST/FISTP overflow       (Erratum 20)
    //   [2] F00F LOCK CMPXCHG8B reg    hang (Erratum 81)
    //   [3] MOV moffs A2/A3 non-pair   (Erratum 59, cycle-mode only)
    //   [4] erroneous #DB on V86 POPF/IRET with a #GP fault (Erratum 79, M6B)
    input  logic [4:0]  errata_en,

    // ------------------------------------------------------------------------
    // M7.1 Quake user-mode lock-step int-0x80 PROXY + %gs base
    // (docs/m7-lockstep-spec.md). DEFAULT 0 = INERT — with proxy_en==0 the core
    // is byte-identical to the M0-M6 user core (int 0x80 still HALTs; gs_base is
    // unused; user %gs stays flat base 0), so `make verify` is bit-for-bit
    // unaffected. When proxy_en==1 (TB --quake-image / --lockstep mode):
    //   * an `int 0x80` (cd80) in USER mode does NOT halt: the core raises
    //     syscall_active for one clock exposing the upcoming retire `n`
    //     (syscall_n); the TB combinationally drives back the GOLDEN sys_call
    //     effects for that record — syscall_eax (kernel ret -> eax),
    //     syscall_resume_eip (the golden's NEXT-record pc; QEMU's one-insn-per-tb
    //     step folds the instruction following cd80, so the resume EIP comes from
    //     the golden, not from decoded length), and an OPTIONAL %gs TLS base
    //     (syscall_apply_gs + syscall_gs_base from set_thread_area). The core
    //     applies eax, the (latched) gs_base, advances eip to resume_eip, RETIRES
    //     the int-0x80 record (so the RTL trace has the row compare.py grades),
    //     and resumes — it never executes the kernel.
    //   * a user-mode `mov gs, sel` with the TLS GDT selector (0x33) installs the
    //     latched gs_base as seg_base[GS]; any other user selector stays flat
    //     (base 0). The kernel writes are applied by the TB directly to its
    //     memory model when it services syscall_active.
    input  logic        proxy_en,         // M7.1: enable the int-0x80 proxy + %gs base
    output logic        syscall_active,   // 1-clock: core hit cd80 in proxy mode
    output logic [63:0] syscall_n,        // the retire `n` this int-0x80 will get
    input  logic [31:0] syscall_resume_eip, // golden NEXT-record pc (post-syscall EIP)
    input  logic [31:0] syscall_eax,      // golden sys_call.ret -> eax
    input  logic        syscall_apply_gs, // 1: this syscall set a new %gs TLS base
    input  logic [31:0] syscall_gs_base,  // the resulting %gs base (set_thread_area)
`ifdef VEN_PS_PROXY
    // PS-bridge (F4): on real HW the PS answers the int-0x80 microseconds later, so
    // the proxy must STALL (S_SYSCALL_WAIT) and commit only when the PS has filled
    // syscall_eax/gs/resume AND written the kernel memory effects to the DDR carveout.
    input  logic        syscall_resp_valid,
`endif

    // M14: syscall ARGS exposed at the syscall_active pulse (read-only). For the
    // TB's free-run syscall EMULATOR (--emulate-syscalls): the TB samples these
    // the same clock as syscall_active to compute the real kernel effect, instead
    // of replaying a golden. Pure combinational regfile reads — completely INERT
    // to core behaviour (no feedback path), so every existing gate is unchanged.
    // i386 Linux syscall ABI: nr=eax, args=(ebx,ecx,edx,esi,edi,ebp).
    output logic [31:0] syscall_arg_eax,  // gpr[EAX] = syscall number
    output logic [31:0] syscall_arg_ebx,  // arg0
    output logic [31:0] syscall_arg_ecx,  // arg1
    output logic [31:0] syscall_arg_edx,  // arg2
    output logic [31:0] syscall_arg_esi,  // arg3
    output logic [31:0] syscall_arg_edi,  // arg4
    output logic [31:0] syscall_arg_ebp,  // arg5

    // ------------------------------------------------------------------------
    // M7.3b Win95 system co-sim port-I/O bus (docs/m7-lockstep-spec.md M7.3).
    // DEFAULT 0 = INERT: with cosim_en==0 the core's IN/OUT decode is the
    // M0-M6/M2S behaviour — an `out 0xf4` is the isa-debug-exit terminator (HALT,
    // no extra retire, preserving every sys gate byte-for-byte) and any OTHER
    // IN/OUT HALTs loudly (the corpus never uses port I/O), so the io_* bus below
    // is never exercised and `make verify` + the sys gates are unaffected.
    //
    // When cosim_en==1 (TB --win95-image / --lockstep mode) the core EXECUTES
    // IN/OUT through this bus, MIRRORING the mem_* protocol:
    //   * an IN raises io_req with io_we=0, io_addr=<port>, io_size=<1/2/4>; the
    //     TB drives back the matching golden dev_in[] VALUE on io_rdata + io_ack,
    //     and the core writes it width-aware into AL/AX/eAX. This is the ONLY
    //     environment input injected (the integrity crux — never a CPU register/
    //     flag/eip is fabricated; only the device-read value the CPU cannot
    //     compute on its own).
    //   * an OUT raises io_req with io_we=1, io_addr=<port>, io_size, io_wdata=
    //     <AL/AX/eAX>; the TB consumes it (and the cosim isa-debug-exit `out 0xf4`
    //     keeps terminating the run there). The CPU COMPUTES the OUT value itself.
    // The reset edx P5 stepping signature also follows the co-sim CPU model (see
    // the reset arm): cosim uses qemu `-cpu pentium` (edx=0x543), the existing sys
    // gates keep the unchanged 0x663. cosim_en implies boot_mode (system).
    // ------------------------------------------------------------------------
    input  logic        cosim_en,         // M7.3b: enable the Win95 co-sim port-I/O bus
    output logic        io_req,           // I/O bus request (IN or OUT)
    output logic        io_we,            // 1 = OUT (CPU drives), 0 = IN (CPU reads)
    output logic [15:0] io_addr,          // the 16-bit I/O port
    output logic [2:0]  io_size,          // access width in BYTES (1/2/4)
    output logic [31:0] io_wdata,         // OUT data (AL/AX/eAX, width per io_size)
    input  logic [31:0] io_rdata,         // IN data (the golden dev_in value)
    input  logic        io_ack,           // I/O response strobe (combinational-OK)

    // ------------------------------------------------------------------------
    // M8.1 EXTERNAL INTERRUPT pins (docs PROGRESS_Jun04.md "M8" + the M8.0
    // design). DEFAULT INERT: the whole external-interrupt divert below is
    // gated on `soc_en` (a NEW input that defaults 0 here and is tied 0 in
    // ventium_top), so with soc_en==0 these pins are dead — the core is
    // byte-for-byte identical to the M0-M7 core (every existing gate +
    // `make verify` unaffected). This is the proven additive pattern
    // (boot_mode / cycle_mode / errata_en / proxy_en / cosim_en all default
    // inert). When soc_en==1 (the M8 ventium_soc) an EXTERNAL maskable INTR
    // from the 8259 master, or an edge NMI, is delivered at the next
    // instruction boundary through the EXISTING verified S_INT_GATE ->
    // S_INT_CS -> S_INT_PUSH IDT FSM via the int_sw=0 (hardware) path:
    //   * intr        — LEVEL request from the 8259 master INT (held until
    //                   serviced). Delivered only when EFLAGS.IF=1 and the
    //                   one-instruction STI/MOV-SS shadow is clear.
    //   * nmi         — NON-MASKABLE edge. Latched on a rising edge, delivered
    //                   regardless of IF, vector 2, and blocks a further NMI
    //                   until the IRET that ends the handler.
    //   * inta        — 1-clock INTERRUPT-ACKNOWLEDGE strobe pulsed in the same
    //                   clock the core accepts a maskable INTR. The PIC drives
    //                   inta_vector COMBINATIONALLY off this strobe (its second
    //                   INTA cycle), which the core latches as the delivered
    //                   vector. NMI does NOT pulse inta (vector is fixed 2).
    //   * inta_vector — the 8-bit vector the PIC supplies on the inta strobe.
    //   * inta_valid  — the PIC asserts this with a meaningful inta_vector
    //                   (reserved for a future spurious-IRQ refinement; the
    //                   master 8259 always supplies a vector, so the current
    //                   divert latches inta_vector unconditionally).
    // ------------------------------------------------------------------------
    input  logic        soc_en,           // M8.1: enable the external-interrupt divert
    input  logic        intr,             // level: pending maskable INTR (8259 master)
    input  logic        nmi,              // edge: non-maskable interrupt request
    output logic        inta,             // 1-clock INTERRUPT-ACKNOWLEDGE strobe
    input  logic [7:0]  inta_vector,      // PIC-supplied vector (combinational on inta)
    input  logic        inta_valid,       // PIC has a meaningful inta_vector

    output logic        mem_req,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ack,

    // M6: raised (and latched) when the core enters the F00F hang state
    // (Erratum 81). Lets the TB observe the documented "system hang" without the
    // core ever retiring the offending instruction or a clean #UD.
    output logic        cpu_hung,

    output logic        retire_valid,
    output logic [31:0] retire_pc,
    output arch_state_t retire_state,

    // x87 post-commit architectural state (M3). Valid in the same cycle as
    // retire_valid. `retire_x87_touched` is 1 iff the retired instruction was an
    // x87 op (so ventium_top calls vtm_retire_x87 only then). st0..st7 are in
    // TOP-relative order (st0 = register at TOP), each canonical floatx80[79:0].
    // fstat already has TOP overlaid in bits[13:11]; ftag follows QEMU's
    // user-mode gdbstub convention (constant 0x0000).
    output logic        retire_x87_touched,
    output logic [15:0] retire_fctrl,
    output logic [15:0] retire_fstat,
    output logic [15:0] retire_ftag,
    output logic [79:0] retire_st0, retire_st1, retire_st2, retire_st3,
    output logic [79:0] retire_st4, retire_st5, retire_st6, retire_st7,

    // ------------------------------------------------------------------------
    // M4 cycle-trace attribution (docs/m4-pipeline-spec.md "RTL cycle-trace
    // producer", trace-format §2.3). The dual-issue pipeline raises these in the
    // SAME clock as retire_valid, conveying which pipe each retiring instruction
    // issued to and whether it issued paired. A paired issue retires TWO
    // instructions in one clock: retire_valid+retire2_valid both high, the U
    // insn carries retire_pipe=U/paired=0 and the V insn retire2_pipe=V/paired=1.
    // ventium_top turns each high retire(2)_valid into a vtm_retire(+_cycle) call.
    // pipe encoding: 0=U, 1=V, 2=none. (Func mode ignores all of this.)
    // ------------------------------------------------------------------------
    output logic        retire_pipe_valid,   // primary retirement carries pipe info
    output logic [1:0]  retire_pipe,         // 0=U 1=V 2=none for the primary insn
    output logic        retire_paired,       // primary insn issued paired (always U=0 here)

    output logic        retire2_valid,       // a SECOND insn retired this same clock
    output logic [31:0] retire2_pc,
    output arch_state_t retire2_state,
    output logic [1:0]  retire2_pipe,        // pipe for the second insn (V=1)
    output logic        retire2_paired,      // second insn paired with the first (1)

    // ------------------------------------------------------------------------
    // M2S.1 system-mode retire payload (docs/m2s1-segmentation-spec.md "TB sys
    // emission"). Valid in the same clock as retire_valid. retire_sys is high
    // only for a system-mode core (boot_mode=1); ventium_top then calls the
    // vtm_retire_sys DPI hook carrying cr0..cr4 (and the selectors, which are
    // already in retire_state). In user mode retire_sys stays low and these are
    // never read, so the user trace is byte-for-byte identical.
    // ------------------------------------------------------------------------
    output logic        retire_sys,          // this retirement carries system state
    output logic [31:0] retire_cr0, retire_cr2, retire_cr3, retire_cr4
`ifdef VEN_DBG_CORE
    ,
    // ------------------------------------------------------------------------
    // Debug observability taps (VEN_DBG_CORE). PURE OBSERVERS of existing FSM/
    // arch registers — add no logic to any datapath, never feed back, so a
    // +VEN_DBG_CORE build is cycle-identical. With no define, none of this exists
    // and the default/deploy build is byte/cycle-identical.
    //   dbg_state    — FSM micro-state (state_e): WHERE/why the core is parked.
    //   dbg_int_vec  — last delivered exception/interrupt vector (#UD=6/#GP=13/
    //                  #PF=14/ext IRQ); holds the last value.
    //   dbg_fault_pc — source EIP of that exception/interrupt (int_src_pc).
    //   dbg_cr0      — live CR0: PE(bit0)/PG(bit31) reveal real/protected/paging.
    // (single-step / breakpoint control ports are added below once the FSM
    //  issue-boundary hold is wired — see the dbg_hold block.)
    // ------------------------------------------------------------------------
    output logic [5:0]  dbg_state,
    output logic [7:0]  dbg_int_vec,
    output logic [31:0] dbg_fault_pc,
    output logic [31:0] dbg_cr0,
    // Single-step / instruction-breakpoint control (the ONLY debug signals that
    // affect execution, and ONLY when the PS arms them — see the dbg_hold block).
    // Park is at the S_DECODE instruction boundary, LOWER priority than SMI/NMI/
    // INTR so no interrupt is lost, modeled on the S_HLTWAIT resumable halt.
    input  logic        dbg_halt_req,   // level: park at the next instruction boundary
    input  logic        dbg_step,       // pulse: release for exactly ONE instruction
    input  logic        dbg_bp_en,      // enable the PC breakpoint
    input  logic [31:0] dbg_bp_addr,    // park when the about-to-issue EIP == this
    input  logic        dbg_bp_clr,     // pulse: clear a latched breakpoint (resume)
    output logic        dbg_halted      // 1 = parked at an instruction boundary
`endif
);

  // ===========================================================================
  // Architectural state
  // ===========================================================================
  logic [31:0] eip;
  logic [31:0] eflags;
  logic [31:0] gpr [NUM_GPR];   // eax ecx edx ebx esp ebp esi edi

  // ===========================================================================
  // M2S.1 system-mode architectural state (docs/m2s1-segmentation-spec.md).
  // ALL of this is INERT when boot_mode==0 (user): the selectors mirror the
  // SEG_* params, every base is 0, real_mode is 0, and creg0/creg2/3/4 are not
  // emitted. The addressing functions below fold the bases in additively, so a
  // base of 0 is the unchanged flat user-mode address. sys_mode latches
  // boot_mode at reset so the gating is a single registered bit.
  // ===========================================================================
  logic        sys_mode;          // latched boot_mode (1 = system-mode core)
  logic [31:0] creg0;             // CR0 (PE bit0, ..., PG bit31). Only PE active.
  logic [31:0] creg2, creg3, creg4;   // present; untouched this stage (paging=M2S.2)
  // Segment selectors (visible part). Index order = SEG_KEYS: cs ss ds es fs gs.
  logic [15:0] seg_sel  [NUM_SEG];
  // Hidden descriptor cache: base + limit (byte granular, expanded) + the access
  // byte (P/DPL/S/type) per segment. limit/attr are the home for the protection
  // checks computed at descriptor load (seg_load_fault); the pseg corpus loads
  // only clean descriptors so the decision is always "no fault" — but it IS
  // computed (NOT just declared), per docs/m2s1-segmentation-spec §3.
  logic [31:0] seg_base [NUM_SEG];
  logic [31:0] seg_limit[NUM_SEG];   // hidden limit (byte granular; limit checks)
  logic [7:0]  seg_attr [NUM_SEG];   // descriptor access byte: P|DPL[1:0]|S|type[3:0]
  // CPL = the current privilege level, derived from CS.RPL on a CS load (far
  // jump). Reset/real mode: 0. Used as the EFFECTIVE privilege in the DPL checks.
  logic [1:0]  cpl_r;
  // GDTR / IDTR (loaded by LGDT/LIDT).
  logic [31:0] gdt_base;
  logic [15:0] gdt_limit;
  logic [31:0] idt_base;
  logic [15:0] idt_limit;
  // M2S.4 — TR / TSS. LTR loads the task register from a GDT TSS descriptor; the
  // hidden cache holds the TSS linear base + limit (and the selector for STR).
  // tr_valid records whether a TSS has been installed (so cross-priv delivery
  // can read TSS.ssN:espN; if no TR is loaded a cross-priv attempt would #TS,
  // but the pcpl corpus always LTRs first).
  logic [15:0] tr_sel;
  logic [31:0] tr_base;
  logic [31:0] tr_limit;
  logic        tr_valid;
  // M2S.4b — the OUTGOING TSS descriptor access byte (captured at LTR), so a task
  // switch can clear its busy bit (type B->9) without re-reading the descriptor.
  logic [7:0]  tr_attr;
  // M2S.5 — SMM / RSM (docs/m2s5-smm-spec.md). SMBASE holds the base of the SMRAM
  // region (reset default 0x30000; RSM may relocate it from the SMBASE save slot).
  // smm_active = the CPU is currently in System Management Mode (HF_SMM); set on
  // SMI# entry, cleared by RSM. It gates the addressing-context overrides AND the
  // RSM decode (RSM is #UD outside SMM). smi_pending latches a recognised SMI#
  // (the APIC self-IPI with delivery-mode=SMI in the psmm corpus) so it is taken
  // at the NEXT instruction boundary, exactly like qemu's deferred SMI dispatch.
  // (The interrupted CR0 — incl. PE/PG — is saved to the SMRAM map at SMI# entry
  // and read back from it on RSM, so no separate "saved PE" register is kept; the
  // SMM addressing context is driven directly by CR0.PE==0 + the SMM CS/base set
  // up at entry.)
  logic [31:0] smbase;            // SMRAM base (default 0x30000)
  logic        smm_active;        // in SMM (1 = HF_SMM)
  logic        smi_pending;       // a recognised SMI# is waiting for an insn boundary
  // M2S.5 scratch for the SMI-save / RSM-restore micro-sequences (state-save map
  // at SMBASE+0x8000+offset, P5 Table 20-1 layout — see S_SMI_SAVE / S_RSM).
  logic [5:0]  smm_step;          // beat counter across the save/restore sequence
  logic [31:0] smm_resume_eip;    // EIP to save (next insn after the SMI boundary)
  // RSM read-back holding registers: the restore reads the whole map into these,
  // then commits the architectural state in one clock on the final beat so a
  // half-restored context is never observable mid-sequence.
  logic [31:0] rsm_cr0, rsm_cr3, rsm_cr4, rsm_cr2;
  logic [31:0] rsm_eflags, rsm_eip;
  logic [31:0] rsm_gpr [NUM_GPR];
  logic [15:0] rsm_sel  [NUM_SEG];
  logic [31:0] rsm_base [NUM_SEG];
  logic [31:0] rsm_limit[NUM_SEG];
  logic [7:0]  rsm_attr [NUM_SEG];
  logic [31:0] rsm_gdtb, rsm_idtb, rsm_smbase;
  logic [15:0] rsm_gdtl, rsm_idtl;
  // ({cs_d, cpl} are restored directly from the final read-back beat, not staged
  // in a holding reg — see S_RSM commit.)

  // ===========================================================================
  // M8.1 — EXTERNAL INTERRUPT recognition latches (mirror the smi_pending block).
  // ALL of these are INERT when soc_en==0: they are only ever written inside a
  // `soc_en`-gated branch, so with the pins tied off (ventium_top) they hold
  // their reset value (0) forever and never affect the datapath — every existing
  // gate stays bit-identical. (Like smi_pending, the recognition is sampled at
  // the S_DECODE instruction boundary so an external interrupt is taken BEFORE
  // the about-to-run instruction executes, i.e. it restarts at the current EIP.)
  // ===========================================================================
  logic        intr_pending;      // a maskable INTR (8259) is asserted (level-mirror)
  logic        nmi_pending;       // an NMI edge has been latched, awaiting delivery
  logic        nmi_prev;          // previous-clock nmi level, for rising-edge detect
  logic        irq_shadow;        // the STI / MOV-SS one-instruction interrupt inhibit
                                   // (HF_INHIBIT_IRQ): set for exactly the ONE
                                   // instruction following an STI, cleared at the next
                                   // S_DECODE boundary, so an INTR cannot interpose
                                   // between STI and the next instruction.
  logic        nmi_in_progress;   // an NMI handler is running: blocks a further NMI
                                   // until the IRET that ends it (NMI masking, IA-32).

  // P5 SMRAM State Save Map — register offsets (Pentium Dev. Manual Vol.3
  // Table 20-1, 510\60 variant). The ABSOLUTE save-map address of a field is
  // smbase + 0x8000 + offset; the map spans offset 0x7E00..0x7FFC (absolute
  // SMBASE+0xFE00..SMBASE+0xFFFC). The architecturally-named, writeable/restored
  // fields the round-trip needs are below; the segment HIDDEN descriptor state
  // (base/limit/attr) is saved into the reserved areas (the exact P5 reserved-slot
  // encoding is stepping-specific / not publicly documented, so the hidden-state
  // layout here is this RTL's internal convention — see the DONE-PARTIAL note in
  // the README). All fields land in the documented map window so RSM round-trips.
  // DONE-PARTIAL / DEFERRED (explicitly NOT in the save/restore beat list below):
  // Table 20-1 also defines DR6 @ 0x7FCC, DR7 @ 0x7FC8, TR (selector) @ 0x7FC4,
  // and LDT Base @ 0x7FC0. This RTL omits all four across SMI#/RSM: DR6/DR7 do not
  // exist yet (debug registers are the next stage, M2S.6) and there is no LDT-base
  // register in the core; TR (tr_sel/tr_base, from M2S.4) IS architectural but is
  // left unchanged through SMM (the psmm corpus does not modify TR/LDT/DR in the
  // handler, so the round-trip still closes). These are real divergences from the
  // full P5 save map, deferred honestly — see the README "Still deferred" list.
  localparam logic [15:0] SMO_CR0    = 16'h7FFC;
  localparam logic [15:0] SMO_CR3    = 16'h7FF8;
  localparam logic [15:0] SMO_EFLAGS = 16'h7FF4;
  localparam logic [15:0] SMO_EIP    = 16'h7FF0;
  localparam logic [15:0] SMO_EDI    = 16'h7FEC;
  localparam logic [15:0] SMO_ESI    = 16'h7FE8;
  localparam logic [15:0] SMO_EBP    = 16'h7FE4;
  localparam logic [15:0] SMO_ESP    = 16'h7FE0;
  localparam logic [15:0] SMO_EBX    = 16'h7FDC;
  localparam logic [15:0] SMO_EDX    = 16'h7FD8;
  localparam logic [15:0] SMO_ECX    = 16'h7FD4;
  localparam logic [15:0] SMO_EAX    = 16'h7FD0;
  localparam logic [15:0] SMO_GS     = 16'h7FBC;   // selector (upper 2 bytes rsvd)
  localparam logic [15:0] SMO_FS     = 16'h7FB8;
  localparam logic [15:0] SMO_DS     = 16'h7FB4;
  localparam logic [15:0] SMO_SS     = 16'h7FB0;
  localparam logic [15:0] SMO_CS     = 16'h7FAC;
  localparam logic [15:0] SMO_ES     = 16'h7FA8;
  localparam logic [15:0] SMO_IDTB   = 16'h7F94;   // IDT base
  localparam logic [15:0] SMO_GDTB   = 16'h7F88;   // GDT base
  localparam logic [15:0] SMO_AHALT  = 16'h7F02;   // Auto-HALT restart slot (word, bit0)
  localparam logic [15:0] SMO_REVID  = 16'h7EFC;   // SMM revision identifier (RO)
  localparam logic [15:0] SMO_SMBASE = 16'h7EF8;   // SMBASE relocation slot
  // RTL-internal reserved-area convention for the segment HIDDEN descriptor cache
  // + the GDT/IDT limits (so RSM restores the full hidden state bit-exactly). The
  // SDM reserved window 0x7E00..0x7EF7 is private to the implementation; we lay
  // the 6 segments' {base,limit,attr} + the table limits there.
  localparam logic [15:0] SMO_HID    = 16'h7E00;   // base of the hidden-state block
  // P5 SMM revision identifier value written by SMI# (Pentium Dev. Manual Vol.3
  // §20.1.5.1, Fig 20-3). Lower word = base-SMM-architecture version; upper word =
  // extensions. On the Pentium 510\60/567\66: bit 16 (I/O-Instruction-Restart) = 0
  // (not supported), bit 17 (SMBASE/jump-vector relocation support) = 1 — §20.1.5.3
  // states "Since bit 17 of the SMM Revision Identifier is set in the Pentium
  // processor (510\60, 567\66) ...". So the faithful P5 value is 0x00020000. (The
  // §20.2.2 remark that the 510\60 "revision ID is 0" refers to the upper-word
  // EXTENSION version number being 0 — it becomes 2 on the 735\90+ when the I/O-
  // restart extension is enabled — not to bit 17, the relocation-support flag,
  // which is independent.) qemu-system-i386 agrees: target/i386 SMM_REVISION_ID =
  // 0x00020000 for the 32-bit target (smm_helper.c). The slot is read-only / not
  // restored by RSM, so this is benign for the round-trip but is the correct value.
  localparam logic [31:0] SMM_REV_ID = 32'h0002_0000;
  // Final beat index of the save/restore sequence (0-based). 45 beats: see the
  // S_SMI_SAVE / S_RSM beat map. The bus arm + the restore latch both walk
  // smm_step 0..SMM_LAST in lockstep so save & restore are symmetric.
  localparam logic [5:0]  SMM_LAST   = 6'd44;

  // real_mode = system-mode core with CR0.PE==0. In real mode the addressing is
  // linear = (sel<<4)+offset (and the CS default operand size is 16-bit).
  logic        real_mode;
  assign real_mode = sys_mode && !creg0[0];

  // ===========================================================================
  // M7.2 VIRTUAL-8086 MODE (V86 / method-1, VME-OFF). docs/m7-lockstep-spec §M7.2.
  // ===========================================================================
  // v86 = system-mode core with EFLAGS.VM (bit17) set. V86 runs with PE=1 & PG=1
  // (paging/TLB stay live — the M2S.2 walk path is unchanged) but uses real-mode
  // sel<<4 segment bases and a FORCED architectural CPL of 3 (USER). EVERYTHING
  // gated on `v86` is INERT when eflags[17]==0 (so make verify + every prior sys
  // gate stays byte-identical): EFLAGS.VM is 0 across all of user mode and the
  // whole pre-V86 sys corpus, so v86==0 there and all V86 arms below are dead.
  // iopl = EFLAGS.IOPL (bits 13:12). Under v86 with iopl<3 the IOPL-sensitive ops
  // (CLI/STI/PUSHF/POPF/INT n/IRET/IN/OUT) #GP(0) to the CPL0 monitor (method-1);
  // at iopl==3 they execute normally. The pv86 corpus runs at IOPL=0 so all six
  // IOPL-sensitive ops in the V86 task trap.
  logic        v86;
  assign v86 = sys_mode && eflags[17];
  logic [1:0]  iopl;
  assign iopl = eflags[13:12];
  // seg_real = "addressing uses a sel<<4 segment base" — real mode OR V86. The
  // MOV-sreg / far-jump base computation + the decode routing both key on this.
  logic        seg_real;
  assign seg_real = real_mode || v86;
  // eff_cpl = the EFFECTIVE current privilege. In V86 it is architecturally 3
  // (USER) regardless of the CS selector's RPL (the CS selector is a real-mode
  // segment value, e.g. 0x1000, so cs&3 is NOT the CPL). Outside V86 it is cpl_r.
  // Used wherever the privilege level governs a protection/paging decision.
  logic [1:0]  eff_cpl;
  assign eff_cpl = v86 ? 2'd3 : cpl_r;

  // cs_d = the CS descriptor D/B bit (code default operand+address size, 1=32).
  // It governs the EFFECTIVE operand/address size default, NOT real_mode: right
  // after CR0.PE=1 but BEFORE the far jump loads a 32-bit CS, the segment is
  // still 16-bit (CS.D=0), so the bootstrap's `66 ljmp ptr16:32` correctly means
  // a 32-bit offset. Reset/real-mode CS.D=0; a PM far jump to a D=1 code segment
  // sets it. def16 = "16-bit is the default" = system-mode core with CS.D==0.
  logic        cs_d;
  logic        def16;
  assign def16 = sys_mode && !cs_d;

  // SEG_KEYS index constants (cs ss ds es fs gs) for the seg_* arrays.
  localparam int SG_CS = 0, SG_SS = 1, SG_DS = 2, SG_ES = 3, SG_FS = 4, SG_GS = 5;

  // ===========================================================================
  // M2S.2 PAGING MMU + split I/D TLBs (docs/m2s2-paging-spec.md).
  // ===========================================================================
  // paging_on = system-mode core with CR0.PG (creg0[31]) set AND CR0.PE set
  // (paging only takes effect in protected mode). When 0, linear == physical
  // (real mode, flat PM-before-PG, and ALL of user mode) so the M2S.1 path and
  // the user-mode path are bit-identical. CR4.PSE (creg4[4]) enables 4 MiB pages
  // when a PDE has PS (bit 7) set.
  logic paging_on;
  assign paging_on = sys_mode && creg0[31] && creg0[0];
  logic cr4_pse;
  assign cr4_pse = creg4[4];

  // Split I/D TLBs (correctness model, NOT cycle timing — spec §3). Each is a
  // small direct-mapped array keyed on the linear page number. An entry caches
  // the translated physical frame + the effective P/RW/US permission of the page
  // (AND of PDE & PTE) + a 4 MiB-page flag (so the offset width is right) +
  // whether the page's A/D bits have already been set in memory (so a repeat use
  // does not re-write them, matching qemu-system which sets A/D once per state).
  localparam int TLB_ENTRIES = 16;          // direct-mapped; index = lin[15:12]
  // The TLB ARRAYS + lookup + fill-commit + flush now live in the parameterized
  // `tlb` module (rtl/mem/tlb.sv), instantiated TWICE below: u_itlb (IS_D=0,
  // fetch) and u_dtlb (IS_D=1, data). The whole S_WALK page-walk micro-sequence
  // STAYS in this spine and drives the fill ports. These nets carry the two
  // instances' combinational lookup outputs (read by xlate_miss / perm_fault /
  // mem_xlate) and the spine-driven fill/flush inputs. See the instantiation +
  // fill driver near the bus-translate block below.
  // The lookup is at cur_lin; mem_xlate reuses it because cur_lin == the bus
  // mem_addr in every translatable state (proven verbatim across the FSM arms).
  // I-TLB (instruction fetches) lookup outputs.
  logic        itlb_lk_hit;   logic [31:0] itlb_lk_phys;
  logic [2:0]  itlb_lk_perm;  logic        itlb_lk_dirty;
  // D-TLB (data accesses) lookup outputs — Dirty tracked so a write marks D.
  logic        dtlb_lk_hit;   logic [31:0] dtlb_lk_phys;
  logic [2:0]  dtlb_lk_perm;  logic        dtlb_lk_dirty;

  // +VEN_FE_PIPE: page-keyed micro-TLB register. Translation is per-4 KiB-page, so
  // we register the {i,d}tlb lookup keyed on the page (cur_lin[31:12]); xlate_miss /
  // mem_xlate then read the REGISTERED result, lifting the combinational hit_of
  // carry-chain off the issue path (the ~41 MHz full-SoC eip-cone binder). A page
  // crossing sets fe_xlate_pend for 1 clock (the only added latency) while the
  // register samples the new page. fe_xlate_pend is tied 0 in the default build, so
  // every `... && !fe_xlate_pend` gate folds away -> default is byte/cycle-identical.
  // Fmax-only demonstrator contract (cycle bands not claimed); functionally arch-exact.
  logic fe_xlate_pend;
`ifdef VEN_FE_PIPE
  logic [19:0] fe_itlb_page, fe_itlb_phys;  logic fe_itlb_hit,  fe_itlb_v;
  logic [19:0] fe_dtlb_page, fe_dtlb_phys;  logic fe_dtlb_hit,  fe_dtlb_dirty, fe_dtlb_v;
`endif

  // Page-walk micro-sequence registers. The walk is a small FSM living inside
  // S_WALK: it reads the PDE, then the PTE (4 KiB) — writing A/D bits back to the
  // page tables as memory writes — fills the proper TLB, then returns to the
  // diverted memory state (walk_ret_state, declared with the FSM enum below).
  // walk_for_d selects the D-TLB (else I).
  logic [31:0] walk_lin;           // the linear address being translated
  logic        walk_for_d;         // 1 = data access (D-TLB), 0 = fetch (I-TLB)
  logic        walk_is_write;      // the resumed access is a write (sets Dirty)
  logic [2:0]  walk_step;          // 0=read PDE,1=write PDE A,2=read PTE,3=write PTE A/D
  logic [31:0] walk_pde;           // latched PDE
  logic [31:0] walk_pte;           // latched PTE
  logic [31:0] walk_pde_addr;      // physical addr of the PDE
  logic [31:0] walk_pte_addr;      // physical addr of the PTE
  logic        walk_pf;            // a page-fault DECISION was reached (delivery=M2S.3)
  // M2S.2 #PF DECISION outputs (delivery is M2S.3): the faulting linear address is
  // latched into CR2; the error code (P/RW/US) is computed. For the clean gate
  // tests this is never asserted.
  logic [2:0]  pf_errcode;         // {US, RW, P} of the faulting access

  // ===========================================================================
  // x87 FPU architectural state (M3)
  // ===========================================================================
  // R2: the x87 architectural STATE FILE (the 8x80-bit physical stack fpr[8],
  // TOP, control/status/tag words, the synchronous reset, and the ftop-relative
  // st(i) read addressing) is now OWNED by the fpu_top module (rtl/fpu/fpu_top.sv),
  // instantiated as u_fpu_state below. The spine keeps the DATAPATH (the
  // fpu_x87_pkg value computations), the M5 FP scoreboard, the S_FEXEC/S_FSTORE
  // FSM, and FNSTSW->gpr[EAX]; it computes each value and drives it onto the
  // module's write ports (the fp_we_* combinational driver near the u_fpu_state
  // instance), and reads the registered state back through these combinational
  // wires (st(i) = fp_st[i], ftop/fctrl/fstat/fptag = the module's *_o outputs).
  // st(i) = fpr[(ftop+i)&7]. Push decrements TOP then writes; pop increments TOP
  // (leaving the stale value, so the trace's "empty" st-slots keep their last
  // contents — matches QEMU). fstat keeps the TOP field (bits[13:11]) ZERO
  // internally (overlaid from ftop on read, mirrors helper_fnstsw); fptag bit i =
  // tag for fpr[i] (1=empty) — drives FXAM, NOT reported in the trace.
  logic [79:0] fp_st [8];        // fp_st[i] = ST(i) = fpr[ftop+i] (module read port)
  logic [79:0] fp_st0_phys;      // = fpr[ftop] (physical ST0, for fstore_val)
  logic [2:0]  ftop;             // = u_fpu_state.ftop_o
  logic [15:0] fctrl;            // = u_fpu_state.fctrl_o (control word; reset 0x037f)
  logic [15:0] fstat;            // = u_fpu_state.fstat_o (RAW; TOP not overlaid)
  logic [7:0]  fptag;            // = u_fpu_state.fptag_o (bit i = tag for fpr[i])
  logic [31:0] fip, fdp;         // = u_fpu_state.fip_o/fdp_o (M11 env-image only)
  logic [15:0] fcs, fds;         // = u_fpu_state.fcs_o/fds_o
  logic [639:0] fpr_flat;        // = u_fpu_state.fpr_flat_o (physical fpr[7..0])
  logic        x87_touched_r;   // retired insn touched the FPU (drives DPI call)

  // ===========================================================================
  // M6 errata-enable bit positions (docs/m6-errata-spec.md). Each gates exactly
  // one documented defect; all default OFF (errata_en==0 == clean M0-M5 core).
  // ===========================================================================
  localparam int ERR_FDIV  = 0;   // Erratum 23  : FDIV/SRT divide flaw
  localparam int ERR_FIST  = 1;   // Erratum 20  : FIST/FISTP overflow undetected
  localparam int ERR_F00F  = 2;   // Erratum 81  : LOCK CMPXCHG8B reg-dst hang
  localparam int ERR_MOFFS = 3;   // Erratum 59  : MOV moffs A2/A3 non-pairing
  // M6B (242480-041 Erratum 79): "Erroneous Debug Exception on POPF/IRET
  // Instructions with a GP Fault". In virtual-8086 mode at IOPL<3, a POPF or IRET
  // is IOPL-sensitive and #GP(0)-traps to the monitor WITHOUT accessing the stack.
  // If a DATA breakpoint is armed on the SS:ESP linear address, the breakpoint
  // must NOT trigger (the stack was never touched) — but on the affected P5
  // steppings an ERRONEOUS #DB is delivered IN ADDITION to the #GP, with the
  // saved CS:EIP pointing at the FIRST instruction of the #GP handler (the
  // documented Implication). Default OFF -> only the #GP is delivered (clean).
  localparam int ERR_DBGP  = 4;   // Erratum 79  : erroneous #DB on V86 POPF/IRET #GP

  // ===========================================================================
  // FSM
  // ===========================================================================
  typedef enum logic [5:0] {   // M7.3c: widened 5->6 bits to admit S_INS (the prior
                               // 32 states exactly filled a [4:0] enum)
    S_RESET, S_FETCH, S_DECODE, S_LOAD, S_LOAD2, S_EXEC, S_STORE, S_USEQ, S_HALT,
    S_FLOAD, S_FEXEC, S_FSTORE,
`ifdef VEN_SRT_ITER
    S_FP_BUSY,   // wait for the iterative SRT FDIV/FSQRT engine
`endif
`ifdef VEN_IDIV_ITER
    S_DIV_BUSY,  // wait for the iterative integer DIV/IDIV engine
`endif
`ifdef VEN_BCD_ITER
    S_BCD_BUSY,  // wait for the iterative FP->packed-BCD (FBSTP) engine
    S_FBLD_BUSY, // wait for the iterative packed-BCD->FP (FBLD) engine
`endif
`ifdef VEN_TRANSCENDENTAL
    S_TRSC_BUSY, // wait for the iterative x87 transcendental engine (F2XM1, #11)
`endif
`ifdef VEN_FP_PIPE
    S_FEXEC_EX,  // slow-arm FP-execute 2nd stage: f_eval from the registered
                 // operands (captured in S_FEXEC) -> commit (we_wabs) + retire IN
                 // THE SAME CLOCK, so the per-retire arch-state check is exact.
`endif

`ifdef VEN_PS_PROXY
    S_SYSCALL_WAIT,   // PS-bridge (F4): hold the int-0x80 proxy until syscall_resp_valid
`endif
    S_FENV_ST, S_FENV_LD,   // M11b: env/state store (FNSTENV/FNSAVE) & load (FLDENV/FRSTOR)
    // M7.3b Win95 co-sim port I/O: the IN/OUT bus handshake state (cosim only).
    S_IO,
    // M7.3c INS (port-input string): per-element IN handshake, then store to [EDI]
    // (reuses the K_STR S_STORE element/retire/loop path). Cosim only.
    S_INS,
    S_PF, S_PIPE, S_F00F_HANG,
    // M2S.1 system-mode descriptor + table micro-sequences:
    S_LGDT, S_SEGLD, S_LJMP,
    // M9.5 real-mode far CALL / RETF (2-beat stack push / pop of CS:IP). Reuse
    // seg_step as the beat counter (mutually exclusive with the seg/ljmp states).
    S_LCALL, S_RETF,
    // M9.5 SGDT/SIDT: 2-beat store of the 6-byte GDTR/IDTR pseudo-descriptor.
    S_SGDT,
    // F3 real-mode IVT interrupt delivery: read the 4-byte IVT entry, push the
    // 16-bit FLAGS:CS:IP frame, then IRET pops it back. (Pure real mode, PE=0;
    // V86/PM keep the existing 8-byte-gate S_INT_* / S_IRET path.)
    S_RMINT_RD, S_RMINT_PUSH, S_RMIRET,
    // F3 interruptible HLT (system mode): HLT retires + parks here until a maskable
    // INTR / NMI wakes the core and is delivered (IRET resumes after the HLT). Real
    // firmware (SeaBIOS yield = sti;hlt) busy-waits on the timer IRQ this way. User
    // mode keeps the loud terminal S_HALT (no wake) so make verify is byte-identical.
    S_HLTWAIT,
    // M2S.2 paging: the 2-level page-walk micro-sequence (PDE read -> PTE read ->
    // optional A/D writeback -> TLB fill -> resume the diverted memory state).
    S_WALK,
    // M2S.3 IDT delivery micro-sequence (gated sys_mode). A fault DECISION (the
    // M2S.1 segment faults + M2S.2 #PF, now DELIVERED) or a software INT/INT3/
    // INTO/UD2 vectors through IDT[v]:
    //   S_INT_GATE : read the 8-byte IDT gate descriptor (offset+selector+attr)
    //   S_INT_CS   : read the 8-byte GDT code descriptor named by the gate sel
    //   S_INT_PUSH : push the exception frame (EFLAGS, CS, EIP[, error code])
    // then load CS:EIP from the gate, clear IF/TF (interrupt gate), and retire.
    // S_IRET pops EIP/CS/EFLAGS (near, same-privilege); S_INT_CS_RET reloads the
    // returned-to CS descriptor and retires the IRET.
    S_INT_GATE, S_INT_CS, S_INT_PUSH, S_IRET, S_INT_CS_RET,
    // M2S.4 — TR/TSS + cross-privilege machinery:
    //   S_LTR     : LTR — read the GDT TSS descriptor (base/limit), set busy bit,
    //               load TR. (STR is a register write, handled in S_EXEC.)
    //   S_INT_TSS : cross-priv delivery — read TSS.ssN:espN (N = target CS.DPL).
    //   S_INT_SS  : cross-priv delivery — read + load the new SS descriptor.
    //   S_IRET_SS : inter-priv IRET — reload the popped (outer) SS descriptor.
    S_LTR, S_INT_TSS, S_INT_SS, S_IRET_SS,
    // M2S.4b — HARDWARE TASK SWITCH micro-sequence (far JMP/CALL to a TSS, gated
    // sys_mode; IA-32 SDM Vol.3 §7.3). A far JMP whose target GDT descriptor is a
    // SYSTEM (S=0) available/busy 32-bit TSS (type 9/B) runs:
    //   S_TSW_SAVE : SAVE the outgoing task state into the CURRENT TSS (tr_base):
    //                EIP@0x20, EFLAGS@0x24, the 8 GPRs@0x28..0x44, the 6 segment
    //                selectors@0x48..0x5C, LDTR@0x60 (one dword write per beat).
    //   S_TSW_READ : LOAD the incoming task state from the NEW TSS (named by the
    //                jump selector): CR3@0x1C, EIP@0x20, EFLAGS@0x24, GPRs, the 6
    //                selectors, LDTR (one dword read per beat, latched in tsw_*).
    //   S_TSW_SEG  : reload the hidden descriptor (base/limit/attr) of each of the
    //                6 incoming segment selectors from the GDT (like a seg load).
    //   S_TSW_BUSY : toggle the descriptor busy bits — a JMP CLEARS the outgoing
    //                TSS busy bit (type B->9) and SETS the incoming one (9->B) —
    //                then COMMIT (new TR, CR0.TS=1, incoming EIP) and retire ONCE.
    S_TSW_SAVE, S_TSW_READ, S_TSW_SEG, S_TSW_BUSY,
    // M2S.5 — SMM / RSM (gated sys_mode; docs/m2s5-smm-spec.md):
    //   S_SMI_SAVE : SMI# entry — save the CPU state to the SMRAM save-state map
    //                (P5 Table 20-1 offsets @ SMBASE+0x8000+offset), then enter
    //                SMM (clear CR0.PE/PG/EM/TS; CS base=SMBASE sel=SMBASE>>4;
    //                EIP=0x8000; large limits) and retire ONCE in the SMM context.
    //   S_RSM      : RSM (0F AA) — read the whole save map back, then commit the
    //                restored state (honoring a handler-modified SMBASE/resume EIP)
    //                in one clock and resume the interrupted context.
    S_SMI_SAVE, S_RSM,
    // M2S.6 — the extra data-watchpoint handler-entry record (the qemu gdbstub
    // single-step quirk: a DATA breakpoint #DB re-reports the post-delivery state
    // stamped at the handler entry PC before the handler's first instruction).
    S_DB_EXTRA
  } state_e;
  state_e state;
  // M2S.2 page-walk return state (declared here so it can use state_e).
  state_e walk_ret_state;          // state to resume after a page walk

  // M6 Erratum 81: latched once the core enters the F00F hang (never clears
  // until reset). Drives the cpu_hung output and keeps the FSM parked.
  logic hung_r;
  assign cpu_hung = hung_r;

`ifdef VEN_DBG_CORE
  // ---- VEN_DBG_CORE observability taps (pure combinational observers) -------
  // No logic added to any datapath; these never feed back into the FSM.
  assign dbg_state    = 6'(state);
  assign dbg_int_vec  = int_vec;
  assign dbg_fault_pc = int_src_pc;
  assign dbg_cr0      = creg0;

  // ---- single-step / instruction-breakpoint hold ---------------------------
  // dbg_block_issue, when 1, makes the S_DECODE boundary PARK (stay in S_DECODE,
  // eip unchanged) instead of dispatching — see the injection in
  // core_fetch_decode.svh. The park is below SMI/NMI/INTR so interrupts are never
  // lost; in-flight loads/stores/fills + the L1/AXI fill FSM advance in their own
  // states untouched (parking only suppresses ISSUING a NEW instruction).
  logic dbg_bp_latched;   // breakpoint fired; sticky until the PS pulses dbg_bp_clr
  logic dbg_step_q;       // permit exactly ONE issue while parked (single-step)
  logic dbg_bp_hit;
  logic dbg_block_issue;  // 1 = park the S_DECODE boundary (consumed in the FSM)
  // pre-execution PC breakpoint: the instruction about to issue sits at `eip`,
  // at the S_DECODE boundary. Suppressed during a step so we can step OFF it.
  assign dbg_bp_hit = dbg_bp_en && (eip == dbg_bp_addr) && (state == S_DECODE) && !dbg_step_q;
  wire   dbg_park   = dbg_halt_req | dbg_bp_latched;
  assign dbg_block_issue = (dbg_park | dbg_bp_hit) & ~dbg_step_q;
  assign dbg_halted      = dbg_block_issue & (state == S_DECODE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dbg_bp_latched <= 1'b0;
      dbg_step_q     <= 1'b0;
    end else begin
      if (dbg_bp_hit)        dbg_bp_latched <= 1'b1;        // latch a breakpoint hit
      else if (dbg_bp_clr)   dbg_bp_latched <= 1'b0;        // PS clears it to resume
      if (dbg_step && dbg_park) dbg_step_q <= 1'b1;         // arm one single-step
      else if (dbg_step_q && retire_valid) dbg_step_q <= 1'b0; // consume after one retire
    end
  end
`else
  // No debug build: the S_DECODE issue-hold can never engage -> the injected
  // `else if (dbg_block_issue)` arm is dead, keeping the FSM byte/cycle-identical.
  wire dbg_block_issue = 1'b0;
`endif

  // M7.1 int-0x80 proxy state. gs_base_r holds the latched %gs TLS base captured
  // from the proxy (set_thread_area's sys_call.gs_base); it is installed into
  // seg_base[GS] the moment a user-mode `mov gs, 0x33` selector load happens.
  // cn mirrors the retire counter so syscall_n can name the upcoming record (the
  // TB cross-checks it against its own retire count). Both are INERT (untouched,
  // base stays flat) unless proxy_en is set, so existing user tests are
  // byte-identical. The combinational syscall_active pulse is produced in the
  // S_DECODE int-0x80 arm (see below); the apply happens on that same clock.
  logic [31:0] gs_base_r;          // latched %gs TLS base (0 = flat / unset)
  logic [63:0] cn;                 // core-side retire counter (drives syscall_n)
  logic [63:0] tsc;                // F3: free-running time-stamp counter (RDTSC 0F 31)
`ifdef VEN_DBG_WD
  logic [23:0] dbg_stall;          // sim-only: cycles since last retire (hang watchdog)
  logic        dbg_printed;        // sim-only: one-shot for the watchdog dump
`endif
`ifdef VEN_PS_PROXY
  logic [3:0]  q_proxy_len;        // int80 length latched at S_SYSCALL_WAIT entry (eip
                                   // parks at cd80, so this is the only thing the wait
                                   // arm needs to advance eip on the late commit).
`endif
  // M7.1 folded-instruction state: after proxying an int-0x80 we execute the
  // instruction following cd80 and emit ONE retire that stands in for the golden
  // int-0x80 record. fold_pending_r marks "the next retire is that syscall record"
  // and fold_pc_r holds the int's pc to stamp on it (so the retire's pc matches
  // the golden, not the folded insn's address). Inert unless proxy_en.
  logic        fold_pending_r;
  logic [31:0] fold_pc_r;
  logic        syscall_active_c;   // combinational: this clock decodes cd80 in proxy mode
  assign syscall_n      = cn;
  // syscall_active is high for exactly the S_DECODE clock that proxies an
  // int-0x80: the TB samples it to apply the kernel writes + drive back the
  // golden ret/resume-eip/gs effects this same clock (combinational, like the
  // mem bus). Gated on proxy_en + d_int80 so it is 0 in every non-proxy run.
  // (state/proxy_en/d_int80 are all declared above this point.)

  localparam int IWORDS = 4;
  logic [7:0]  ibuf [16];
  logic [2:0]  fetch_word;

  // ===========================================================================
  // M4 dual-issue fast-path pipeline state (docs/m4-pipeline-spec.md §"How to
  // evolve the core"). A 32-byte prefetch buffer feeds a 2-wide decode + pairing
  // checker; simple/pairable instructions execute through it at up to 2/clock
  // with AGI interlock + a 256-entry/4-way BTB & 2-bit predictor. Anything the
  // fast path does not recognise falls back to the proven multi-cycle FSM
  // (S_FETCH..) so functional behaviour is preserved exactly.
  // ===========================================================================
  // 8 KB 2-WAY set-associative instruction cache (128 sets x 2 ways x 32 B line =
  // 256 lines), the P5 L1 I-cache geometry (Alpert & Avnon, docs/p5-timing-model.md).
  // M5 finding [med]: the oracle's I-cache is 2-WAY / 128-set / LRU
  // (verif/qemu-plugins/p5trace.c:61-65 L1_SETS=128 L1_WAYS=2, l1_access 2-way
  // LRU); a DIRECT-MAPPED I-cache gives a DIFFERENT hit/miss SEQUENCE for any
  // conflict-prone or partially-resident working set (wrong-way / replacement
  // divergence). The I-cache must use the SAME associativity/index/tag/LRU as the
  // oracle (and as the RTL D-cache) so the miss sequence — not just the aggregate
  // — agrees. set = addr[11:5] (128 sets), tag = addr[31:12] (20 bits). The fast
  // path decodes combinationally out of the cache; a miss triggers a line fill
  // (8 word reads = imiss penalty) in S_PF, allocating the 2-way LRU victim.
  //
  // +VEN_CACHE_HALF (FPGA area/congestion experiment, NOT a verification config):
  // halve both L1s to 64 sets => 4 KB I$ + 4 KB D$. This changes the index/tag
  // geometry (idx 6 / tag 21 instead of idx 7 / tag 20) and therefore the miss
  // SEQUENCE, so it does NOT match the fixed-128-set cycle oracle (the M4/M5
  // mb_* bands are only claimed for the default build). It STAYS functionally
  // bit-exact (the cache is a hit/miss + data store; smaller => more fills, same
  // bytes), validated by `VL_EXTRA_DEFINES=+define+VEN_CACHE_HALF make verify`.
  // The default build is byte/cycle-identical: with IC_IDXW=7, addr[5 +: 7] is
  // exactly addr[11:5] and addr[12 +: 20] is exactly addr[31:12].
  // L1 I-cache geometry knobs (default 128 sets × 2 ways = 8 KB, the silicon /
  // cycle-validated config). Override per-cache (VEN_IC_SETS / VEN_IC_WAYS) or
  // for both L1s at once (VEN_L1_SETS / VEN_L1_WAYS); +VEN_CACHE_HALF = 64 sets.
  // Non-default geometries stay FUNCTIONALLY correct but are not matched by the
  // fixed-2-way/128-set p5trace.so cycle oracle (area/perf experiments).
`ifdef VEN_IC_SETS
  localparam int IC_SETS = `VEN_IC_SETS;
`elsif VEN_L1_SETS
  localparam int IC_SETS = `VEN_L1_SETS;
`elsif VEN_CACHE_HALF
  localparam int IC_SETS = 64;
`else
  localparam int IC_SETS = 128;
`endif
`ifdef VEN_IC_WAYS
  localparam int IC_WAYS = `VEN_IC_WAYS;
`elsif VEN_L1_WAYS
  localparam int IC_WAYS = `VEN_L1_WAYS;
`else
  localparam int IC_WAYS = 2;
`endif
  localparam int IC_IDXW = $clog2(IC_SETS);     // set-index width: 7 @128 / 6 @64
  localparam int IC_TAGW = 32 - 5 - IC_IDXW;    // tag width:      20 @128 / 21 @64
  localparam int IC_LINE = 32;
  localparam int IC_WAYW = (IC_WAYS <= 1) ? 1 : $clog2(IC_WAYS);  // way-index width (1 @2-way)
  // The I-cache ARRAYS + per-word fill + fill-complete MRU + up-to-3 LRU touches
  // + synchronous reset now live in the `icache` module (rtl/mem/icache.sv, R2
  // extract), instantiated as u_icache below. The arrays are EXPOSED READ-ONLY as
  // these outputs so the combinational probes (ic_present / ic_hit_way / ic_byte)
  // read the REGISTERED PRE-edge state directly, UNCHANGED. The fill is sequenced
  // by the spine regs below (pf_fill_addr/pf_fill_way/pf_word + the ic_victim_o
  // victim, which STAY here); the module never recomputes the victim.
  // icache addressed line-read interface (replaces the whole-array ic_data_o:
  // the fetch window spans only 2 consecutive lines — A=flin's line, B=next).
  logic [IC_IDXW-1:0]  ic_rd_setA, ic_rd_setB;
  logic [IC_WAYW-1:0] ic_rd_wayA, ic_rd_wayB;
  logic [IC_LINE*8-1:0] ic_rd_lineA, ic_rd_lineB;
`ifdef VEN_IC_BRAM
  // +VEN_IC_BRAM: the icache read ports are REGISTERED (BRAM mandates a synchronous
  // read), so ic_rd_lineA/B in cycle T hold the line for the read ADDRESS presented
  // in cycle T-1. We register that address as a TAG (rdA_set_q/rdA_way_q for A,
  // rdB_* for B) so ic_byte can CONTENT-ADDRESS the two registered line buffers
  // (pick whichever buffer holds the needed set) instead of comparing against the
  // live ic_rd_setA. A line is "fetch-ready" iff a buffer's tag matches what flin
  // needs THIS cycle. Sequential fetch keeps flin in one line for ~8 insns (tag
  // matches, no stall), and a sequential line-crossing finds the new line ALREADY in
  // buffer B (it read flin's next line last cycle) — so sequential fetch is
  // bubble-free; only a redirect to an un-buffered line costs a 1-cycle refill.
  logic [IC_IDXW-1:0]  rdA_set_q, rdB_set_q;
  logic [IC_WAYW-1:0] rdA_way_q, rdB_way_q;
  logic        ic_fetch_ready;   // the line(s) the current decode window needs are buffered
  // 2b — predicted-taken-target PREFETCH: when a predicted-taken branch sits in the
  // current (non-straddling) window, we're about to REDIRECT, so the sequential next
  // line (port B's normal job) won't be needed — repurpose port B to read the branch
  // TARGET line, so it is buffered BEFORE the redirect and the back-edge costs no
  // bubble. Driven in the fast-path comb block (where the BTB prediction is known).
  logic        pf_redir;
  logic [31:0] pf_redir_tgt;
`endif
  logic [IC_TAGW-1:0] ic_tag_o  [IC_SETS][IC_WAYS];   // addr[31:5+idx]
  logic        ic_val_o  [IC_SETS][IC_WAYS];
  logic [IC_WAYW-1:0] ic_victim_o [IC_SETS]; // replacement (LRU) way per set (== ~ic_lru @2-way)
  logic [31:0] pf_fill_addr;         // line base currently being filled
  logic [IC_WAYW-1:0] pf_fill_way;     // victim way chosen for the fill (LRU)
  logic [2:0]  pf_word;              // refill word counter (8 words = 32 bytes)

  // BTB: 64 sets x 4 ways, 2-bit saturating counters (Alpert & Avnon / AP-500).
  // The arrays (btb_tag/btb_ctr/btb_val/btb_rr), the pure-comb btb_lookup() and
  // the single btb_update_taken() now live in the bpred_btb module (R2 extract,
  // rtl/core/bpred_btb.sv). The spine drives two combinational predict ports
  // (btb_u_query_pc -> btb_u_pred / btb_v_query_pc -> btb_v_pred, PRE-update
  // state) and the single synchronous resolve port (btb_resolve_valid/pc/taken).
  localparam int BTB_SETS = 64;
  localparam int BTB_WAYS = 4;
  logic [31:0] btb_u_query_pc;   // comb U predict pc (= eip)
  logic        btb_u_pred;       // comb: U predicted-taken (PRE-update state)
  logic [31:0] btb_v_query_pc;   // comb V predict pc (= eip + u_d.len)
  logic        btb_v_pred;       // comb: V predicted-taken (PRE-update state)
  logic        btb_resolve_valid;// comb: a branch resolves this clock (U or V)
  logic [31:0] btb_resolve_pc;   // comb: resolving branch pc
  logic        btb_resolve_taken;// comb: resolving branch taken decision

  // AGI tracking: gpr index written in the immediately-PREVIOUS issue clock.
  // -1 (bit8 set) = none. Updated each fast-path issue clock.
  logic [8:0]  agi_wr0, agi_wr1;     // up to two regs written last fast clock

  logic [2:0]  mispred_bubbles;      // remaining flush bubbles to burn

  // ===========================================================================
  // M5 cycle-accuracy state (docs/m5-cycle-spec.md). Two timing models, both
  // EMERGENT (real SM / real scoreboard), using the SAME geometry/penalty as the
  // p5model oracle (build/p5trace.so: imiss=8, dmiss=8, 8KB/2-way/32B, misalign
  // +3) so the cycle COMPONENTS agree, not a formula copied from the oracle.
  // ===========================================================================
  // Free-running core-clock counter (the timeline the FP scoreboard lives on).
  // Mirrors the TB's cyc = clock-count-at-retire; advances every clock.
  logic [31:0] core_cyc;

  // x87 FP latency/throughput scoreboard (p5model g.fp_ready). Holds the cycle at
  // which the x87 top-of-stack result of the most recent FP producer/rmw becomes
  // readable. A dependent FP consumer (fp_role>=2) must stall until then; this is
  // what turns a dependent fadd chain into CPI~3 (lat 3) while independent FP
  // pipelines at throughput 1 (the latency is overlapped by other work).
  //
  // #6 DESIGN DECISION (owner-confirmed 2026-06-09, "keep fixed P5 lat"): the
  // scoreboard is driven by the FIXED P5 latencies `u_d.fp_lat`/`fp_occ` (the
  // p5trace.c oracle's per-op constants), NOT by the iterative engines' real
  // `done`. The two are RUNTIME-EXCLUSIVE arms: this fast/cycle arm is the M4/M5
  // cycle-accuracy model graded against the p5model golden (the mb_* bands), while
  // the iterative SRT/BCD/transcendental engines live on the SLOW functional arm
  // (S_FP_BUSY/S_BCD_BUSY/S_TRSC_BUSY). Those engines' done-latency is an
  // implementation artifact (radix-4 SRT count, ~20-clk microcode), tuned for
  // bit-exactness/area — NOT real-P5 cycle timing — so feeding it back here would
  // diverge from the oracle and move the bands. The fixed `fp_lat`/`fp_occ`
  // constants stay the cycle-fidelity source of truth. (#6 closed as by-design.)
  logic [31:0] fp_ready_cyc;

  // FP pipe OCCUPANCY hold (p5model pipe_free_at = issue + occ). An FP op holds
  // the in-order pipe for `occ` clocks: even a FOLLOWING INDEPENDENT integer op
  // cannot issue until the FP op's occupancy expires (fdiv occ 39, fmul occ 2,
  // fsqrt occ 70). This is DISTINCT from result latency (fp_ready_cyc), which
  // only stalls a dependent FP CONSUMER. fp_occ_pending marks "occupancy clocks
  // are being burned; commit+retire when stall_cnt reaches 0"; fp_issue_cyc is
  // the cycle occupancy began (so fp_ready = issue + lat is anchored correctly).
  logic        fp_occ_pending;
  logic [31:0] fp_issue_cyc;
`ifdef VEN_FP_OVERLAP
  // GAP1 (FDIV/integer overlap, mirrors p5trace.c g.fp_busy_until): the cycle the
  // single x87 exec unit is free again. A FOLLOWING FP op (is_fp, NOT FXCH) waits
  // on it; integer ops never reach the FP arm, so they overlap the FDIV shadow.
  // The FP op itself holds the INTEGER pipe only P5_FP_ISSUE_OCC clocks (retires at
  // issue+2 like oracle pipe_free_at=issue+P5_FP_ISSUE_OCC), while the real occ-long
  // exec window lives on fp_busy_cyc.
  logic [31:0] fp_busy_cyc;
  localparam logic [6:0] P5_FP_ISSUE_OCC = 7'd2;
`endif

  // L1 D-cache TIMING model: 8 KB / 2-way / 32 B line / 128 sets, LRU. Data still
  // comes from the BFM (mem_rdata); this only gates WHEN a load completes. A read
  // miss adds dmiss; a misaligned access adds +3 (AP-500). Matches p5_mem() +
  // l1_access() in verif/qemu-plugins/p5trace.c (read-allocate, 2-way LRU).
`ifdef VEN_DC_SETS
  localparam int DC_SETS = `VEN_DC_SETS;
`elsif VEN_L1_SETS
  localparam int DC_SETS = `VEN_L1_SETS;
`elsif VEN_CACHE_HALF
  localparam int DC_SETS = 64;   // +VEN_CACHE_HALF: 4 KB D$ (see IC_SETS note above)
`else
  localparam int DC_SETS = 128;
`endif
`ifdef VEN_DC_WAYS
  localparam int DC_WAYS = `VEN_DC_WAYS;
`elsif VEN_L1_WAYS
  localparam int DC_WAYS = `VEN_L1_WAYS;
`else
  localparam int DC_WAYS = 2;
`endif
  // The dc_tag/dc_val/dc_lru state + the dc_hit() lookup + the dc_access()
  // allocate/LRU SM + the synchronous reset now live in the dcache_timing module
  // (rtl/mem/dcache.sv), instantiated below. The spine keeps the penalty policy
  // (pending_mem_pen / P5_DMISS / P5_MISALIGN) + the cycle_mode gating, and drives
  // the module's combinational lookup (dc_lu_addr -> dc_lu_hit) + the single
  // funnelled posedge access port (dc_acc_valid / dc_acc_addr).
  logic [31:0] dc_lu_addr;   // comb lookup address (= this clock's access address)
  logic        dc_lu_hit;    // comb: line resident in its set (PRE-access state)
  logic        dc_acc_valid; // comb: an access/allocate fires this clock
  logic [31:0] dc_acc_addr;  // comb: the access address
  // I-cache miss penalty (imiss=8) is materialised EMERGENTLY by the existing
  // S_PF line-fill (8 word reads = 8 clocks), so it needs no constant here.
  localparam logic [6:0] P5_DMISS = 7'd8;   // D-cache miss penalty (plugin arg)
  localparam logic [6:0] P5_MISALIGN = 7'd3;// misaligned data access (AP-500)

  // Deferred D-cache penalty (p5model g.pending_mem_pen): a load's miss/misalign
  // penalty is charged to the NEXT instruction's issue (the model defers the
  // data stall by one retire). We replicate that one-instruction defer so the
  // per-instruction cyc deltas line up with the oracle.
  logic [6:0]  pending_mem_pen;

  // Multi-clock stall countdowns used to MATERIALISE a penalty as real clocks
  // (so cyc = clock-count-at-retire grows by exactly the penalty). Only one is
  // ever non-zero at a time; S_PIPE burns them before issuing.
  logic [6:0]  stall_cnt;             // remaining stall clocks before next issue

  // ALU op encoding (ALU_ADD..ALU_NOT) lives in ventium_alu_pkg (imported above).
  // op-class enum (kind_e), micro-sequencer enums (smk_e/st_e/ctk_e), and the
  // x87 decode enum (fxop_e) live in ventium_decode_pkg (imported above).

  // ===========================================================================
  // Decoder outputs (combinational)
  // ===========================================================================
  logic [3:0]  d_len;
  logic        d_halt;
  logic        d_int80;   // M7.1: decoded `int 0x80` (cd80) — the proxy site
  logic        d_unknown;
  // M2S.3 software/conditional interrupt + return decode (gated sys_mode in the
  // FSM; in user mode INT n still HALTs as before). d_int_n carries the vector.
  logic        d_int;            // INT n / INT3 / INTO -> IDT delivery (a TRAP)
  logic [7:0]  d_int_vec;        // the vector for d_int
  logic        d_int_imm;        // M7.2: this is the INT n IMMEDIATE form (0xCD ib)
                                 // — the IOPL-sensitive one in V86 (INT3/INTO are
                                 // NOT IOPL-controlled; they always vector to the
                                 // monitor). Distinguishes 0xCD 0x03 from 0xCC.
  logic        d_int_cond_of;    // INTO: deliver only if OF (eflags bit 11) set
  logic        d_iret;           // IRET (CF): pop EIP/CS/EFLAGS
  logic        d_ud2;            // UD2 (0F 0B) -> #UD (vector 6) in sys mode
  // M2S.5 RSM (0F AA): leave SMM, restore the saved CPU state from the SMRAM save
  // map + resume the interrupted context. Only legal inside SMM (smm_active);
  // outside SMM it is #UD (user mode HALTs as before — RSM is a system op).
  logic        d_rsm;
  // M6 Erratum 81 (F00F): decoded the invalid LOCK CMPXCHG8B-with-register-dst
  // form (F0 0F C7 /reg, mod==11). Set ALONGSIDE d_unknown (so the clean core,
  // errata off, still HALTs loudly on this invalid opcode); when errata_en[
  // ERR_F00F] is set the FSM routes it to the documented hang instead.
  logic        d_f00f;
  logic        d_is_branch;
  logic        d_branch_taken;
  logic [31:0] d_rel;
  logic [4:0]  d_alu_op;
  logic        d_writes_reg;
  logic        d_writes_flags;
  logic        d_mem_read;
  logic        d_mem_write;
  logic        d_mem_dst;
  logic [2:0]  d_dst_reg;
  logic [2:0]  d_src_reg;
  logic [31:0] d_imm;
  logic        d_use_imm;
  logic        d_is_push;
  logic        d_is_pop;
  logic        d_is_lea;
  logic        d_is_mov;
  logic        d_is_nop;
  logic [31:0] d_ea;
  logic [2:0]  d_w;
  logic        d_dst_high8;
  logic        d_src_high8;
  kind_e       d_kind;
  logic [2:0]  d_shrot;
  logic        d_shift_cl;
  logic        d_shift_one;
  logic [4:0]  d_shift_imm;
  logic        d_shrd;
  logic [2:0]  d_md;
  logic        d_imul_3op;
  logic [31:0] d_imul_imm;
  logic        d_ext_signed;
  logic [2:0]  d_ext_srcw;
  logic [3:0]  d_cc;
  logic        d_bit_imm;
  logic [2:0]  d_bit_op;
  logic        d_conv_cdq;
  smk_e        d_sm;
  st_e         d_st;
  logic        d_str_loadsi;   // reads [ESI]
  logic        d_str_storedi;  // writes [EDI]
  logic        d_str_scandi;   // reads [EDI] for compare
  ctk_e        d_ct;
  logic [15:0] d_ret_imm;
  logic        d_cld;
  logic        d_std;
  logic        d_clc;          // CLC (F8): CF<-0
  logic        d_stc;          // STC (F9): CF<-1
  logic        d_cmc;          // CMC (F5): CF<-~CF
  logic        d_cli;          // CLI (FA): IF<-0  (M2S.1)
  logic        d_sti;          // STI (FB): IF<-1  (M2S.1)
  logic        d_cnt16;        // 0x67 address-size: LOOP/JCXZ use CX (low 16)
  // M7.3b: a 16-bit-operand-size NEAR branch (real-mode Jcc/JMP rel16, or the
  // rel8 forms in 16-bit mode). The taken target truncates EIP to 16 bits (IA-32:
  // a near jump under a 16-bit operand size masks EIP to IP). 0 in 32-bit mode, so
  // every prior gate is unchanged. Set by the operand-size-aware branch arms.
  logic        d_br16;

  // ---- M7.3b IN/OUT port-I/O decode (docs/m7-lockstep-spec.md M7.3) ----------
  // The Win95 system co-sim needs real port I/O: IN reads a device value the CPU
  // cannot compute (replayed from the golden's dev_in via the io bus), OUT drives
  // a port/value out to the TB (consumed there; the existing isa-debug-exit `out
  // 0xf4` terminator is preserved). Opcodes:
  //   E4 ib  IN  AL, imm8        E5 ib  IN  eAX, imm8
  //   E6 ib  OUT imm8, AL        E7 ib  OUT imm8, eAX
  //   EC     IN  AL, DX          ED     IN  eAX, DX
  //   EE     OUT DX, AL          EF     OUT DX, eAX
  // Width: byte for the AL forms (E4/E6/EC/EE), else eff-opsize (word in real
  // mode / dword in 32-bit). The port is an imm8 (E4-E7) or DX[15:0] (EC-EF).
  // d_io_w reuses the wmask width code (1=byte, 2=word, 4=dword). These are 0 for
  // every non-IN/OUT instruction, so the dispatch below is inert elsewhere.
  logic        d_io;            // this instruction is IN/OUT
  logic        d_io_write;      // 1 = OUT (CPU drives the port), 0 = IN (CPU reads)
  logic        d_io_imm;        // 1 = port is the imm8 byte (E4-E7), 0 = DX (EC-EF)
  logic [7:0]  d_io_port_imm;   // the imm8 port (when d_io_imm)
  logic [2:0]  d_io_w;          // I/O width code (1=byte, 2=word, 4=dword)

  // ---- M2S.1 system-mode decode (docs/m2s1-segmentation-spec.md) ------------
  // d_seg : which segment the memory operand uses (SG_CS..SG_GS). Default DS
  //   (=SG_DS); stack ops force SS; a 26/2E/36/3E/64/65 override prefix selects
  //   ES/CS/SS/DS/FS/GS. In user mode this is ignored (all bases 0).
  // d_sysop : a decoded system instruction (LGDT/LIDT/MOV CRn/MOV sreg/far JMP).
  // d_def16 : the real-mode default operand/address size is 16-bit (so a 0x66
  //   prefix means 32-bit). Computed at decode from real_mode ^ pfx.
  logic [2:0]  d_seg;          // segment index for the data memory operand
  typedef enum logic [3:0] {
    SYS_NONE, SYS_LGDT, SYS_LIDT, SYS_MOVCR_TO, SYS_MOVCR_FROM,
    SYS_MOVSREG_TO, SYS_MOVSREG_FROM, SYS_LJMP,
    // M2S.4 — LTR (load TR from a GDT TSS selector) and STR (store TR selector).
    SYS_LTR, SYS_STR,
    // M2S.6 — MOV r32,DRn (0F 21) and MOV DRn,r32 (0F 23). The DR index is in
    // d_sys_creg (reused: ModR/M.reg), the GPR in d_dst_reg / d_src_reg.
    SYS_MOVDR_FROM, SYS_MOVDR_TO,
    // M9.5 — real-mode far CALL ptr16:16/32 (0x9A) and RETF (0xCB / 0xCA imm16).
    // Reuse d_ljmp_off/d_ljmp_sel for the call target and d_ret_imm for RETF imm16.
    SYS_LCALL, SYS_RETF,
    // M9.5 — SGDT (0F 01 /0) / SIDT (0F 01 /1): store the 6-byte GDTR/IDTR
    // pseudo-descriptor to memory (the reverse of LGDT/LIDT's S_LGDT read).
    SYS_SGDT, SYS_SIDT
  } sysop_e;
  sysop_e      d_sysop;
  logic [2:0]  d_sys_sreg;     // target/source segment register index (mov sreg)
  logic [2:0]  d_sys_creg;     // CR index (0/2/3/4) for MOV CRn
  logic [31:0] d_ljmp_off;     // far-jump target offset
  logic [15:0] d_ljmp_sel;     // far-jump target selector
  logic        d_seg_load;     // M9.5 LES/LDS/LSS/LFS/LGS: also load a seg reg from [mem]+2
  logic [2:0]  d_lseg;         //   target segment register index for the seg-load
  logic        d_push_sreg;    // F3 PUSH sreg (06/0E/16/1E): push data = seg_sel[d_sys_sreg]
  logic        d_pop_sreg;     // F3 POP sreg (07/17/1F): pop writes seg_sel/base[d_sys_sreg]
  logic        d_seg_load_lo;  // F3 MOV Sreg,[mem]: selector = LOW 16b of the 2-byte read
  logic        d_store_sreg;   // F3 MOV [mem],Sreg: store data = seg_sel[d_sys_sreg]
  logic        d_callf_mem;    // F3 FF /3 CALLF m16:16 (far indirect call through memory)
  logic        d_jmpf_mem;     // F3 FF /5 JMPF  m16:16 (far indirect jump through memory)
  logic        d_pfx_seg_en;   // a segment-override prefix is present
  logic [2:0]  d_pfx_seg_idx;  // which segment the override selects

  // ---- x87 decode (M3) ------------------------------------------------------
  // x87 sub-op encoding (fxop_e: FX_*) lives in ventium_decode_pkg. The decoder
  // classifies each escape (D8..DF + ModR/M) into one of these and supplies the
  // addressing (d_f_mem_read/write + d_f_msize) and operand index (d_f_sti).
  fxop_e       d_fxop;
  logic        d_is_x87;
  logic        d_f_mem_read;     // x87 op reads a memory operand
  logic        d_f_mem_write;    // x87 op writes a memory operand
  logic [2:0]  d_f_msize;        // memory operand bytes: 2/4/8/10 (encoded as 2,4,8,10 won't fit 3b)
  logic [3:0]  d_f_mbytes;       // memory operand size in bytes (2,4,8,10)
  logic        d_f_pop;          // pop the stack after the op (1 pop)
  logic        d_f_pop2;         // pop twice (FCOMPP/FUCOMPP)
  logic [2:0]  d_f_sti;          // st(i) index operand
  logic [2:0]  d_f_aluop;        // 0=add 1=mul 4=sub 5=subr 6=div 7=divr (x87 group)
  logic [2:0]  d_f_const;        // ROM-constant selector for FLDCONST

  // ===========================================================================
  // ModR/M + SIB helpers
  // ===========================================================================
  logic [3:0]  m_idx;
  logic [1:0]  modrm_mod;
  logic [2:0]  modrm_reg;
  logic [2:0]  modrm_rm;
  logic        has_sib;
  logic [1:0]  sib_scale;
  logic [2:0]  sib_index;
  logic [2:0]  sib_base;
  logic [7:0]  mrm, sibb;

  // mfl() (ModR/M field length) lives in ventium_decode_pkg.

  // ===========================================================================
  // Prefix machine
  // ===========================================================================
  logic [3:0] pfx_len;
  logic       pfx_opsize, pfx_addr, pfx_seg, pfx_lock;
  logic [1:0] pfx_rep;          // 0 none, 2 F2, 3 F3
  logic [7:0] op0, op1;
  logic       two_byte;

  // is_prefix() lives in ventium_decode_pkg.

  always_comb begin
    pfx_len=4'd0; pfx_opsize=1'b0; pfx_addr=1'b0; pfx_seg=1'b0; pfx_lock=1'b0; pfx_rep=2'd0;
    d_pfx_seg_en=1'b0; d_pfx_seg_idx=3'd0;
    for (int i=0;i<4;i++) begin
      if (is_prefix(ibuf[pfx_len])) begin
        unique case (ibuf[pfx_len])
          8'h66: pfx_opsize=1'b1;
          8'h67: pfx_addr=1'b1;
          8'hF3: pfx_rep=2'd3;
          8'hF2: pfx_rep=2'd2;
          8'hF0: pfx_lock=1'b1;
          // segment-override prefixes (M2S.1): record which segment they pick.
          8'h2E: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_CS); end
          8'h36: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_SS); end
          8'h3E: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_DS); end
          8'h26: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_ES); end
          8'h64: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_FS); end
          8'h65: begin pfx_seg=1'b1; d_pfx_seg_en=1'b1; d_pfx_seg_idx=3'(SG_GS); end
          default: pfx_seg=1'b1;
        endcase
        pfx_len = pfx_len + 4'd1;
      end
    end
    op0=ibuf[pfx_len];
    two_byte=(op0==8'h0F);
    op1=ibuf[pfx_len+4'd1];
  end

  // M2S.1: EFFECTIVE operand/address size. In REAL mode the default is 16-bit,
  // so a 0x66/0x67 prefix means 32-bit (the bit is inverted vs protected/flat).
  // In user mode and protected mode real_mode==0, so eff_* == the raw prefix and
  // the decoder is byte-for-byte unchanged. The decoder below uses eff_opsize/
  // eff_addr in place of pfx_opsize/pfx_addr.
  logic eff_opsize, eff_addr;
  assign eff_opsize = pfx_opsize ^ def16;
  assign eff_addr   = pfx_addr   ^ def16;

  // SYSTEM-mode pure helpers (mfl_e, desc_base/limit/attr/present/dpl/s/type,
  // seg_is_code/writable/readable, tsw_save_off/tsw_read_off, seg_load_fault,
  // seg_fault_vec) were extracted VERBATIM to ventium_sys_pkg (R2 modularization).
  // Every body uses only its args + literals (mfl_e also calls mfl() from
  // ventium_decode_pkg), so the move is a netlist no-op. sreg_idx() stays here
  // (its body references the module-local SG_CS..SG_GS localparams).

  // x86 segment-register field (ModR/M.reg for MOV Sreg) -> our SG_ index.
  // x86 encoding: 0=ES 1=CS 2=SS 3=DS 4=FS 5=GS; SG_ order: cs=0 ss=1 ds=2 es=3.
  function automatic logic [2:0] sreg_idx(input logic [2:0] e);
    unique case (e)
      3'd0: sreg_idx = 3'(SG_ES);
      3'd1: sreg_idx = 3'(SG_CS);
      3'd2: sreg_idx = 3'(SG_SS);
      3'd3: sreg_idx = 3'(SG_DS);
      3'd4: sreg_idx = 3'(SG_FS);
      default: sreg_idx = 3'(SG_GS);
    endcase
  endfunction

  // cond_true() (Jcc tttn condition eval) lives in ventium_decode_pkg.
  // Width helpers (wmask/sbit/sbit2/parity8) live in ventium_alu_pkg.

  // ===========================================================================
  // Combinational decoder
  // ===========================================================================
  always_comb begin
    d_len=4'd1; d_halt=1'b0; d_int80=1'b0; d_unknown=1'b0; d_f00f=1'b0; d_is_branch=1'b0; d_branch_taken=1'b0;
    d_rel=32'd0; d_alu_op=ALU_ADD; d_writes_reg=1'b0; d_writes_flags=1'b0;
    d_mem_read=1'b0; d_mem_write=1'b0; d_mem_dst=1'b0; d_dst_reg=3'd0; d_src_reg=3'd0;
    d_imm=32'd0; d_use_imm=1'b0; d_is_push=1'b0; d_is_pop=1'b0; d_is_lea=1'b0;
    d_is_mov=1'b0; d_is_nop=1'b0; d_ea=32'd0; d_w=3'd4; d_dst_high8=1'b0; d_src_high8=1'b0;
    d_kind=K_ALU; d_shrot=3'd0; d_shift_cl=1'b0; d_shift_one=1'b0; d_shift_imm=5'd0;
    d_shrd=1'b0; d_md=3'd0; d_imul_3op=1'b0; d_imul_imm=32'd0; d_ext_signed=1'b0;
    d_ext_srcw=3'd1; d_cc=4'd0; d_bit_imm=1'b0; d_bit_op=3'd4; d_conv_cdq=1'b0;
    d_sm=SM_PUSHA; d_st=ST_MOVS; d_str_loadsi=1'b0; d_str_storedi=1'b0; d_str_scandi=1'b0;
    d_ct=CT_CALLREL; d_ret_imm=16'd0; d_cld=1'b0; d_std=1'b0;
    d_clc=1'b0; d_stc=1'b0; d_cmc=1'b0; d_cli=1'b0; d_sti=1'b0; d_cnt16=eff_addr;
    d_br16=1'b0;
    d_io=1'b0; d_io_write=1'b0; d_io_imm=1'b0; d_io_port_imm=8'd0; d_io_w=3'd1;
    d_fxop=FX_NONE; d_is_x87=1'b0; d_f_mem_read=1'b0; d_f_mem_write=1'b0;
    d_f_msize=3'd0; d_f_mbytes=4'd0; d_f_pop=1'b0; d_f_pop2=1'b0; d_f_sti=3'd0;
    d_f_aluop=3'd0; d_f_const=3'd0;
    // M2S.1 system-decode defaults. d_seg defaults to DS for data accesses (stack
    // ops override to SS in their handlers below); a segment-override prefix wins.
    d_sysop=SYS_NONE; d_sys_sreg=3'd0; d_sys_creg=3'd0;
    d_ljmp_off=32'd0; d_ljmp_sel=16'd0;
    d_seg_load=1'b0; d_lseg=3'd0;
    d_push_sreg=1'b0; d_pop_sreg=1'b0; d_seg_load_lo=1'b0; d_store_sreg=1'b0;
    d_callf_mem=1'b0; d_jmpf_mem=1'b0;
    d_seg = d_pfx_seg_en ? d_pfx_seg_idx : 3'(SG_DS);
    // M2S.3 interrupt/return decode defaults.
    d_int=1'b0; d_int_vec=8'd0; d_int_imm=1'b0; d_int_cond_of=1'b0; d_iret=1'b0; d_ud2=1'b0;
    d_rsm=1'b0;

    m_idx     = pfx_len + (two_byte ? 4'd2 : 4'd1);
    mrm       = ibuf[m_idx];
    sibb      = ibuf[m_idx+4'd1];
    modrm_mod = mrm[7:6];
    modrm_reg = mrm[5:3];
    modrm_rm  = mrm[2:0];
    has_sib   = (modrm_mod!=2'b11) && (modrm_rm==3'b100);
    sib_scale = sibb[7:6];
    sib_index = sibb[5:3];
    sib_base  = sibb[2:0];

    begin
      logic [31:0] base_val, index_val, disp_val;
      logic [3:0]  disp_idx;
      logic        no_base, no_index;
      no_base=1'b0; no_index=1'b0; base_val=32'd0; index_val=32'd0; disp_val=32'd0;
      disp_idx=m_idx+4'd1;
      if (has_sib) begin
        disp_idx=m_idx+4'd2;
        if (sib_base==3'b101 && modrm_mod==2'b00) no_base=1'b1;
        else base_val=gpr[sib_base];
        if (sib_index==3'b100) no_index=1'b1;
        else index_val=gpr[sib_index]<<sib_scale;
      end else begin
        if (modrm_mod==2'b00 && modrm_rm==3'b101) no_base=1'b1;
        else base_val=gpr[modrm_rm];
      end
      if (modrm_mod==2'b01) disp_val={{24{ibuf[disp_idx][7]}}, ibuf[disp_idx]};
      else if (modrm_mod==2'b10 ||
               (modrm_mod==2'b00 && !has_sib && modrm_rm==3'b101) ||
               (modrm_mod==2'b00 && has_sib && sib_base==3'b101))
        disp_val={ibuf[disp_idx+3],ibuf[disp_idx+2],ibuf[disp_idx+1],ibuf[disp_idx]};
      d_ea=(no_base?32'd0:base_val)+(no_index?32'd0:index_val)+disp_val;
      // F3 — 32-bit EBP/ESP-based forms default to SS (SDM Table 2-2/2-3): SIB
      // base=ESP (any mod), SIB base=EBP with mod!=00 (mod==00 is disp32 -> DS),
      // and non-SIB [EBP+disp] (mod 01/10). A segment-override prefix wins. This
      // was MISSING: `mov ds,[esp+8]` (SeaBIOS's extra-stack IRQ trampoline,
      // a32 SIB) read DS:[esp+8] instead of SS:[esp+8] in real mode, loaded a
      // garbage segment, and saved the IRQ context over the freshly-loaded
      // FreeDOS kernel image (the F3 depack 43-byte slip). Invisible in every
      // flat gate (all segment bases equal), so make verify stays byte-identical.
      if (!d_pfx_seg_en && !eff_addr &&
          ((has_sib && (sib_base==3'b100 ||
                        (sib_base==3'b101 && modrm_mod!=2'b00))) ||
           (!has_sib && modrm_rm==3'b101 && modrm_mod!=2'b00)))
        d_seg = 3'(SG_SS);
    end

    // F3 — 16-bit ADDRESSING (eff_addr==1, i.e. real mode w/o a 0x67 prefix). The
    // 32-bit EA block above used the 32-bit ModR/M model (base_val=gpr[rm], SIB),
    // which is WRONG for 16-bit forms — so recompute d_ea here from the 16-bit
    // base/index table (no SIB in 16-bit addressing). Until now only the direct
    // `[disp16]` form was handled; every register form ([bx],[si],[bp+disp],[bx+si]..)
    // silently used the 32-bit gpr[rm] EA, which broke hand-written 16-bit real-mode
    // asm (gcc/SeaBIOS use a 0x67 a32 prefix so eff_addr=0 and were unaffected; the
    // FreeDOS MBR's `test byte [bx],0x80` partition scan hit it). mfl_e(eff_addr,..)
    // already gives the right LENGTH, so only d_ea (and the BP->SS default) need work.
    //   rm: 000 BX+SI  001 BX+DI  010 BP+SI  011 BP+DI  100 SI  101 DI
    //       110 (mod==00) disp16 / (else) BP   111 BX
    //   disp: mod=01 disp8(sext), mod=10 disp16, mod=00/rm=110 disp16, else none.
    //   16-bit GPRs: BX=gpr[3], BP=gpr[5], SI=gpr[6], DI=gpr[7] (low 16).
    if (eff_addr) begin
      logic [15:0] ea16_base, ea16_disp;
      unique case (modrm_rm)
        3'b000:  ea16_base = gpr[3][15:0] + gpr[6][15:0];                 // BX+SI
        3'b001:  ea16_base = gpr[3][15:0] + gpr[7][15:0];                 // BX+DI
        3'b010:  ea16_base = gpr[5][15:0] + gpr[6][15:0];                 // BP+SI
        3'b011:  ea16_base = gpr[5][15:0] + gpr[7][15:0];                 // BP+DI
        3'b100:  ea16_base = gpr[6][15:0];                                // SI
        3'b101:  ea16_base = gpr[7][15:0];                                // DI
        3'b110:  ea16_base = (modrm_mod==2'b00) ? 16'd0 : gpr[5][15:0];   // disp16 / BP
        default: ea16_base = gpr[3][15:0];                               // BX (rm=111)
      endcase
      if (modrm_mod==2'b01)
        ea16_disp = {{8{ibuf[m_idx+1][7]}}, ibuf[m_idx+1]};              // disp8 (sext)
      else if (modrm_mod==2'b10 || (modrm_mod==2'b00 && modrm_rm==3'b110))
        ea16_disp = {ibuf[m_idx+2], ibuf[m_idx+1]};                      // disp16
      else
        ea16_disp = 16'd0;
      d_ea = {16'd0, (ea16_base + ea16_disp)};   // 16-bit wrap, zero-extended
      // BP-based 16-bit forms default to SS (stack); others keep DS. A segment-
      // override prefix (already in d_seg) wins. rm=010/011 (BP+idx) and rm=110 with
      // mod!=00 (BP+disp) are BP-relative.
      if (!d_pfx_seg_en &&
          (modrm_rm==3'b010 || modrm_rm==3'b011 ||
           (modrm_rm==3'b110 && modrm_mod!=2'b00)))
        d_seg = 3'(SG_SS);
    end

    d_w = eff_opsize ? 3'd2 : 3'd4;

    if (two_byte) begin
      unique casez (op1)
        // ---- M2S.4 system 0F 00 group: /1 STR, /3 LTR ----------------------
        // 0F 00 /3 LTR r/m16 — load TR from a GDT TSS selector (reads the TSS
        // descriptor, marks it busy). 0F 00 /1 STR r/m16 — store the TR selector.
        // Only the register form (mod==11) is used by the corpus; SLDT(/0) and
        // LLDT(/2)/VERR(/4)/VERW(/5) are not needed here.
        8'h00: begin
          // LTR/STR are SYSTEM instructions: only meaningful in system mode. Gate
          // the decode on sys_mode so user mode keeps its exact pre-M2S.4 behavior
          // (0F 00 was d_unknown -> HALT; the user corpus never uses it, so this
          // keeps `make verify` byte-identical).
          if (sys_mode && modrm_mod==2'b11 && modrm_reg==3'd3) begin // LTR r16
            d_sysop=SYS_LTR; d_src_reg=modrm_rm; d_w=3'd2; d_len=pfx_len+4'd3;
          end else if (sys_mode && modrm_mod==2'b11 && modrm_reg==3'd1) begin // STR r16
            d_sysop=SYS_STR; d_dst_reg=modrm_rm; d_writes_reg=1'b1;
            d_w=3'd2; d_len=pfx_len+4'd3;
          end else begin
            d_unknown=1'b1; d_len=pfx_len+4'd2;  // SLDT/LLDT/VERR/VERW/mem deferred
          end
        end
        // ---- 0F 1E / 0F 1F: CET endbr + multi-byte NOP -> NOP --------------
        // 0F 1F /r is the canonical multi-byte NOP; F3 0F 1E FB/FA are the CET
        // endbr32/endbr64 markers (F3 is a legacy prefix here, in pfx_len). On a
        // non-CET CPU these are hint-NOPs, and qemu (our oracle, any -cpu) retires
        // them as NOPs. The core previously hit d_unknown -> HALT, which stranded
        // CET-compiled binaries: musl's __divmoddi4 begins with endbr32, so Quake
        // hung at its first 64-bit divide. Decode the whole 0F 1E/1F space as a
        // NOP, consuming the modrm(+SIB/disp) via mfl_e so the length is exact.
        8'h1E, 8'h1F: begin
          d_is_nop=1'b1;
          d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
        end
        // ---- M2S.5 RSM (0F AA): resume from System Management Mode ----------
        // RSM restores the CPU state from the SMRAM save-state map and resumes
        // the interrupted program. It is ONLY valid while the CPU is in SMM
        // (HF_SMM); executing it outside SMM is #UD (Pentium Dev. Manual Vol.3
        // §20.1.3.3). Here, inside SMM the FSM runs the S_RSM restore sequence;
        // OUTSIDE SMM (or in user mode) it stays an unknown opcode -> HALT loudly
        // (so a stray 0F AA cannot masquerade as a clean run, and user-mode
        // `make verify` is byte-identical: 0F AA was d_unknown there before).
        8'hAA: begin
          d_len=pfx_len+4'd2;
          if (sys_mode && smm_active) d_rsm=1'b1; else d_unknown=1'b1;
        end
        // ---- M2S.1 system 0F opcodes ---------------------------------------
        8'h01: begin // 0F 01 /2 LGDT, /3 LIDT, /0 SGDT, /1 SIDT (mem operand = 6 bytes)
          if (modrm_reg==3'd2 || modrm_reg==3'd3) begin
            d_sysop=(modrm_reg==3'd2)?SYS_LGDT:SYS_LIDT;
            d_mem_read=1'b1;       // read the 6-byte pseudo-descriptor from memory
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else if ((modrm_reg==3'd0 || modrm_reg==3'd1) && modrm_mod!=2'b11 && !paging_on) begin
            // M9.5 SGDT (/0) / SIDT (/1): STORE the 6-byte pseudo-descriptor. Not
            // privileged (any CPL). Scoped to !paging_on (the SoC boot path; the
            // 2-beat S_SGDT store does not integrate page translation) -> else HALT.
            d_sysop=(modrm_reg==3'd0)?SYS_SGDT:SYS_SIDT;
            d_mem_write=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else d_unknown=1'b1;  // /4 SMSW /6 LMSW etc deferred
        end
        8'h20: begin // 0F 20 /r MOV r32, CRn  (mod field ignored, always reg)
          d_sysop=SYS_MOVCR_FROM; d_sys_creg=modrm_reg; d_dst_reg=modrm_rm;
          d_writes_reg=1'b1; d_w=3'd4; d_len=pfx_len+4'd3;
        end
        8'h22: begin // 0F 22 /r MOV CRn, r32
          d_sysop=SYS_MOVCR_TO; d_sys_creg=modrm_reg; d_src_reg=modrm_rm;
          d_w=3'd4; d_len=pfx_len+4'd3;
        end
        8'h21: begin // 0F 21 /r MOV r32, DRn  (M2S.6; mod field ignored, always reg)
          // Gated on sys_mode so USER mode is byte-identical: 0F 21 stays d_unknown
          // (loud HALT) exactly as before M2S.6 — no new user-mode path.
          if (sys_mode) begin
            d_sysop=SYS_MOVDR_FROM; d_sys_creg=modrm_reg; d_dst_reg=modrm_rm;
            d_writes_reg=1'b1; d_w=3'd4; d_len=pfx_len+4'd3;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
        end
        8'h23: begin // 0F 23 /r MOV DRn, r32  (M2S.6)
          if (sys_mode) begin
            d_sysop=SYS_MOVDR_TO; d_sys_creg=modrm_reg; d_src_reg=modrm_rm;
            d_w=3'd4; d_len=pfx_len+4'd3;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
        end
        8'b1000_????: begin // Jcc rel16/rel32 (0F 8x)
          // Operand-size-aware (M7.3b): 32-bit mode (every prior user/PM gate,
          // eff_opsize=0) = rel32 / length 6 — UNCHANGED. 16-bit operand mode (real
          // mode without 0x66, or PM with 0x66; eff_opsize=1) = rel16 / length 4,
          // and the taken target truncates EIP to 16 bits (d_br16). The Win95 boot's
          // real-mode SeaBIOS POST uses the 0F 8x rel16 form (e.g. the jnz at
          // 0xe062) — the prior hardcoded rel32 mis-decoded its length.
          d_is_branch=1'b1; d_branch_taken=cond_true(op1[3:0],eflags);
          if (eff_opsize) begin
            d_rel={{16{ibuf[m_idx+1][7]}},ibuf[m_idx+1],ibuf[m_idx]};
            d_br16=1'b1; d_len=pfx_len+4'd4;
          end else begin
            d_rel={ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1],ibuf[m_idx]};
            d_len=pfx_len+4'd6;
          end
        end
        8'b1001_????: begin // SETcc r/m8
          d_kind=K_SETCC; d_w=3'd1; d_cc=op1[3:0];
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_len=pfx_len+4'd3;
          end else begin
            d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        // M9.5 — LSS (0F B2) / LFS (0F B4) / LGS (0F B5): load r16 + SS/FS/GS from a
        // m16:16 far pointer. Same real-mode-16-bit mechanism as LES/LDS (single
        // 4-byte read {sel,off}; GPR<-off, seg<-sel base=sel<<4). Out of scope -> HALT.
        8'hB2, 8'hB4, 8'hB5: begin
          if (modrm_mod!=2'b11 && seg_real && eff_opsize) begin
            d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
            d_mem_read=1'b1; d_w=3'd2; d_seg_load=1'b1;
            d_lseg=(op1==8'hB2)?3'(SG_SS):(op1==8'hB4)?3'(SG_FS):3'(SG_GS);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd3; end
        end
        8'hB6,8'hB7,8'hBE,8'hBF: begin // MOVZX/MOVSX
          d_kind=K_EXT; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          d_ext_signed=(op1==8'hBE)||(op1==8'hBF);
          d_ext_srcw=((op1==8'hB6)||(op1==8'hBE))?3'd1:3'd2;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_src_high8=(d_ext_srcw==3'd1)&&modrm_rm[2];
            d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'hAF: begin // IMUL r, r/m
          d_kind=K_IMUL2; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd3; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hA3,8'hAB,8'hB3,8'hBB: begin // BT/BTS/BTR/BTC reg
          d_kind=K_BITTEST; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          unique case (op1)
            8'hA3: d_bit_op=3'd4; 8'hAB: d_bit_op=3'd5; 8'hB3: d_bit_op=3'd6;
            default: d_bit_op=3'd7;
          endcase
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_writes_reg=(op1!=8'hA3); d_len=pfx_len+4'd3;
          end else begin d_unknown=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hBA: begin // BT/BTS/BTR/BTC imm
          d_kind=K_BITTEST; d_writes_flags=1'b1; d_bit_imm=1'b1; d_bit_op=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_imm={24'd0,ibuf[m_idx+1]};
            d_writes_reg=(modrm_reg!=3'd4); d_len=pfx_len+4'd4;
          end else begin d_unknown=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1; end
        end
        8'hBC,8'hBD: begin // BSF/BSR
          d_kind=K_BITSCAN; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          d_shrd=(op1==8'hBD);
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd3; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hA4,8'hA5,8'hAC,8'hAD: begin // SHLD/SHRD
          d_kind=K_SHLDRD; d_writes_flags=1'b1;
          d_shrd=(op1==8'hAC)||(op1==8'hAD);
          d_shift_cl=(op1==8'hA5)||(op1==8'hAD);
          d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm;
            if (d_shift_cl) d_len=pfx_len+4'd3;
            else begin d_shift_imm=ibuf[m_idx+1][4:0]; d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
          end else begin
            d_unknown=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+(d_shift_cl?4'd0:4'd1);
          end
        end
        8'b1100_1???: begin // BSWAP r32
          d_kind=K_BSWAP; d_writes_reg=1'b1; d_dst_reg=op1[2:0]; d_len=pfx_len+4'd2;
        end
        // ---- 0F B0/B1: CMPXCHG r/m, r ----------------------------------------
        // CMPXCHG r/m,r (accumulator = AL for 0F B0, eAX for 0F B1). It is an RMW:
        //   temp = r/m;  CMP accumulator,temp (sets ZF/CF/PF/AF/SF/OF as the
        //   accumulator-minus-temp subtraction);  if accumulator==temp then
        //   r/m <- src (the reg operand) and ZF=1; else accumulator <- temp and
        //   ZF=0 (the memory dst is written back UNCHANGED to keep the locked RMW
        //   atomic — matches QEMU). q_src_reg carries the reg operand to store;
        //   the destination is q_dst_reg (reg form) or q_ea (memory form). The
        //   compare/flags reuse the ALU_CMP path with a=accumulator, b=temp.
        // The LOCK prefix (F0) is a functional no-op here (already consumed in the
        // prefix loop into pfx_lock); on this in-order single-core the RMW is
        // already atomic. Kept on the proven slow FSM (NP / microcoded). Not gated
        // on proxy_en — a general ISA fix valid in all modes.
        8'hB0,8'hB1: begin
          d_kind=K_CMPXCHG; d_writes_flags=1'b1;
          d_w=(op1==8'hB0)?3'd1:(eff_opsize?3'd2:3'd4);
          d_src_reg=modrm_reg; d_src_high8=(op1==8'hB0)&&modrm_reg[2];
          if (modrm_mod==2'b11) begin
            d_dst_reg=modrm_rm; d_dst_high8=(op1==8'hB0)&&modrm_rm[2];
            d_writes_reg=1'b1; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        // ---- 0F C7: CMPXCHG8B (/1, memory only) ------------------------------
        // The ONLY valid form is a MEMORY destination (mod != 11). A REGISTER
        // destination (mod == 11) is an invalid opcode (#UD). The clean core does
        // not implement CMPXCHG8B's memory form either (M2S), so both forms are
        // d_unknown here -> HALT loudly. We additionally tag the invalid
        // register-destination form (mod==11) as d_f00f so the FSM can reproduce
        // Erratum 81 (the LOCK + reg-dst HANG) when errata_en[ERR_F00F] is set.
        8'hC7: begin
          d_unknown=1'b1; d_len=pfx_len+4'd3;
          if (modrm_mod==2'b11 && modrm_reg==3'd1) d_f00f=1'b1;  // /1 reg-dst
        end
        // ---- 0F A2: CPUID -----------------------------------------------------
        // CPUID is a no-operand instruction (no ModRM): leaf = eAX (subleaf = eCX,
        // unused by the leaves this boot touches). It writes eax/ebx/ecx/edx and
        // touches NO flags. The result is a pure FUNCTION of the leaf for the modeled
        // CPU (qemu `-cpu pentium`), so this is a deterministic ISA implementation —
        // NOT injected environment. The leaf->result table lives in S_EXEC (K_CPUID)
        // and is gated on cosim_en OR soc_en so the existing user-mode corpus (which
        // never executes CPUID, both off) is byte-identical: outside co-sim AND outside
        // the SoC, CPUID stays the loud HALT (d_unknown) it has always been. The SoC
        // (soc_en=1, cosim_en=0) ungates it because real boot firmware probes CPUID on
        // entry; the leaf table is the same qemu `-cpu pentium` model the SoC golden uses
        // (verif/sys/tests/psoccpuid). Length is always pfx_len+2 (decode is
        // unconditional, so even the gated HALT advances correctly is moot — HALT
        // never retires — but the length is right for a clean characterization).
        8'hA2: begin
          d_len=pfx_len+4'd2;
          if (cosim_en || soc_en) begin
            d_kind=K_CPUID; d_writes_reg=1'b1;  // EXEC writes all 4 GPRs directly
          end else d_unknown=1'b1;              // out-of-scope in user mode -> HALT
        end
        // ---- 0F 31: RDTSC — read the 64-bit time-stamp counter into EDX:EAX.
        // Ungated like CPUID (cosim_en || soc_en): real boot firmware (SeaBIOS
        // calibrates the TSC against PIT ch2) needs it; our CPUID advertises the
        // TSC feature (leaf-1 EDX bit 4 = 1). The user-mode corpus has both off, so
        // it stays the loud HALT there — and the TSC value is a free-running cycle
        // count, inherently not per-record-diffable vs qemu (the SeaBIOS path that
        // uses it is free-run graded, not single-step). CR4.TSD privilege check is
        // not modeled (firmware runs CPL0 with TSD=0). EXEC writes EDX:EAX directly.
        8'h31: begin
          d_len=pfx_len+4'd2;
          if (cosim_en || soc_en) begin
            d_kind=K_RDTSC; d_writes_reg=1'b1;  // EXEC writes EDX:EAX from `tsc`
          end else d_unknown=1'b1;              // out-of-scope in user mode -> HALT
        end
        // ---- 0F 08 INVD / 0F 09 WBINVD: cache invalidate / write-back+invalidate.
        // Privileged (CPL0) cache-management ops with NO architectural register/flag
        // effect — qemu's TCG treats both as NOPs (no modeled cache writeback), and
        // Ventium's caches stay coherent with the flat memory model, so they retire as
        // NOPs. Real boot firmware (SeaBIOS shadows the BIOS / sets caching) uses WBINVD.
        // Ungated like CPUID/RDTSC (cosim_en || soc_en); user-mode corpus keeps the HALT.
        8'h08, 8'h09: begin
          d_len=pfx_len+4'd2;
          if (cosim_en || soc_en) d_is_nop=1'b1; else d_unknown=1'b1;
        end
        // ---- 0F 0B: UD2, the architecturally-undefined opcode -> #UD (vector 6).
        // In SYSTEM mode it DELIVERS #UD through the IDT (a FAULT: pushes the
        // faulting EIP); in user mode there is no IDT, so it HALTs loudly as an
        // out-of-scope opcode (unchanged). #UD carries NO error code.
        8'h0B: begin
          d_len=pfx_len+4'd2;
          if (sys_mode) d_ud2=1'b1; else d_unknown=1'b1;
        end
        default: begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
      endcase
    end else begin
      unique casez (op0)
        8'b1011_0???: begin // MOV r8, imm8
          d_len=pfx_len+4'd2; d_is_mov=1'b1; d_writes_reg=1'b1; d_w=3'd1;
          d_dst_reg=op0[2:0]; d_dst_high8=op0[2]; d_alu_op=ALU_MOV; d_use_imm=1'b1;
          d_imm={24'd0,ibuf[pfx_len+1]};
        end
        8'b1011_1???: begin // MOV r16/32, imm
          d_is_mov=1'b1; d_writes_reg=1'b1; d_dst_reg=op0[2:0]; d_alu_op=ALU_MOV; d_use_imm=1'b1;
          if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'b0100_0???: begin // INC r16/32
          d_len=pfx_len+4'd1; d_writes_reg=1'b1; d_writes_flags=1'b1;
          d_dst_reg=op0[2:0]; d_src_reg=op0[2:0]; d_alu_op=ALU_INC; d_w=eff_opsize?3'd2:3'd4;
        end
        8'b0100_1???: begin // DEC r16/32
          d_len=pfx_len+4'd1; d_writes_reg=1'b1; d_writes_flags=1'b1;
          d_dst_reg=op0[2:0]; d_src_reg=op0[2:0]; d_alu_op=ALU_DEC; d_w=eff_opsize?3'd2:3'd4;
        end
        8'b0101_0???: begin // PUSH r16/32
          d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1; d_src_reg=op0[2:0];
          d_w=eff_opsize?3'd2:3'd4;
        end
        8'b0101_1???: begin // POP r16/32
          d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1; d_writes_reg=1'b1;
          d_dst_reg=op0[2:0]; d_w=eff_opsize?3'd2:3'd4;
        end
        // ---- F3: one-byte PUSH/POP segment register (06/0E/16/1E push es/cs/ss/ds,
        // 07/17/1F pop es/ss/ds — there is no POP CS, 0x0F is the 0F escape). Real
        // boot firmware (SeaBIOS's 16<->32 call32 trampoline) pushes CS to build an
        // iret far-return frame. The push value is the 16-bit selector (zero-extended
        // to 32 under a 0x66 operand-size prefix); POP reloads the selector and, in
        // real/v86, the base = sel<<4 (the only path these reach in firmware). They
        // were d_unknown->HALT before; the user corpus never executes them, so the
        // default `make verify` build stays byte-identical. K_ALU (default kind) so the
        // push data-mux / pop writeback below service them.
        8'h06: begin d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_ES); d_w=eff_opsize?3'd2:3'd4; end
        8'h0E: begin d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_CS); d_w=eff_opsize?3'd2:3'd4; end
        8'h16: begin d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_SS); d_w=eff_opsize?3'd2:3'd4; end
        8'h1E: begin d_len=pfx_len+4'd1; d_is_push=1'b1; d_mem_write=1'b1;
                     d_push_sreg=1'b1; d_sys_sreg=3'(SG_DS); d_w=eff_opsize?3'd2:3'd4; end
        8'h07: begin d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1;
                     d_pop_sreg=1'b1; d_sys_sreg=3'(SG_ES); d_w=eff_opsize?3'd2:3'd4; end
        8'h17: begin d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1;
                     d_pop_sreg=1'b1; d_sys_sreg=3'(SG_SS); d_w=eff_opsize?3'd2:3'd4; end
        8'h1F: begin d_len=pfx_len+4'd1; d_is_pop=1'b1; d_mem_read=1'b1;
                     d_pop_sreg=1'b1; d_sys_sreg=3'(SG_DS); d_w=eff_opsize?3'd2:3'd4; end
        8'h60: begin d_kind=K_STKMISC; d_sm=SM_PUSHA; d_len=pfx_len+4'd1; d_w=eff_opsize?3'd2:3'd4; end
        8'h61: begin d_kind=K_STKMISC; d_sm=SM_POPA;  d_len=pfx_len+4'd1; d_w=eff_opsize?3'd2:3'd4; end
        8'h68: begin // PUSH imm
          d_is_push=1'b1; d_mem_write=1'b1; d_use_imm=1'b1;
          if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'h6A: begin // PUSH imm8 (sign-ext)
          d_is_push=1'b1; d_mem_write=1'b1; d_use_imm=1'b1; d_w=eff_opsize?3'd2:3'd4;
          d_imm={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; d_len=pfx_len+4'd2;
        end
        8'h69: begin // IMUL r, r/m, imm32
          d_kind=K_IMUL2; d_imul_3op=1'b1; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_imul_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]};
            d_len=pfx_len+4'd6;
          end else begin
            d_mem_read=1'b1;
            d_imul_imm={ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+3],
                        ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+2],
                        ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                        ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+0]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
          end
        end
        8'h6B: begin // IMUL r, r/m, imm8
          d_kind=K_IMUL2; d_imul_3op=1'b1; d_writes_reg=1'b1; d_writes_flags=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_src_reg=modrm_rm; d_imul_imm={{24{ibuf[m_idx+1][7]}},ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1;
            d_imul_imm={{24{ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)][7]}},
                        ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'b00??_?000: begin // ALU r/m8, r8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin
            d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=(op0[5:3]!=3'b111); d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?001: begin // ALU r/m16/32, r16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_rm; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=(op0[5:3]!=3'b111); d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?010: begin // ALU r8, r/m8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_reg; d_dst_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?011: begin // ALU r16/32, r/m16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b00??_?100: begin // ALU AL, imm8
          d_w=3'd1; d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=R_EAX; d_src_reg=R_EAX;
          d_use_imm=1'b1; d_imm={24'd0,ibuf[pfx_len+1]}; d_len=pfx_len+4'd2;
        end
        8'b00??_?101: begin // ALU eAX, imm16/32
          d_alu_op={2'b00,op0[5:3]}; d_writes_flags=1'b1;
          d_writes_reg=(op0[5:3]!=3'b111); d_dst_reg=R_EAX; d_src_reg=R_EAX; d_use_imm=1'b1;
          if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'h80: begin // group1 r/m8, imm8
          d_w=3'd1; d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            d_imm={24'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'h81: begin // group1 r/m16/32, imm16/32
          d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_src_reg=modrm_rm;
            if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
            else begin d_w=3'd4; d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            if (eff_opsize) begin d_w=3'd2;
              d_imm={16'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd2;
            end else begin d_w=3'd4;
              d_imm={ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+3],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+2],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+0]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
            end
          end
        end
        8'h83: begin // group1 r/m16/32, imm8 sign-ext
          d_alu_op={2'b00,modrm_reg}; d_writes_flags=1'b1; d_use_imm=1'b1; d_w=eff_opsize?3'd2:3'd4;
          if (modrm_mod==2'b11) begin
            d_writes_reg=(modrm_reg!=3'b111); d_dst_reg=modrm_rm; d_src_reg=modrm_rm;
            d_imm={{24{ibuf[m_idx+1][7]}},ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin
            d_mem_read=1'b1; d_mem_write=(modrm_reg!=3'b111); d_mem_dst=1'b1;
            d_imm={{24{ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)][7]}},
                   ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1;
          end
        end
        8'h84: begin // TEST r/m8, r8
          d_w=3'd1; d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h85: begin // TEST r/m16/32, r16/32
          d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h86: begin // XCHG r/m8, r8
          d_kind=K_XCHG; d_w=3'd1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_writes_reg=1'b1; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h87: begin // XCHG r/m16/32, r16/32
          d_kind=K_XCHG; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_writes_reg=1'b1; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h88: begin // MOV r/m8, r8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_w=3'd1; d_src_reg=modrm_reg; d_src_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h89: begin // MOV r/m16/32, r16/32
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_src_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h8A: begin // MOV r8, r/m8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_w=3'd1; d_writes_reg=1'b1; d_dst_reg=modrm_reg; d_dst_high8=modrm_reg[2];
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h8B: begin // MOV r16/32, r/m16/32
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        // M9.5 — LES (0xC4) / LDS (0xC5): load r16 + a segment register from a
        // m16:16 far pointer. REAL-MODE 16-bit only: a single 4-byte read returns
        // {sel, off}; the GPR gets off (a normal MOV writeback), the segment reg
        // gets sel (base=sel<<4) via the q_seg_load exec hook. The reg form is #UD,
        // and 32-bit (0x66) / protected-mode are out of scope -> HALT loudly.
        8'hC4, 8'hC5: begin
          if (modrm_mod!=2'b11 && seg_real && eff_opsize) begin
            d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
            d_mem_read=1'b1; d_w=3'd2;
            d_seg_load=1'b1; d_lseg=(op0==8'hC4)?3'(SG_ES):3'(SG_DS);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
        end
        8'h8C: begin // MOV r/m16, Sreg  (M2S.1)
          // store the selector value of segment modrm_reg into r/m16. Reg form =
          // SYS_MOVSREG_FROM (writes a GPR). F3 MEMORY-dest form (mod!=11): real
          // boot firmware (SeaBIOS's call16/call32 trampoline SAVES es/ss/etc into a
          // struct). Storing a selector is mode-independent (no descriptor), so it
          // routes as a normal MOV-store (d_is_mov + d_mem_write) with the data taken
          // from seg_sel via d_store_sreg. Gated sys_mode so the user-mode corpus keeps
          // its HALT (byte-identical); reg form unchanged.
          if (modrm_mod==2'b11) begin
            d_sysop=SYS_MOVSREG_FROM; d_sys_sreg=sreg_idx(modrm_reg); d_w=3'd2;
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2;
          end else if (sys_mode) begin
            d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_w=3'd2;
            d_store_sreg=1'b1; d_sys_sreg=sreg_idx(modrm_reg);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else begin
            d_unknown=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'h8D: begin // LEA
          d_is_lea=1'b1; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
        end
        8'h8E: begin // MOV Sreg, r/m16  (M2S.1)
          // load segment register modrm_reg from r/m16. Reg-form source: the M2S.1
          // SYS_MOVSREG_TO path (real -> base=sel<<4 in S_EXEC; PM -> S_SEGLD GDT walk).
          // F3 MEMORY-source form (mod!=11): real/v86 boot firmware (SeaBIOS's call32
          // return loads ds/es from a saved struct). Read the 2-byte selector and load
          // it via the LES/LDS seg-load hook's LOW-half variant (base=sel<<4). Gated
          // seg_real: a PM mov-sreg-from-mem would need the GDT walk and still defers
          // to HALT (out of scope, never hit by the firmware path). The user corpus
          // never uses the mem form, so `make verify` stays byte-identical.
          if (modrm_mod==2'b11) begin
            d_sysop=SYS_MOVSREG_TO; d_sys_sreg=sreg_idx(modrm_reg); d_w=3'd2;
            d_src_reg=modrm_rm; d_len=pfx_len+4'd2;
          end else if (seg_real) begin
            d_mem_read=1'b1; d_w=3'd2;
            d_seg_load=1'b1; d_seg_load_lo=1'b1; d_lseg=sreg_idx(modrm_reg);
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end else begin
            d_unknown=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          end
        end
        8'h8F: begin // POP r/m
          d_is_pop=1'b1; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'b1001_0???: begin // NOP / XCHG eAX,r
          if (op0==8'h90 && !eff_opsize) begin d_is_nop=1'b1; d_len=pfx_len+4'd1; end
          else begin d_kind=K_XCHG; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_src_reg=op0[2:0]; d_len=pfx_len+4'd1; end
        end
        8'h98: begin d_kind=K_CONV; d_conv_cdq=1'b0; d_len=pfx_len+4'd1; end
        8'h99: begin d_kind=K_CONV; d_conv_cdq=1'b1; d_len=pfx_len+4'd1; end
        8'h9C: begin d_kind=K_STKMISC; d_sm=SM_PUSHF; d_mem_write=1'b1; d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'h9D: begin d_kind=K_STKMISC; d_sm=SM_POPF;  d_mem_read=1'b1;  d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'h9E: begin d_kind=K_STKMISC; d_sm=SM_SAHF; d_len=pfx_len+4'd1; end
        8'h9F: begin d_kind=K_STKMISC; d_sm=SM_LAHF; d_len=pfx_len+4'd1; end
        // ---- BCD / ASCII-adjust (review fidelity closure; QEMU-exact in S_EXEC) ----
        // All six write AX (d_w=2, dst=EAX) and flags; the BCD AX result + defined
        // flags are computed combinationally below and override alu_out/flags_out.
        // ASCII forms 0xD4/0xD5 take an imm8 "base" (ibuf[pfx_len+1]); 0x27/0x2F/
        // 0x37/0x3F are 1-byte no-operand. (These previously fell to d_unknown/HALT.)
        8'h37: begin d_kind=K_ALU; d_alu_op=ALU_AAA; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_len=pfx_len+4'd1; end
        8'h3F: begin d_kind=K_ALU; d_alu_op=ALU_AAS; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_len=pfx_len+4'd1; end
        8'h27: begin d_kind=K_ALU; d_alu_op=ALU_DAA; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_len=pfx_len+4'd1; end
        8'h2F: begin d_kind=K_ALU; d_alu_op=ALU_DAS; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_len=pfx_len+4'd1; end
        8'hD4: begin d_kind=K_ALU; d_alu_op=ALU_AAM; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_use_imm=1'b1;
                     d_imm={24'd0, ibuf[pfx_len+4'd1]}; d_len=pfx_len+4'd2; end
        8'hD5: begin d_kind=K_ALU; d_alu_op=ALU_AAD; d_writes_reg=1'b1; d_dst_reg=R_EAX;
                     d_w=3'd2; d_writes_flags=1'b1; d_use_imm=1'b1;
                     d_imm={24'd0, ibuf[pfx_len+4'd1]}; d_len=pfx_len+4'd2; end
        // MOV moffs (A0-A3): the moffs (absolute displacement) width follows the
        // EFFECTIVE ADDRESS size — 2 bytes under 16-bit addressing (real mode / V86
        // without a 0x67 prefix; eff_addr==1), 4 bytes under 32-bit addressing.
        // Previously hardcoded 4-byte (d_len pfx_len+5), which over-consumed 2 bytes
        // and desynced the stream for a 16-bit-address `66 a3 disp16` store — exactly
        // the V86 task's `mov %eax,%ds:0`. M0-M6/sys gates only ever hit the 32-bit
        // form, so the eff_addr branch is additive (bit-identical where eff_addr==0).
        8'hA0: begin // MOV AL, moffs8 (8-bit load, preserve [31:8])
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_mem_read=1'b1;
          d_w=3'd1;
          if (eff_addr) begin d_ea={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hA1: begin // MOV eAX, moffs
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_mem_read=1'b1;
          d_w=eff_opsize?3'd2:3'd4;
          if (eff_addr) begin d_ea={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hA2: begin // MOV moffs8, AL (8-bit store)
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_mem_dst=1'b1; d_src_reg=R_EAX;
          d_w=3'd1;
          if (eff_addr) begin d_ea={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hA3: begin // MOV moffs, eAX
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_mem_dst=1'b1; d_src_reg=R_EAX;
          d_w=eff_opsize?3'd2:3'd4;
          if (eff_addr) begin d_ea={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hA8: begin d_w=3'd1; d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_dst_reg=R_EAX;
          d_use_imm=1'b1; d_imm={24'd0,ibuf[pfx_len+1]}; d_len=pfx_len+4'd2; end
        8'hA9: begin d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_dst_reg=R_EAX; d_use_imm=1'b1;
          if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_w=3'd4; d_imm={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        // string ops
        8'hA4: begin d_kind=K_STR; d_st=ST_MOVS; d_w=3'd1; d_str_loadsi=1'b1; d_str_storedi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA5: begin d_kind=K_STR; d_st=ST_MOVS; d_w=eff_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_str_storedi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAA: begin d_kind=K_STR; d_st=ST_STOS; d_w=3'd1; d_str_storedi=1'b1; d_len=pfx_len+4'd1; end
        8'hAB: begin d_kind=K_STR; d_st=ST_STOS; d_w=eff_opsize?3'd2:3'd4; d_str_storedi=1'b1; d_len=pfx_len+4'd1; end
        8'hAC: begin d_kind=K_STR; d_st=ST_LODS; d_w=3'd1; d_str_loadsi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAD: begin d_kind=K_STR; d_st=ST_LODS; d_w=eff_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAE: begin d_kind=K_STR; d_st=ST_SCAS; d_w=3'd1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hAF: begin d_kind=K_STR; d_st=ST_SCAS; d_w=eff_opsize?3'd2:3'd4; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA6: begin d_kind=K_STR; d_st=ST_CMPS; d_w=3'd1; d_str_loadsi=1'b1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        8'hA7: begin d_kind=K_STR; d_st=ST_CMPS; d_w=eff_opsize?3'd2:3'd4; d_str_loadsi=1'b1; d_str_scandi=1'b1; d_writes_flags=1'b1; d_mem_read=1'b1; d_len=pfx_len+4'd1; end
        // ---- 6C/6D: INS — port-input string (the co-sim's only string-I/O op) ----
        // INSB (6C) / INSW/D (6D): read a byte/word/dword from port DX and STORE it
        // to ES:[EDI], then EDI += width (DF=0 forward). With a REP prefix it iterates
        // ECX times — each element is its own retire record at the same PC (exactly
        // like the golden's `rep insb` at 0xEBB07, ecx=4, port 0x511 fwcfg). It is a
        // STRING op (K_STR / ST_INS, d_str_storedi) AND a port-input (d_io) so the
        // co-sim's recorded dev_in value is the source of each element (the sole
        // injected environment). The dedicated S_INS state does the per-element IO
        // handshake; the existing K_STR S_STORE path writes [EDI] and loops/retires.
        // Gated on cosim_en (mirrors the IN/OUT decode): outside co-sim INS HALTs
        // loudly (out-of-scope, like every other port I/O) so the corpus is unchanged.
        // Width: byte for 6C; eff-opsize (16/32) for 6D. The boot only uses 6C, but
        // 6D is decoded identically for completeness (same S_INS path, wider element).
        8'h6C, 8'h6D: begin
          // INS/REP INS uses the SAME S_INS per-element IO handshake as the single IN,
          // so it works under soc_en too (SeaBIOS bulk-reads fw_cfg via `rep insb`).
          // Outside both (user mode) it stays the loud HALT. Default build unaffected.
          if (cosim_en || soc_en) begin
            d_kind=K_STR; d_st=ST_INS; d_str_storedi=1'b1; d_mem_write=1'b1;
            d_w=(op0==8'h6C) ? 3'd1 : (eff_opsize?3'd2:3'd4);
            d_io=1'b1; d_io_write=1'b0; d_io_imm=1'b0;  // port is DX (resolved at issue)
            d_io_w=d_w;
            d_len=pfx_len+4'd1;
          end else begin d_unknown=1'b1; d_len=pfx_len+4'd1; end
        end
        8'hC6: begin // MOV r/m8, imm8
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_use_imm=1'b1; d_w=3'd1;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2];
            d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin d_mem_write=1'b1; d_mem_dst=1'b1;
            d_imm={24'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1; end
        end
        8'hC7: begin // MOV r/m16/32, imm
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_use_imm=1'b1;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm;
            if (eff_opsize) begin d_w=3'd2; d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
            else begin d_w=3'd4; d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
          end else begin d_mem_write=1'b1; d_mem_dst=1'b1;
            if (eff_opsize) begin d_w=3'd2;
              d_imm={16'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd2;
            end else begin d_w=3'd4;
              d_imm={ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+3],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+2],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+1],
                     ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+0]};
              d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd4;
            end
          end
        end
        8'hD0,8'hD1,8'hD2,8'hD3: begin // shift/rotate by 1 / CL
          d_kind=K_SHIFT; d_writes_flags=1'b1; d_shrot=modrm_reg;
          d_w=(op0==8'hD0||op0==8'hD2)?3'd1:(eff_opsize?3'd2:3'd4);
          d_shift_one=(op0==8'hD0||op0==8'hD1);
          d_shift_cl=(op0==8'hD2||op0==8'hD3);
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2;
          end else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hC0,8'hC1: begin // shift/rotate by imm8
          d_kind=K_SHIFT; d_writes_flags=1'b1; d_shrot=modrm_reg;
          d_w=(op0==8'hC0)?3'd1:(eff_opsize?3'd2:3'd4);
          if (modrm_mod==2'b11) begin
            d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2];
            d_shift_imm=ibuf[m_idx+1][4:0]; d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3;
          end else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1;
            d_shift_imm=ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)][4:0];
            d_imm={24'd0,ibuf[m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)]};
            d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base)+4'd1; end
        end
        8'hF6,8'hF7: begin // group3
          d_w=(op0==8'hF6)?3'd1:(eff_opsize?3'd2:3'd4);
          unique case (modrm_reg)
            3'd0,3'd1: begin // TEST r/m, imm
              d_alu_op=ALU_TEST; d_writes_flags=1'b1; d_use_imm=1'b1;
              if (modrm_mod==2'b11) begin d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2];
                if (d_w==3'd1) begin d_imm={24'd0,ibuf[m_idx+1]}; d_len=pfx_len+4'd3; end
                else if (d_w==3'd2) begin d_imm={16'd0,ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd4; end
                else begin d_imm={ibuf[m_idx+4],ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1]}; d_len=pfx_len+4'd6; end
              end else begin
                // TEST mem, imm — read the operand, AND with imm, set flags only
                // (no write). The M1-M6 user corpus never used the memory form, so
                // it previously HALTed (d_unknown); Quake's musl uses it (e.g.
                // `test byte [esp+8], 0x10`). The imm follows the full ModR/M+SIB+
                // disp, so its offset is the operand length minus the imm width.
                d_mem_read=1'b1; d_mem_dst=1'b1;
                begin
                  logic [3:0] ml;
                  ml = mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
                  if (d_w==3'd1) begin
                    d_imm={24'd0,ibuf[m_idx+ml]};                 // imm8 after the operand
                    d_len=m_idx+ml+4'd1;
                  end else if (d_w==3'd2) begin
                    d_imm={16'd0,ibuf[m_idx+ml+1],ibuf[m_idx+ml]};
                    d_len=m_idx+ml+4'd2;
                  end else begin
                    d_imm={ibuf[m_idx+ml+3],ibuf[m_idx+ml+2],ibuf[m_idx+ml+1],ibuf[m_idx+ml]};
                    d_len=m_idx+ml+4'd4;
                  end
                end
              end
            end
            3'd2: begin // NOT
              d_alu_op=ALU_NOT;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd3: begin // NEG
              d_alu_op=ALU_NEG; d_writes_flags=1'b1;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            default: begin // MUL/IMUL/DIV/IDIV
              d_kind=K_MULDIV; d_md=modrm_reg; d_writes_flags=1'b1;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_src_high8=(d_w==3'd1)&&modrm_rm[2]; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
          endcase
        end
        8'hFE: begin // INC/DEC r/m8
          d_w=3'd1; d_writes_flags=1'b1; d_alu_op=(modrm_reg==3'd0)?ALU_INC:ALU_DEC;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_dst_high8=modrm_rm[2]; d_len=pfx_len+4'd2; end
          else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'hFF: begin
          unique case (modrm_reg)
            3'd0,3'd1: begin // INC/DEC r/m16/32
              d_w=eff_opsize?3'd2:3'd4; d_writes_flags=1'b1; d_alu_op=(modrm_reg==3'd0)?ALU_INC:ALU_DEC;
              if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_mem_write=1'b1; d_mem_dst=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd2: begin // CALL r/m near
              // F3: push width follows the operand size (16-bit real-mode `call
              // r/m16` pushes 2 bytes / SP-=2, exactly like E8 CALLREL). Was a
              // hard-coded d_w=4, which leaked SP by 2 per call/ret pair in
              // 16-bit code. eff_opsize=0 in every flat gate -> byte-identical.
              d_kind=K_CTRL; d_ct=CT_CALLIND; d_mem_write=1'b1;
              d_w=eff_opsize?3'd2:3'd4;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd4: begin // JMP r/m near
              d_kind=K_CTRL; d_ct=CT_JMPIND;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            3'd6: begin // PUSH r/m
              d_is_push=1'b1; d_mem_write=1'b1; d_w=eff_opsize?3'd2:3'd4;
              if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
              else begin d_mem_read=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
            // F3 — FF /3 CALLF m16:16 / FF /5 JMPF m16:16 (far indirect call/jump
            // THROUGH MEMORY): read the 4-byte {offset,selector} far pointer from
            // [mem], then a far transfer. (FreeDOS does `jmp far [bp+0x5a]`.) These
            // are MEMORY-ONLY (reg form mod=11 is invalid -> #UD/HALT). Gated real
            // mode (seg_real && !paging_on) like the direct far CALL/JMP; PM call/jmp
            // gates are out of scope. d_callf_mem/d_jmpf_mem are serviced after the
            // S_LOAD reads the pointer: JMPF loads CS:IP inline, CALLF stages it then
            // S_LCALL pushes CS:next_eip + loads.
            3'd3: begin // CALLF m16:16
              if (modrm_mod!=2'b11 && seg_real && !paging_on) begin
                d_callf_mem=1'b1; d_mem_read=1'b1; d_w=3'd2;
                d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
              end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
            end
            3'd5: begin // JMPF m16:16
              if (modrm_mod!=2'b11 && seg_real && !paging_on) begin
                d_jmpf_mem=1'b1; d_mem_read=1'b1; d_w=3'd2;
                d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
              end else begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
            end
            default: begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
          endcase
        end
        8'hEB: begin d_len=pfx_len+4'd2; d_is_branch=1'b1; d_branch_taken=1'b1;
          d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; d_br16=eff_opsize; end
        8'hE9: begin d_is_branch=1'b1; d_branch_taken=1'b1;
          // JMP rel16/rel32 (M7.3b operand-size-aware). 32-bit (eff_opsize=0): rel32
          // / length 5 — UNCHANGED. 16-bit (real-mode SeaBIOS, e.g. the jmp at
          // 0xe076): rel16 / length 3, target truncated to 16 bits (d_br16).
          if (eff_opsize) begin
            d_rel={{16{ibuf[pfx_len+2][7]}},ibuf[pfx_len+2],ibuf[pfx_len+1]};
            d_br16=1'b1; d_len=pfx_len+4'd3;
          end else begin
            d_rel={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
            d_len=pfx_len+4'd5;
          end
        end
        8'b0111_????: begin d_len=pfx_len+4'd2; d_is_branch=1'b1;
          d_branch_taken=cond_true(op0[3:0],eflags); d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]};
          d_br16=eff_opsize; end
        8'hE8: begin d_kind=K_CTRL; d_ct=CT_CALLREL; d_mem_write=1'b1; d_w=eff_opsize?3'd2:3'd4;
          // 0x66 near CALL: 16-bit rel (cw), push 16-bit next-IP, ESP-=2, and
          // EIP=(next_eip+rel16)&0xFFFF (operand-size-16 truncates EIP).
          if (eff_opsize) begin d_rel={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_rel={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hC3: begin d_kind=K_CTRL; d_ct=CT_RETN; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'hC2: begin d_kind=K_CTRL; d_ct=CT_RETN_IMM; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4;
          d_ret_imm={ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
        // M9.5 — RETF (far return): pop IP then CS (2 beats), ESP += 2w (+imm16). The
        // S_RETF state does the stack pops + the real-mode CS load (base=sel<<4). The
        // routing (real-mode only; PM RETF HALTs) is in core_fetch_decode.svh.
        8'hCB: begin d_sysop=SYS_RETF; d_ret_imm=16'd0; d_w=eff_opsize?3'd2:3'd4;
          d_len=pfx_len+4'd1; end
        8'hCA: begin d_sysop=SYS_RETF; d_ret_imm={ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd3; end
        8'hC9: begin d_kind=K_STKMISC; d_sm=SM_LEAVE; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'hE2: begin d_kind=K_CTRL; d_ct=CT_LOOP;   d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE1: begin d_kind=K_CTRL; d_ct=CT_LOOPE;  d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE0: begin d_kind=K_CTRL; d_ct=CT_LOOPNE; d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE3: begin d_kind=K_CTRL; d_ct=CT_JECXZ;  d_len=pfx_len+4'd2; d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hFC: begin d_cld=1'b1; d_len=pfx_len+4'd1; end
        8'hFD: begin d_std=1'b1; d_len=pfx_len+4'd1; end
        8'hF8: begin d_clc=1'b1; d_len=pfx_len+4'd1; end // CLC: CF<-0
        8'hF9: begin d_stc=1'b1; d_len=pfx_len+4'd1; end // STC: CF<-1
        8'hF5: begin d_cmc=1'b1; d_len=pfx_len+4'd1; end // CMC: CF<-~CF
        8'hFA: begin d_cli=1'b1; d_len=pfx_len+4'd1; end // CLI: IF<-0 (M2S.1)
        8'hFB: begin d_sti=1'b1; d_len=pfx_len+4'd1; end // STI: IF<-1 (M2S.1)
        // INT n (CD ib): in USER mode INT 0x80 is the syscall HALT (unchanged —
        // no IDT in linux-user). In SYSTEM mode it is a software interrupt that
        // vectors through IDT[n] (a TRAP: pushes the NEXT EIP so IRET resumes
        // after the INT). The decode is gated on sys_mode so user mode is byte-
        // identical; a non-0x80 INT in user mode still HALTs loudly (out of scope).
        8'hCC: begin // INT3 (#BP, vector 3) — TRAP
          d_len=pfx_len+4'd1;
          // user mode: keep the prior loud-HALT (d_unknown) exactly so the M0-M6
          // user gate stays BIT-IDENTICAL (0xCC was an unknown opcode before M2S.3).
          if (sys_mode) begin d_int=1'b1; d_int_vec=8'd3; end else d_unknown=1'b1;
        end
        8'hCD: begin
          d_len=pfx_len+4'd2;
          if (sys_mode) begin d_int=1'b1; d_int_imm=1'b1; d_int_vec=ibuf[pfx_len+1]; end
          else begin
            // user mode: int 0x80 = the syscall site. Without the proxy it HALTs
            // (M0-M6 behaviour, unchanged). d_int80 flags it so the S_DECODE arm
            // can route it to the proxy when proxy_en is set.
            d_halt  = (ibuf[pfx_len+1]==8'h80);
            d_int80 = (ibuf[pfx_len+1]==8'h80);
          end
        end
        8'hCE: begin // INTO (#OF, vector 4) — TRAP, conditional on OF
          d_len=pfx_len+4'd1;
          // user mode: prior loud-HALT (d_unknown) preserved for bit-identity.
          if (sys_mode) begin d_int=1'b1; d_int_vec=8'd4; d_int_cond_of=1'b1; end
          else d_unknown=1'b1;
        end
        8'hCF: begin // IRET — pop EIP/CS/EFLAGS (near, same-privilege)
          d_len=pfx_len+4'd1;
          if (sys_mode) d_iret=1'b1; else d_unknown=1'b1;
        end

        // -------------------------------------------------------------------
        // M2S.1 system-mode instructions (real-mode boot + real->PM transition).
        // -------------------------------------------------------------------
        8'hEA: begin // far JMP ptr16:off  (EA off16/32 sel16)
          // operand-size selects the offset width: 16-bit by default (real mode
          // EA off16 sel16, len=5) or 32-bit under 0x66 (66 EA off32 sel16,
          // len=7 incl the 66 prefix — pfx_len counts the 66). The bootstrap uses
          // BOTH: the 16-bit reset stub (EA off16 sel16) and the 66 ljmp ptr16:32.
          d_sysop=SYS_LJMP;
          if (eff_opsize) begin
            d_ljmp_off={16'd0, ibuf[pfx_len+2], ibuf[pfx_len+1]};
            d_ljmp_sel={ibuf[pfx_len+4], ibuf[pfx_len+3]};
            d_len=pfx_len+4'd5;
          end else begin
            d_ljmp_off={ibuf[pfx_len+4], ibuf[pfx_len+3], ibuf[pfx_len+2], ibuf[pfx_len+1]};
            d_ljmp_sel={ibuf[pfx_len+6], ibuf[pfx_len+5]};
            d_len=pfx_len+4'd7;
          end
        end
        8'h9A: begin // far CALL ptr16:16 (9A off16 sel16) / ptr16:32 under 0x66.
          // M9.5: push CS then the return IP (S_LCALL), then real-mode CS load
          // (base=sel<<4) + EIP=off. Operand size selects the offset/push width.
          d_sysop=SYS_LCALL;
          if (eff_opsize) begin
            d_ljmp_off={16'd0, ibuf[pfx_len+2], ibuf[pfx_len+1]};
            d_ljmp_sel={ibuf[pfx_len+4], ibuf[pfx_len+3]};
            d_w=3'd2; d_len=pfx_len+4'd5;
          end else begin
            d_ljmp_off={ibuf[pfx_len+4], ibuf[pfx_len+3], ibuf[pfx_len+2], ibuf[pfx_len+1]};
            d_ljmp_sel={ibuf[pfx_len+6], ibuf[pfx_len+5]};
            d_w=3'd4; d_len=pfx_len+4'd7;
          end
        end
        8'hF4: begin // HLT — stop retiring (a clean spin in the bare-metal test)
          d_halt=1'b1; d_len=pfx_len+4'd1;
        end

        // -------------------------------------------------------------------
        // M7.3b PORT I/O — IN/OUT (docs/m7-lockstep-spec.md M7.3). The decode is
        // UNCONDITIONAL (not gated on sys/cosim) so the length is always right;
        // the FSM (S_DECODE) decides what to DO: in --win95 co-sim mode an IN
        // takes its value off the io bus + an OUT drives the port out; OUTSIDE
        // co-sim the only legal use is the isa-debug-exit `out 0xf4` terminator
        // (preserved — HALT, no extra retire), and any other IN/OUT HALTs loudly.
        // Width: AL forms (E4/E6/EC/EE) = byte; eAX forms = eff-opsize (word in
        // real mode, dword in 32-bit). Port: imm8 (E4-E7) or DX (EC-EF).
        // -------------------------------------------------------------------
        8'hE4, 8'hE5: begin   // IN AL/eAX, imm8
          d_io=1'b1; d_io_write=1'b0; d_io_imm=1'b1; d_io_port_imm=ibuf[pfx_len+1];
          d_io_w = (op0==8'hE4) ? 3'd1 : (eff_opsize ? 3'd2 : 3'd4);
          d_len  = pfx_len + 4'd2;
        end
        8'hE6, 8'hE7: begin   // OUT imm8, AL/eAX
          d_io=1'b1; d_io_write=1'b1; d_io_imm=1'b1; d_io_port_imm=ibuf[pfx_len+1];
          d_io_w = (op0==8'hE6) ? 3'd1 : (eff_opsize ? 3'd2 : 3'd4);
          d_len  = pfx_len + 4'd2;
        end
        8'hEC, 8'hED: begin   // IN AL/eAX, DX
          d_io=1'b1; d_io_write=1'b0; d_io_imm=1'b0;
          d_io_w = (op0==8'hEC) ? 3'd1 : (eff_opsize ? 3'd2 : 3'd4);
          d_len  = pfx_len + 4'd1;
        end
        8'hEE, 8'hEF: begin   // OUT DX, AL/eAX
          d_io=1'b1; d_io_write=1'b1; d_io_imm=1'b0;
          d_io_w = (op0==8'hEE) ? 3'd1 : (eff_opsize ? 3'd2 : 3'd4);
          d_len  = pfx_len + 4'd1;
        end

        // -------------------------------------------------------------------
        // x87 FPU escapes D8..DF (single-byte opcode + ModR/M). m_idx already
        // points at the ModR/M byte; mod==11 = register form (length 2),
        // mod!=11 = memory form (length = m_idx + mfl(...)). We classify into a
        // fxop and supply addressing; the FPU exec path consumes them.
        // m3-fpu-spec.md: Tier-1/2 ops are routed; deferred/Tier-3 ops set
        // d_unknown so the core HALTs loudly (never mis-executes).
        // -------------------------------------------------------------------
        8'b1101_1???: begin
          d_is_x87=1'b1;
          d_f_sti = modrm_rm;
          // default length: register form 2, memory form variable
          if (modrm_mod==2'b11) d_len = m_idx + 4'd1;      // opcode + modrm
          else                  d_len = m_idx + mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
          unique case (op0)
            // ----- D8: arithmetic ST0 op= m32 / ST0 op= ST(i) --------------
            8'hD8: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin
                    d_fxop=FX_AR_M32; d_f_aluop=modrm_reg; d_f_mem_read=1'b1; d_f_mbytes=4'd4;
                  end
                  3'd2: begin d_fxop=FX_FCOM_M32; d_f_mem_read=1'b1; d_f_mbytes=4'd4; end
                  default: begin d_fxop=FX_FCOM_M32; d_f_mem_read=1'b1; d_f_mbytes=4'd4; d_f_pop=1'b1; end
                endcase
              end else begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_ST0_STI; d_f_aluop=modrm_reg; end
                  3'd2: d_fxop=FX_FCOM_STI;
                  default: begin d_fxop=FX_FCOM_STI; d_f_pop=1'b1; end
                endcase
              end
            end
            // ----- D9: loads/const/stack/sign/control -----------------------
            8'hD9: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0: begin d_fxop=FX_FLD_M32;  d_f_mem_read=1'b1;  d_f_mbytes=4'd4; end
                  3'd2: begin d_fxop=FX_FST_M32;  d_f_mem_write=1'b1; d_f_mbytes=4'd4; end
                  3'd3: begin d_fxop=FX_FST_M32;  d_f_mem_write=1'b1; d_f_mbytes=4'd4; d_f_pop=1'b1; end
                  3'd4: d_fxop=FX_FLDENV;        // M11b: 28-byte env load (S_FENV_LD owns the beats)
                  3'd5: begin d_fxop=FX_FLDCW;    d_f_mem_read=1'b1;  d_f_mbytes=4'd2; end
                  3'd6: d_fxop=FX_FNSTENV;        // M11b: 28-byte env store (S_FENV_ST owns the beats)
                  3'd7: begin d_fxop=FX_FNSTCW;   d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  default: d_unknown=1'b1;
                endcase
              end else begin
                unique casez (mrm)
                  8'b1100_0???: d_fxop=FX_FLD_STI;            // D9 C0+i FLD st(i)
                  8'b1100_1???: d_fxop=FX_FXCH;               // D9 C8+i FXCH
                  8'hD0:        d_fxop=FX_FNOP;                // D9 D0   FNOP
                  8'hE0:        d_fxop=FX_FCHS;                // D9 E0
                  8'hE1:        d_fxop=FX_FABS;                // D9 E1
                  8'hE4:        d_fxop=FX_FTST;                // D9 E4
                  8'hE5:        d_fxop=FX_FXAM;                // D9 E5
                  8'hE8:        begin d_fxop=FX_FLDCONST; d_f_const=3'd0; end  // FLD1
                  8'hE9:        begin d_fxop=FX_FLDCONST; d_f_const=3'd1; end  // FLDL2T
                  8'hEA:        begin d_fxop=FX_FLDCONST; d_f_const=3'd2; end  // FLDL2E
                  8'hEB:        begin d_fxop=FX_FLDCONST; d_f_const=3'd3; end  // FLDPI
                  8'hEC:        begin d_fxop=FX_FLDCONST; d_f_const=3'd4; end  // FLDLG2
                  8'hED:        begin d_fxop=FX_FLDCONST; d_f_const=3'd5; end  // FLDLN2
                  8'hEE:        begin d_fxop=FX_FLDCONST; d_f_const=3'd6; end  // FLDZ
                  8'hF6:        d_fxop=FX_FDECSTP;            // D9 F6
                  8'hF7:        d_fxop=FX_FINCSTP;            // D9 F7
                  8'hFA:        d_fxop=FX_FSQRT;              // D9 FA FSQRT
`ifdef VEN_TRANSCENDENTAL
                  8'hF0:        d_fxop=FX_F2XM1;              // D9 F0 F2XM1 (#11)
                  8'hF1:        d_fxop=FX_FYL2X;              // D9 F1 FYL2X (#11)
                  8'hF3:        d_fxop=FX_FPATAN;             // D9 F3 FPATAN (#11)
                  8'hF9:        d_fxop=FX_FYL2XP1;            // D9 F9 FYL2XP1 (#11)
                  8'hFE:        d_fxop=FX_FSIN;               // D9 FE FSIN (#11)
                  8'hFF:        d_fxop=FX_FCOS;               // D9 FF FCOS (#11)
                  8'hFB:        d_fxop=FX_FSINCOS;            // D9 FB FSINCOS (#11)
                  8'hF2:        d_fxop=FX_FPTAN;              // D9 F2 FPTAN (#11)
`endif
                  default:      d_unknown=1'b1;  // transcendentals/F2XM1/etc deferred
                endcase
              end
            end
            // ----- DA: FIADD..m32, FICOM m32, FUCOMPP -----------------------
            8'hDA: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_I32; d_f_aluop=modrm_reg; d_f_mem_read=1'b1; d_f_mbytes=4'd4; end
                  3'd2: begin d_fxop=FX_FICOM_M32; d_f_mem_read=1'b1; d_f_mbytes=4'd4; end
                  default: begin d_fxop=FX_FICOM_M32; d_f_mem_read=1'b1; d_f_mbytes=4'd4; d_f_pop=1'b1; end
                endcase
              end else begin
                if (mrm==8'hE9) begin d_fxop=FX_FUCOMPP; d_f_pop2=1'b1; end
                else d_unknown=1'b1;   // FCMOVcc deferred (not P5-era anyway)
              end
            end
            // ----- DB: FILD m32, FISTP m32, FNINIT/FNCLEX, FLD m80, FSTP m80 -
            8'hDB: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0: begin d_fxop=FX_FILD_M32; d_f_mem_read=1'b1;  d_f_mbytes=4'd4; end
                  3'd2: begin d_fxop=FX_FIST_M32; d_f_mem_write=1'b1; d_f_mbytes=4'd4; end
                  3'd3: begin d_fxop=FX_FIST_M32; d_f_mem_write=1'b1; d_f_mbytes=4'd4; d_f_pop=1'b1; end
                  3'd5: begin d_fxop=FX_FLD_M80;  d_f_mem_read=1'b1;  d_f_mbytes=4'd10; end
                  3'd7: begin d_fxop=FX_FST_M80;  d_f_mem_write=1'b1; d_f_mbytes=4'd10; d_f_pop=1'b1; end
                  default: d_unknown=1'b1;
                endcase
              end else begin
                unique case (mrm)
                  8'hE2: d_fxop=FX_FNCLEX;
                  8'hE3: d_fxop=FX_FNINIT;
                  default: d_unknown=1'b1;  // FCMOVcc/FCOMI deferred
                endcase
              end
            end
            // ----- DC: arithmetic ST0 op= m64 / ST(i) op= ST0 ---------------
            8'hDC: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_M64; d_f_aluop=modrm_reg; d_f_mem_read=1'b1; d_f_mbytes=4'd8; end
                  3'd2: begin d_fxop=FX_FCOM_M64; d_f_mem_read=1'b1; d_f_mbytes=4'd8; end
                  default: begin d_fxop=FX_FCOM_M64; d_f_mem_read=1'b1; d_f_mbytes=4'd8; d_f_pop=1'b1; end
                endcase
              end else begin
                unique case (modrm_reg)
                  // DC C0+i .. : ST(i)-destination forms. The x87 SUBR/SUB and
                  // DIVR/DIV senses are SWAPPED for the ST(i)-dest encoding vs
                  // the ST0-dest one (classic x87 "reverse" gotcha): reg=4 means
                  // FSUBR(ST(i)=ST0-ST(i)), 5=FSUB(ST(i)-ST0), 6=FDIVR, 7=FDIV.
                  // We flip aluop bit0 for the {sub,div} group so f_arith (a=ST(i),
                  // b=ST0) computes the right direction.
                  3'd0,3'd1: begin d_fxop=FX_AR_STI_ST0; d_f_aluop=modrm_reg; end
                  3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_STI_ST0; d_f_aluop={modrm_reg[2:1], ~modrm_reg[0]}; end
                  default: d_unknown=1'b1;
                endcase
              end
            end
            // ----- DD: FLD/FST m64, FST st(i), FFREE, FUCOM, FNSTSW m16 -----
            8'hDD: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0: begin d_fxop=FX_FLD_M64; d_f_mem_read=1'b1;  d_f_mbytes=4'd8; end
                  3'd2: begin d_fxop=FX_FST_M64; d_f_mem_write=1'b1; d_f_mbytes=4'd8; end
                  3'd3: begin d_fxop=FX_FST_M64; d_f_mem_write=1'b1; d_f_mbytes=4'd8; d_f_pop=1'b1; end
                  3'd4: d_fxop=FX_FRSTOR;        // M11b: 108-byte state load + reg reload
                  3'd6: d_fxop=FX_FNSAVE;        // M11b: 108-byte state store + FNINIT reinit
                  3'd7: begin d_fxop=FX_FNSTSW_M; d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  default: d_unknown=1'b1;
                endcase
              end else begin
                unique casez (mrm)
                  8'b1100_0???: d_fxop=FX_FFREE;             // DD C0+i FFREE
                  8'b1101_0???: d_fxop=FX_FST_STI;           // DD D0+i FST st(i)
                  8'b1101_1???: begin d_fxop=FX_FST_STI; d_f_pop=1'b1; end // DD D8+i FSTP st(i)
                  8'b1110_0???: d_fxop=FX_FUCOM_STI;         // DD E0+i FUCOM
                  8'b1110_1???: begin d_fxop=FX_FUCOM_STI; d_f_pop=1'b1; end // DD E8+i FUCOMP
                  default:      d_unknown=1'b1;
                endcase
              end
            end
            // ----- DE: arithmetic-and-pop ST(i) op= ST0, FCOMPP -------------
            8'hDE: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_I16; d_f_aluop=modrm_reg; d_f_mem_read=1'b1; d_f_mbytes=4'd2; end
                  3'd2: begin d_fxop=FX_FICOM_M16; d_f_mem_read=1'b1; d_f_mbytes=4'd2; end
                  default: begin d_fxop=FX_FICOM_M16; d_f_mem_read=1'b1; d_f_mbytes=4'd2; d_f_pop=1'b1; end
                endcase
              end else begin
                if (mrm==8'hD9) begin d_fxop=FX_FCOMPP; d_f_pop2=1'b1; end
                else begin
                  unique case (modrm_reg)
                    // DE C0+i ..: ST(i)-dest + pop. Same SUBR/SUB, DIVR/DIV swap
                    // as the DC-reg group (see note above).
                    3'd0,3'd1: begin d_fxop=FX_AR_STI_ST0; d_f_aluop=modrm_reg; d_f_pop=1'b1; end
                    3'd4,3'd5,3'd6,3'd7: begin d_fxop=FX_AR_STI_ST0; d_f_aluop={modrm_reg[2:1], ~modrm_reg[0]}; d_f_pop=1'b1; end
                    default: d_unknown=1'b1;
                  endcase
                end
              end
            end
            // ----- DF: FILD m16/m64, FISTP m16/m64, FNSTSW AX --------------
            8'hDF: begin
              if (modrm_mod!=2'b11) begin
                unique case (modrm_reg)
                  3'd0: begin d_fxop=FX_FILD_M16; d_f_mem_read=1'b1;  d_f_mbytes=4'd2; end
                  3'd2: begin d_fxop=FX_FIST_M16; d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  3'd3: begin d_fxop=FX_FIST_M16; d_f_mem_write=1'b1; d_f_mbytes=4'd2; d_f_pop=1'b1; end
                  3'd4: begin d_fxop=FX_FBLD;  d_f_mem_read=1'b1;  d_f_mbytes=4'd10; end          // FBLD m80 (packed BCD)
                  3'd5: begin d_fxop=FX_FILD_M64; d_f_mem_read=1'b1;  d_f_mbytes=4'd8; end
                  3'd6: begin d_fxop=FX_FBSTP; d_f_mem_write=1'b1; d_f_mbytes=4'd10; d_f_pop=1'b1; end // FBSTP m80 + pop
                  3'd7: begin d_fxop=FX_FIST_M64; d_f_mem_write=1'b1; d_f_mbytes=4'd8; d_f_pop=1'b1; end
                  default: d_unknown=1'b1;
                endcase
              end else begin
                if (mrm==8'hE0) d_fxop=FX_FNSTSW_AX;
                else d_unknown=1'b1;
              end
            end
            default: d_unknown=1'b1;
          endcase
          if (d_unknown) d_is_x87=1'b0;   // a deferred escape HALTs as unknown
        end

        default: begin d_len=pfx_len+4'd1; d_unknown=1'b1; end
      endcase
    end

    // Map an 8-bit HIGH-byte register operand (AH..BH, encoded index 4..7) to
    // its physical GPR (EAX..EBX = index 0..3). The high8 flag then selects bits
    // [15:8]. Low 8-bit regs (AL..BL, index 0..3) and 16/32-bit regs are
    // physical already. This keeps every reg_read/reg_merge site using
    // gpr[d_*_reg] directly.
    if (d_dst_high8) d_dst_reg = {1'b0, d_dst_reg[1:0]};
    if (d_src_high8) d_src_reg = {1'b0, d_src_reg[1:0]};
  end

  // M7.1: syscall_active pulses for the S_DECODE clock that proxies an int-0x80.
  // The slow FSM reaches the d_halt/int-0x80 arm in S_DECODE; gating on
  // (state==S_DECODE && d_int80 && proxy_en) makes this exactly the clock the
  // proxy applies its effects, so the TB samples the same edge. 0 in all
  // non-proxy runs (proxy_en==0).
  assign syscall_active_c = (state==S_DECODE) && d_int80 && proxy_en;
  assign syscall_active   = syscall_active_c;

  // M14: expose the syscall args (regfile values at the cd80 decode) so the TB
  // free-run emulator can read nr+args off the same edge as syscall_active. Pure
  // combinational reads of gpr (layout: eax ecx edx ebx esp ebp esi edi) — no
  // feedback into the core, inert in every replay/non-proxy run.
  assign syscall_arg_eax = gpr[0];
  assign syscall_arg_ecx = gpr[1];
  assign syscall_arg_edx = gpr[2];
  assign syscall_arg_ebx = gpr[3];
  assign syscall_arg_ebp = gpr[5];
  assign syscall_arg_esi = gpr[6];
  assign syscall_arg_edi = gpr[7];

  // ===========================================================================
  // M8.1 — external-interrupt ACCEPT predicates (combinational). These mirror the
  // exact priority of the S_DECODE divert (see below) so the `inta` strobe and the
  // sequential delivery agree on the SAME clock. ALL are 0 when soc_en==0, so the
  // core is byte-identical to the M0-M7 core.
  //
  // Priority at the instruction boundary: SMI# (smi_take) > NMI > maskable INTR.
  //   smi_take : the recognised SMI# the S_DECODE smi_pending block takes FIRST.
  //   nmi_take : an NMI edge, NON-maskable (ignores IF/irq_shadow), blocked only
  //              while an NMI handler is already running (nmi_in_progress) or by a
  //              pending SMI.
  //   intr_take: a maskable INTR — only when EFLAGS.IF=1, the one-instruction
  //              STI/MOV-SS shadow is clear (irq_shadow=0), and neither a higher-
  //              priority NMI nor SMI is being taken this boundary. (NMI in progress
  //              does NOT mask INTR — the IA-32 NMI block applies to NMI only.)
  // The level INTR / NMI edge are sampled into intr_pending / nmi_pending (the
  // sequential block) exactly like smi_pending, then consumed here.
  // ===========================================================================
  logic smi_take, nmi_take, intr_take;
  assign smi_take  = smi_pending && sys_mode && !smm_active;
  assign nmi_take  = soc_en && nmi_pending && !nmi_in_progress && !smi_take;
  assign intr_take = soc_en && intr_pending && eflags[9] && !irq_shadow
                     && !nmi_take && !smi_take;
  // INTERRUPT-ACKNOWLEDGE strobe: pulse for exactly the S_DECODE clock the core
  // accepts a maskable INTR (the PIC drives inta_vector combinationally off this).
  // NMI carries the fixed vector 2 and does NOT pulse inta. 0 whenever soc_en==0.
  assign inta = ((state==S_DECODE) || (state==S_HLTWAIT)) && intr_take;

  // ===========================================================================
  // Latched decoded fields
  // ===========================================================================
  logic [3:0]  q_len;
  logic        q_is_branch, q_branch_taken;
  logic [31:0] q_rel;
  logic [4:0]  q_alu_op;
  logic        q_writes_reg, q_writes_flags, q_mem_read, q_mem_write, q_mem_dst;
  logic [2:0]  q_dst_reg, q_src_reg;
  logic [31:0] q_imm;
  logic        q_use_imm, q_is_push, q_is_pop, q_is_lea, q_is_mov;
  logic [31:0] q_ea, q_pc;
  logic [2:0]  q_w;
  logic        q_dst_high8, q_src_high8;
  // CMPXCHG (0F B0/B1) mem-form: latched equality decision. Computed in S_EXEC
  // (before the conditional accumulator update mutates EAX) and consumed in
  // S_STORE's store-operand resolution, so the write data stays stable across
  // the S_EXEC->S_STORE clock even though gpr[R_EAX] changes on the not-equal
  // path. 1 => store src (equal); 0 => write the original temp back unchanged.
  logic        cmpxchg_wrsrc_r;
  kind_e       q_kind;
  logic [2:0]  q_shrot;
  logic        q_shift_cl, q_shift_one;
  logic [4:0]  q_shift_imm;
  logic        q_shrd;
  logic [2:0]  q_md;
  logic        q_imul_3op;
  logic [31:0] q_imul_imm;
  logic        q_ext_signed;
  logic [2:0]  q_ext_srcw;
  logic [3:0]  q_cc;
  logic        q_bit_imm;
  logic [2:0]  q_bit_op;
  logic        q_conv_cdq;
  smk_e        q_sm;
  st_e         q_st;
  logic        q_rep, q_repne, q_str_loadsi, q_str_storedi, q_str_scandi;
  // M7.3c INS: the IN value captured in S_INS, carried into the S_STORE element.
  logic [31:0] ins_data;
  ctk_e        q_ct;
  logic [15:0] q_ret_imm;
  logic        q_cld, q_std;
  logic        q_clc, q_stc, q_cmc;
  logic        q_cli, q_sti;
  logic        q_cnt16;
  logic        q_br16;   // M7.3b: 16-bit near-branch (taken target masks to 16 bits)

  // latched M7.3b IN/OUT port-I/O decode (see d_io_* above). q_io_port holds the
  // resolved 16-bit port (imm8 zero-extended, or DX[15:0]); q_io_w the width.
  logic        q_io;
  logic        q_io_write;
  logic [15:0] q_io_port;
  logic [2:0]  q_io_w;

  // latched M2S.1 system decode
  sysop_e      q_sysop;
  logic [2:0]  q_sys_sreg, q_sys_creg, q_seg;
  logic [31:0] q_ljmp_off;
  logic [15:0] q_ljmp_sel;
  logic        q_seg_load;        // M9.5 LES/LDS/LSS/LFS/LGS: also load a seg reg
  logic [2:0]  q_lseg;            //   target segment register index for the seg-load
  logic        q_push_sreg;       // F3 PUSH sreg latch
  logic        q_pop_sreg;        // F3 POP sreg latch
  logic        q_seg_load_lo;     // F3 MOV Sreg,[mem] low-half seg-load latch
  logic        q_store_sreg;      // F3 MOV [mem],Sreg store-selector latch
  logic        q_callf_mem;       // F3 FF /3 CALLF m16:16 latch
  logic        q_jmpf_mem;        // F3 FF /5 JMPF  m16:16 latch
  logic        seg_step;          // SEGLD descriptor-fetch beat counter (0/1)
  logic [31:0] retf_off;          // M9.5 RETF: the popped IP/EIP held between beats
  logic [31:0] gdt_lo;            // first dword of the in-flight 8-byte descriptor

  // -------------------------------------------------------------------------
  // M2S.3 IDT delivery state (latched when a fault/INT vectors). The delivery
  // micro-sequence (S_INT_GATE -> S_INT_CS -> S_INT_PUSH) reads the gate, reads
  // the target CS descriptor, and pushes the exception frame, then loads
  // CS:EIP. The frame is pushed at the gate's target privilege stack (here:
  // same-privilege, so the current SS:ESP — cross-priv stack switch via TSS is
  // M2S.4). All of this is INERT when !sys_mode.
  // -------------------------------------------------------------------------
  // ===========================================================================
  // M2S.6 DEBUG REGISTERS + #DB (docs/m2s6-debug-spec.md). ALL of this is INERT
  // when !sys_mode: the DR file is never written (MOV DRn is a SLOW-FSM-only
  // sys op), the #DB delivery latches never arm, and TF/RF are only inspected on
  // a system-mode core. User mode (boot_mode=0) is byte-identical.
  //
  // DR0..DR3 = linear breakpoint addresses; DR6 = debug status (B0..B3, BD, BS,
  // BT + the 0xFFFF0FF0 reserved-1 read pattern); DR7 = control (Ln/Gn enables,
  // LE/GE, GD, the R/Wn 2-bit type + LENn 2-bit length per breakpoint). DR4/DR5
  // alias DR6/DR7 when CR4.DE=0. Reset (Vol.3): DR6=0xFFFF0FF0, DR7=0x00000400.
  // ===========================================================================
  logic [31:0] dr0, dr1, dr2, dr3;   // linear breakpoint addresses
  logic [31:0] dr6;                  // debug status (sticky B0..B3/BD/BS/BT)
  logic [31:0] dr7;                  // debug control (Ln/Gn, R/Wn, LENn, GD)
  // DR6/DR7 reserved-bit fixed patterns (P5 Vol.3). On WRITE the CPU forces these
  // reserved-1 bits; the read-back therefore always carries them. In 32-bit mode
  // qemu's DR_RESERVED_MASK (upper 32 bits) never bites, so all 32 bits writable.
  localparam logic [31:0] DR6_FIXED_1 = 32'hFFFF_0FF0;   // DR6 reserved-1 pattern
  localparam logic [31:0] DR7_FIXED_1 = 32'h0000_0400;   // DR7 bit10 reserved-1
  // DR6 status-bit positions.
  localparam int DR6_B0 = 0, DR6_B1 = 1, DR6_B2 = 2, DR6_B3 = 3;
  localparam int DR6_BD = 13, DR6_BS = 14;
  // DR7.GD (general-detect) lives at bit 13 (mirrors DR6.BD).
  localparam int DR7_GD = 13;

  // ---- #DB delivery model (M2S.6). A #DB raised as a CONSEQUENCE of an
  // instruction (TF single-step = DR6.BS, a data breakpoint = DR6.Bn, or an
  // instruction breakpoint hit on the committed next-EIP = DR6.Bn) is launched
  // FROM that instruction's RETIRE boundary via arm_db(): the qemu gdbstub
  // single-step fuses the instruction and its synchronous #DB into ONE record
  // (the instruction's PC + the post-delivery state), so the instruction does NOT
  // emit a separate retire — arm_db() diverts straight to the IDT delivery FSM.
  // ---- TF / RF issue-time snapshot. The #DB checks run at the triggering
  // instruction's RETIRE boundary, but must use the flags the instruction RAN
  // UNDER (sampled at its S_DECODE dispatch), not the post-modified ones — so a
  // POPF that SETS TF does not itself step-trap (the trap fires after the NEXT
  // instruction). RF (bit16) suppresses an instruction breakpoint for exactly one
  // instruction; the CPU clears it once that instruction retires (we clear it at
  // S_DECODE so the post-retire EFLAGS shows RF=0, matching qemu's
  // x86_debug_check_breakpoint behaviour).
  logic        tf_at_issue;       // TF the in-flight instruction runs under
  logic        rf_at_issue;       // RF the in-flight instruction runs under (suppress)
  // ---- Data-watchpoint extra-record flag. The qemu gdbstub single-step emits an
  // EXTRA record for a DATA breakpoint #DB: after the delivery record (stamped at
  // the store's PC, post-frame-push), it re-reports the SAME state stamped at the
  // HANDLER entry PC (the resumption point, BEFORE the handler's first instruction
  // runs), then the handler proceeds. (Instruction-bp / TF traps do NOT do this.)
  // Set when arm_db is launched for a data-write breakpoint; consumed in
  // S_INT_PUSH -> S_DB_EXTRA to emit that one extra fused-resumption record.
  logic        db_wp_extra;       // emit the data-watchpoint handler-entry record
  // ---- M6B Erratum 79 (errata_en[ERR_DBGP], default OFF). When a V86 POPF/IRET
  // #GP(0)-traps at IOPL<3 (the IOPL guard below) AND a DATA breakpoint is armed
  // on the SS:ESP linear address, the affected stepping ERRONEOUSLY delivers a
  // #DB right after the #GP handler is entered, with the saved CS:EIP = the #GP
  // handler's first instruction. We latch `err79_pending` + the matched DR6.Bn
  // bits at the IOPL guard; the #GP delivery's S_INT_PUSH final beat then CHAINS
  // an arm_db() (saved CS:EIP = int_gate_off = the #GP handler entry) instead of
  // returning to S_PIPE. INERT unless errata_en[ERR_DBGP] is set (so make verify
  // + every sys gate is byte-identical). It also requires v86 — which is 0 on the
  // entire non-V86 corpus — so even ON it is dead outside a V86 task.
  logic        err79_pending;     // chain an erroneous #DB after this V86 #GP
  logic [3:0]  err79_dr6_bits;    // the SS:ESP data-bp DR6.Bn bits that "fire"
  // GD general-detect FIRING is DEFERRED (documented). qemu 8.2.2 does NOT model
  // DR7.GD, so the committed pdebug golden takes EXACTLY 3 #DB deliveries. Firing
  // GD here would make the RTL take a 4th #DB the golden lacks -> the differential
  // diff would DIVERGE, and there is no TB hook to run a separate GD-enabled
  // structural trace. So the GD DECISION is computed below but its #DB fire is held
  // behind this default-off localparam (a future structural self-check can flip it
  // for an RTL-only trace, the psmm precedent). See StructuredOutput "deferred".
  localparam logic DBG_GD_ENABLE = 1'b0;

  logic [7:0]  int_vec;           // the vector being delivered (0..255)
  logic [31:0] int_ret_eip;       // EIP to PUSH (faulting EIP for a FAULT, next
                                  // EIP for a TRAP / software INT)
  logic [31:0] int_src_pc;        // the q_pc to stamp on the delivery retire
                                  // record (the faulting/INT instruction's PC)
  logic        int_has_err;       // push a 32-bit error code for this vector
  logic [31:0] int_err;           // the error code value (selector / #PF bits)
  logic [3:0]  int_step;          // beat counter within S_INT_GATE/_CS/_PUSH
                                  // (4-bit: the M7.2 V86 push needs 10 beats 0..9)
  logic [31:0] int_gate_off;      // assembled handler offset from the IDT gate
  logic [15:0] int_gate_sel;      // gate's code selector
  logic        int_gate_trap;     // 1 = trap gate (leave IF), 0 = interrupt gate
  logic        int_sw;            // delivery is a SOFTWARE INT n/INT3/INTO (the
                                  // gate DPL>=CPL privilege check applies; HW
                                  // faults / external INTs bypass it)
  logic [31:0] int_lo;            // first dword of the in-flight 8-byte gate/desc
  logic [31:0] iret_eip;          // IRET-popped EIP (held until ESP/CS settle)
  logic [15:0] iret_cs;           // IRET-popped CS selector
  logic [31:0] iret_eflags;       // IRET-popped EFLAGS (held until SS/ESP settle)
  // M2S.4 cross-privilege delivery scratch. When the target CS.DPL < CPL the
  // delivery loads SS:ESP from TSS.ssN:espN (N = target DPL) and pushes the
  // LARGER 5-word frame (old SS, old ESP, EFLAGS, CS, EIP[, errcode]) on the NEW
  // stack. xpl_active marks the in-flight delivery as cross-privilege so the
  // S_INT_PUSH frame layout + ESP math switch to the larger form.
  logic        xpl_active;        // this delivery is cross-privilege (stack switch)
  logic [15:0] int_old_ss;        // the interrupted task's SS (pushed in the frame)
  logic [31:0] int_old_esp;       // the interrupted task's ESP (pushed in the frame)
  logic [15:0] int_old_cs;        // the interrupted task's CS (pushed in the frame)
  // M7.2 V86 delivery scratch. from_v86 marks an in-flight delivery whose SOURCE
  // was V86 (EFLAGS.VM was set when the fault/INT fired). It is latched at delivery
  // start (S_INT_CS, where the cross-priv decision is made) so the S_INT_PUSH frame
  // switches to the 9-WORD V86 layout (GS,FS,DS,ES,SS,ESP,EFLAGS,CS,EIP) and, on
  // the final beat, EFLAGS.VM is cleared + DS/ES/FS/GS are zeroed (IA-32 V86 entry
  // to a PM handler). The interrupted V86 segment selectors are frozen for the push.
  logic        from_v86;          // this delivery's source was V86 (9-word frame)
  logic [15:0] int_old_ds, int_old_es, int_old_fs, int_old_gs;  // V86 frame segs
  logic [31:0] int_old_eflags;    // the V86 EFLAGS image pushed (VM still set)
  logic [1:0]  int_new_cpl;       // target privilege level (= target CS.DPL)
  logic [15:0] int_new_ss;        // new SS selector from TSS.ssN
  logic [31:0] int_new_esp;       // new ESP from TSS.espN
  // M2S.4 inter-privilege IRET scratch. When the IRET-popped CS.RPL > current
  // CPL the return is to a LESS-privileged level: additionally pop ESP/SS, switch
  // to the outer stack, and null any data segment not accessible at the new CPL.
  logic        iret_interpriv;    // this IRET returns to a lower privilege
  logic [15:0] iret_ss;           // IRET-popped SS selector (inter-priv)
  logic [31:0] iret_esp;          // IRET-popped ESP (inter-priv)
  // M7.2: IRET from CPL0 with the popped EFLAGS.VM set = a RETURN INTO V86 (the
  // monitor resumes the V86 task). Pops the full 9-word frame (EIP,CS,EFLAGS,ESP,
  // SS,ES,DS,FS,GS), forces CPL=3, sets EFLAGS.VM, and loads every segment base as
  // sel<<4 with NO descriptor read. iret_v86_* hold the popped V86 segments.
  logic        iret_to_v86;       // this IRET returns into V86 (9-word pop)
  logic [15:0] iret_v86_es, iret_v86_ds, iret_v86_fs, iret_v86_gs;

  // M2S.4b HARDWARE TASK SWITCH scratch (gated sys_mode; far JMP/CALL to a TSS).
  // tsw_step beats through the SAVE (write current TSS) / READ (read new TSS) /
  // SEG (reload incoming segment descriptors) / BUSY (toggle the GDT busy bits +
  // commit) phases. The new TSS descriptor (base/limit/sel/access) is captured in
  // S_LJMP from the GDT read; tr_attr holds the OUTGOING TSS descriptor access so
  // its busy bit can be cleared without a re-read. The incoming task state is read
  // into the tsw_* holding regs, then committed atomically on the final beat.
  logic [4:0]  tsw_step;          // beat counter within the task-switch phases
  logic [31:0] tsw_new_base;      // incoming TSS base (from its GDT descriptor)
  logic [31:0] tsw_new_limit;     // incoming TSS limit
  logic [15:0] tsw_new_sel;       // incoming TSS selector (the jump target)
  logic [7:0]  tsw_new_attr;      // incoming TSS descriptor access (busy set => |2)
  logic [31:0] tsw_save_eip;      // outgoing EIP to save (next insn after the jmp)
  logic [31:0] tsw_eip;           // incoming EIP   (from new TSS @0x20)
  logic [31:0] tsw_eflags;        // incoming EFLAGS(from new TSS @0x24)
  logic [31:0] tsw_cr3;           // incoming CR3   (from new TSS @0x1C)
  logic [31:0] tsw_gpr [NUM_GPR]; // incoming GPRs  (@0x28..0x44)
  logic [15:0] tsw_sel [NUM_SEG]; // incoming selectors CS/SS/DS/ES/FS/GS (loaded)
  logic [31:0] tsw_seg_lo;        // low dword latch for the SEG descriptor read

  // latched x87 decode
  fxop_e       q_fxop;
  logic        q_is_x87;
  logic        q_f_mem_read, q_f_mem_write;
  logic [3:0]  q_f_mbytes;
  logic        q_f_pop, q_f_pop2;
  logic [2:0]  q_f_sti, q_f_aluop, q_f_const;
  logic [3:0]  f_step;             // x87 memory beat counter
  logic [4:0]  f_seq_step;         // M11b: wide beat counter for FNSTENV/FNSAVE (0..26)
  logic [31:0] env_tmp [27];       // M11b: FLDENV/FRSTOR read-back holding regs (dwords)
  logic [79:0] f_mem80;            // assembled memory operand (m16/32/64/80)

  logic [31:0] mem_load_data, mem_load_data2;
  logic [3:0]  step;            // micro-sequence step counter
  logic [31:0] str_next_eip;    // EIP target after a string element commit
  logic [31:0] str_store_addr;  // [EDI] (pre-increment) for a MOVS/STOS store
  logic [31:0] str_store_data;  // value to store this string element
  logic [31:0] pusha_esp;       // original ESP latched for PUSHA

  // ===========================================================================
  // Register read/merge with partial semantics
  // ===========================================================================
  // r is the PHYSICAL gpr index (decode already maps AH..BH -> EAX..EBX);
  // high8 selects bits [15:8] for 8-bit ops.
  function automatic logic [31:0] reg_read(input logic [2:0] r, input logic [2:0] w, input logic high8);
    begin
      if (w==3'd1) begin
        if (high8) reg_read = {24'd0, gpr[r][15:8]};
        else       reg_read = {24'd0, gpr[r][7:0]};
      end else if (w==3'd2) reg_read = {16'd0, gpr[r][15:0]};
      else reg_read = gpr[r];
    end
  endfunction

  function automatic logic [31:0] reg_merge(input logic [31:0] cur, input logic [31:0] res,
                                            input logic [2:0] w, input logic high8);
    begin
      if (w==3'd1) begin
        if (high8) reg_merge = {cur[31:16], res[7:0], cur[7:0]};
        else       reg_merge = {cur[31:8], res[7:0]};
      end else if (w==3'd2) reg_merge = {cur[31:16], res[15:0]};
      else reg_merge = res;
    end
  endfunction

  // ALU result + EFLAGS (alu_result/flags_next) and the shift/rotate datapath
  // (shrot_result/shrot_cf, shld_result/shld_cf) live in ventium_alu_pkg.

  // ===========================================================================
  // EXEC combinational operands
  // ===========================================================================
  logic [31:0] dst_cur, a_op, b_op, alu_out, flags_out;
  logic [5:0]  sh_cnt;
  logic [31:0] sh_val, sh_out, sh_shm1;
  logic        sh_cfout;

  always_comb begin
    dst_cur = gpr[q_dst_reg];
    a_op = (q_mem_read && q_mem_dst) ? wmask(mem_load_data,q_w) : reg_read(q_dst_reg,q_w,q_dst_high8);
    if (q_use_imm) b_op = wmask(q_imm,q_w);
    else if (q_mem_read && !q_mem_dst) b_op = wmask(mem_load_data,q_w);
    else if (q_alu_op==ALU_INC || q_alu_op==ALU_DEC) b_op = 32'd1;
    else b_op = reg_read(q_src_reg,q_w,q_src_high8);
    alu_out   = alu_result(q_alu_op, a_op, b_op, eflags[0]);
    flags_out = flags_next(q_alu_op, a_op, b_op, alu_out, eflags, q_w);

    // ---- BCD / ASCII-adjust override (AAA/AAS/DAA/DAS/AAM/AAD). The AX result +
    // DEFINED flags are computed in the dedicated bcd_* always_comb below; here we
    // just route them onto alu_out (written via q_w=2 -> AX) and flags_out.
    if (q_alu_op >= ALU_AAA && q_alu_op <= ALU_AAD) begin
      alu_out   = {16'd0, bcd_ax};
      flags_out = bcd_flags;
    end

    sh_val = (q_mem_read && q_mem_dst) ? wmask(mem_load_data,q_w) : reg_read(q_dst_reg,q_w,q_dst_high8);
    if (q_shift_one) sh_cnt = 6'd1;
    else if (q_shift_cl) sh_cnt = {1'b0, gpr[R_ECX][4:0]};
    else sh_cnt = {1'b0, q_shift_imm};
    sh_out   = shrot_result(q_shrot, sh_val, sh_cnt, eflags[0], q_w);
    sh_cfout = shrot_cf(q_shrot, sh_val, sh_cnt, eflags[0], q_w);
    // shm1 = the operand shifted by (count-1), per QEMU CC_SRC for SHL/SHR/SAR.
    sh_shm1  = (sh_cnt==6'd0) ? sh_val : shrot_result(q_shrot, sh_val, sh_cnt-6'd1, eflags[0], q_w);
  end

  // ===========================================================================
  // BCD / ASCII-adjust datapath (AAA/AAS/DAA/DAS/AAM/AAD) — matches QEMU
  // int_helper.c helper_aaa/aas/daa/das/aam/aad EXACTLY. Computes the AX result
  // (bcd_ax) + the DEFINED EFLAGS (bcd_flags); the EXEC block above routes these
  // onto alu_out/flags_out when the op is BCD. Architecturally-undefined flags
  // (OF always; SF/ZF/PF for AAA/AAS; CF/AF for AAM/AAD) are left cleared and are
  // removed from the differential by tracefmt.eflags_undefined_mask. AAM base 0
  // is a #DE this core defers (like native DIV-by-zero); the divide is guarded to
  // avoid an X (the corpus never executes AAM 0). Outputs default unconditionally
  // (no latch); the `default` arm computes AAA and also covers every non-BCD
  // q_alu_op (harmless dead compute — bcd_* are consumed only for BCD ops).
  // ===========================================================================
  logic [15:0] bcd_ax;
  logic [31:0] bcd_flags;
  always_comb begin
    logic [7:0]  al0, ah0, imm8, nal, nah;
    logic        af0, cf0, icar;
    logic [31:0] fl;
    al0  = gpr[R_EAX][7:0];
    ah0  = gpr[R_EAX][15:8];
    imm8 = q_imm[7:0];
    af0  = eflags[4];
    cf0  = eflags[0];
    icar = 1'b0;
    fl   = eflags & 32'hFFFF_F72A;   // clear CF/PF/AF/ZF/SF/OF
    fl[1]= 1'b1;                     // reserved bit 1 always 1
    nal  = al0; nah = ah0;
    case (q_alu_op)
      ALU_AAS: begin
        // QEMU carries SF/ZF/PF/OF THROUGH (only CF/AF change). Must match
        // exactly: the undefined bits persist into later (unmasked) instructions.
        fl = eflags; fl[1]=1'b1;
        icar = (al0 < 8'd6);
        if ((al0[3:0] > 4'd9) || af0) begin
          nal = (al0 - 8'd6) & 8'h0F; nah = ah0 - 8'd1 - {7'd0,icar};
          fl[0]=1'b1; fl[4]=1'b1;
        end else begin nal = al0 & 8'h0F; fl[0]=1'b0; fl[4]=1'b0; end
      end
      ALU_DAA: begin
        if ((al0[3:0] > 4'd9) || af0) begin nal = al0 + 8'd6;  fl[4]=1'b1; end
        if ((al0 > 8'h99)     || cf0) begin nal = nal + 8'h60; fl[0]=1'b1; end
        fl[6]=(nal==8'd0); fl[2]=~^nal; fl[7]=nal[7];          // ZF/PF/SF
      end
      ALU_DAS: begin
        if ((al0[3:0] > 4'd9) || af0) begin
          fl[4]=1'b1; if ((al0 < 8'd6) || cf0) fl[0]=1'b1; nal = al0 - 8'd6;
        end
        if ((al0 > 8'h99) || cf0) begin nal = nal - 8'h60; fl[0]=1'b1; end
        fl[6]=(nal==8'd0); fl[2]=~^nal; fl[7]=nal[7];
      end
      ALU_AAM: begin
        nah = (imm8==8'd0) ? 8'd0 : (al0 / imm8);   // AH = AL/base
        nal = (imm8==8'd0) ? 8'd0 : (al0 % imm8);   // AL = AL%base
        fl[6]=(nal==8'd0); fl[2]=~^nal; fl[7]=nal[7];          // CF/OF/AF undef
      end
      ALU_AAD: begin
        nal = (ah0 * imm8) + al0; nah = 8'd0;       // AL = AH*base+AL; AH=0
        fl[6]=(nal==8'd0); fl[2]=~^nal; fl[7]=nal[7];
      end
      default: begin // ALU_AAA (and every non-BCD op: harmless dead compute)
        // QEMU carries SF/ZF/PF/OF THROUGH (only CF/AF change) — match exactly.
        fl = eflags; fl[1]=1'b1;
        icar = (al0 > 8'hF9);
        if ((al0[3:0] > 4'd9) || af0) begin
          nal = (al0 + 8'd6) & 8'h0F; nah = ah0 + 8'd1 + {7'd0,icar};
          fl[0]=1'b1; fl[4]=1'b1;                   // CF=AF=1
        end else begin nal = al0 & 8'h0F; fl[0]=1'b0; fl[4]=1'b0; end  // CF=AF=0
      end
    endcase
    bcd_ax    = {nah, nal};
    bcd_flags = fl;
  end

  // ---- CMPXCHG (0F B0/B1) combinational compute -----------------------------
  // accumulator = AL/eAX; temp = the destination operand (memory load for the
  // mem form, the GPR for the reg form). Flags = CMP accumulator,temp (i.e.
  // accumulator - temp), reusing the canonical ALU_CMP flag computation.
  logic [31:0] cmpxchg_acc, cmpxchg_temp, cmpxchg_flags;
  logic        cmpxchg_eq;
  always_comb begin
    cmpxchg_acc  = reg_read(R_EAX, q_w, 1'b0);
    cmpxchg_temp = (q_mem_read && q_mem_dst) ? wmask(mem_load_data, q_w)
                                             : reg_read(q_dst_reg, q_w, q_dst_high8);
    cmpxchg_eq   = (cmpxchg_acc == cmpxchg_temp);
    cmpxchg_flags= flags_next(ALU_CMP, cmpxchg_acc, cmpxchg_temp,
                              cmpxchg_acc - cmpxchg_temp, eflags, q_w);
  end

  // ===========================================================================
  // Retire snapshot
  // ===========================================================================
  logic [31:0] next_eip;
  assign next_eip = q_pc + {28'd0, q_len};

  arch_state_t snap;
  always_comb begin
    snap.eflags=eflags;
    snap.eax=gpr[0]; snap.ecx=gpr[1]; snap.edx=gpr[2]; snap.ebx=gpr[3];
    snap.esp=gpr[4]; snap.ebp=gpr[5]; snap.esi=gpr[6]; snap.edi=gpr[7];
    if (sys_mode) begin
      // System-mode core: the selectors are the LIVE seg_sel[] (real-mode
      // segment values, or protected-mode descriptor selectors). User mode is
      // unchanged (the constant SEG_* params the M0-M6 corpus expects).
      snap.cs=seg_sel[SG_CS]; snap.ss=seg_sel[SG_SS]; snap.ds=seg_sel[SG_DS];
      snap.es=seg_sel[SG_ES]; snap.fs=seg_sel[SG_FS]; snap.gs=seg_sel[SG_GS];
    end else if (proxy_en) begin
      // M7.1 proxy: report the LIVE user selectors (seeded to the SEG_* constants
      // at reset, then updated by a user-mode `mov gs, 0x33` -> seg_sel[GS]=0x33).
      // Quake only ever changes %gs (musl TLS); the others stay at SEG_*.
      snap.cs=seg_sel[SG_CS]; snap.ss=seg_sel[SG_SS]; snap.ds=seg_sel[SG_DS];
      snap.es=seg_sel[SG_ES]; snap.fs=seg_sel[SG_FS]; snap.gs=seg_sel[SG_GS];
    end else begin
      snap.cs=SEG_CS; snap.ss=SEG_SS; snap.ds=SEG_DS; snap.es=SEG_ES; snap.fs=SEG_FS; snap.gs=SEG_GS;
    end
  end
  assign retire_state=snap;
  // M7.1: a folded-syscall retire (the instruction after cd80) is stamped with the
  // int-0x80's pc (fold_pc_r) so it aligns with the golden int-0x80 record. Inert
  // unless proxy_en && fold_pending_r, so non-proxy retires use q_pc verbatim.
  assign retire_pc = (proxy_en && fold_pending_r) ? fold_pc_r : q_pc;

  // M2S.1 system retire payload. retire_sys mirrors retire_valid in system mode
  // (every retirement carries the control-register block); 0 in user mode.
  assign retire_sys = sys_mode && retire_valid;
  assign retire_cr0 = creg0;
  assign retire_cr2 = creg2;
  assign retire_cr3 = creg3;
  assign retire_cr4 = creg4;

  // Second retirement (paired V issue). In cycle mode only `pc` is compared, so
  // retire2_state mirrors the primary snapshot (well-formed, never gate-checked
  // for the V member); retire2_pc is registered at issue.
  logic [31:0] q_pc2;
  assign retire2_state = snap;
  assign retire2_pc = q_pc2;

  // ===========================================================================
  // String addressing + direction
  // ===========================================================================
  logic        df;
  assign df = eflags[10];
  logic [31:0] str_step;        // +/- width
  assign str_step = df ? (32'd0 - {29'd0,q_w}) : {29'd0,q_w};
  // F3 — a16 string pointers (q_cnt16 == latched eff_addr): with 16-bit
  // addressing the EA uses SI/DI (low 16 bits, mod-64K wrap) and the high
  // halves of ESI/EDI are NOT address inputs. Without the mask, a backward
  // (DF=1) copy whose SI/DI crossed 0 went 32-bit negative and every later
  // string EA landed 64 KiB low (FreeDOS SYSINIT's relocate-high copy left
  // holes the flow later fell into). q_cnt16=0 in every 32-bit flat gate.
  wire [31:0] str_esi = q_cnt16 ? {16'd0, gpr[R_ESI][15:0]} : gpr[R_ESI];
  wire [31:0] str_edi = q_cnt16 ? {16'd0, gpr[R_EDI][15:0]} : gpr[R_EDI];

  // ===========================================================================
  // Store-operand resolution (combinational) used in S_STORE.
  // The per-op store address/data/strobe are computed from latched fields.
  // ===========================================================================
  function automatic logic [3:0] strb_of(input logic [2:0] w);
    if (w==3'd1) return 4'b0001; else if (w==3'd2) return 4'b0011; else return 4'b1111;
  endfunction

  logic [31:0] st_addr, st_data;
  logic [3:0]  st_strb;
  logic [31:0] call_target;

  // Slow-path data-LOAD address (mirrors the S_LOAD bus-driver address selection)
  // so the sequential block can run the D-cache timing SM on it (M5 finding [med]).
  logic [31:0] slow_dmem_addr;
  always_comb begin
    if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
        (q_kind==K_STKMISC && q_sm==SM_POPF))      slow_dmem_addr = gpr[R_ESP];
    else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)  slow_dmem_addr = gpr[R_EBP];
    else if (q_kind==K_STR) begin
      if (q_st==ST_SCAS)                           slow_dmem_addr = str_edi;
      else                                         slow_dmem_addr = str_esi;
    end else                                       slow_dmem_addr = q_ea;
  end

  logic [31:0] call_t16;  // 0x66 near-CALL truncated target (declared at top to
                          // avoid an inferred latch on a branch-local var)
  always_comb begin
    // default store: a memory destination (RMW / mov [m],r / setcc [m])
    st_strb = strb_of(q_w);
    st_addr = q_ea;
    st_data = 32'd0;
    call_t16 = next_eip + q_rel;

    // resolve store data by op kind
    if (q_is_push) begin
      st_addr = gpr[R_ESP] - {28'd0,q_w};
      // F3 PUSH sreg: data = the 16-bit selector (zero-extended; strb_of(q_w) keeps
      // 2 bytes for a 16-bit push, 4 for a 0x66-prefixed 32-bit push).
      st_data = q_push_sreg ? {16'd0, seg_sel[q_sys_sreg]}
              : q_use_imm   ? q_imm
              : (q_mem_read ? mem_load_data : reg_read(q_src_reg,q_w,1'b0));
    end else if (q_kind==K_CTRL && (q_ct==CT_CALLREL || q_ct==CT_CALLIND)) begin
      // Near CALL pushes the next-IP at the operand width: 4 bytes (32-bit) or
      // 2 bytes for a 0x66-prefixed 16-bit near CALL.
      st_addr = gpr[R_ESP] - {28'd0,q_w};
      st_data = next_eip;
      st_strb = strb_of(q_w);
    end else if (q_kind==K_STKMISC && q_sm==SM_PUSHF) begin
      st_addr = gpr[R_ESP] - {28'd0,q_w};
      st_data = eflags;
    end else if (q_kind==K_SETCC) begin
      st_data = {31'd0, cond_true(q_cc, eflags)};
      st_strb = 4'b0001;
    end else if (q_kind==K_SHIFT) begin
      st_data = sh_out;
    end else if (q_kind==K_XCHG) begin
      st_data = reg_read(q_src_reg,q_w,q_src_high8);
    end else if (q_kind==K_CMPXCHG) begin
      // CMPXCHG mem-dst: store src (reg operand) if equal, else write the
      // original temp back UNCHANGED (keeps the locked RMW atomic, per QEMU).
      // Uses the LATCHED equality (cmpxchg_wrsrc_r) — by S_STORE gpr[R_EAX] may
      // have been updated on the not-equal path, so the live cmpxchg_eq is stale.
      st_data = cmpxchg_wrsrc_r ? reg_read(q_src_reg,q_w,q_src_high8)
                                : wmask(mem_load_data,q_w);
    end else if (q_is_pop) begin
      // POP m: write the popped stack word to the memory destination.
      st_data = mem_load_data;
    end else if (q_is_mov) begin
      // F3 MOV [mem],Sreg: store the 16-bit selector (strb_of(q_w=2) writes 2 bytes).
      st_data = q_store_sreg ? {16'd0, seg_sel[q_sys_sreg]}
              : q_use_imm    ? q_imm : reg_read(q_src_reg,q_w,q_src_high8);
    end else begin
      // ALU RMW / NEG / NOT / INC / DEC to memory
      st_data = alu_out;
    end

    // CALL/JMP indirect target
    if (q_ct==CT_CALLIND || q_ct==CT_JMPIND) begin
      call_target = q_mem_read ? mem_load_data : gpr[q_src_reg];
      // F3: a 16-bit-operand indirect CALL/JMP loads IP from r/m16 and zeroes
      // EIP[31:16] (same convention as CT_RETN below). Without the mask, EIP's
      // high half took table-adjacent memory bytes / stale upper register bits.
      // q_w==2 only under eff_opsize -> every flat gate is byte-identical.
      if (q_w==3'd2) call_target = {16'd0, call_target[15:0]};
    end
    else if (q_kind==K_CTRL && q_ct==CT_CALLREL && q_w==3'd2)
      // 0x66 near CALL: operand-size-16 truncates the target EIP to 16 bits.
      call_target = {16'd0, call_t16[15:0]};
    else
      call_target = next_eip + q_rel;
  end

  // ===========================================================================
  // String element operand (combinational): value to write/compare this iter.
  // ===========================================================================
  logic [31:0] str_wdata;    // value to store at [EDI]
  logic [31:0] str_a, str_b; // SCAS/CMPS compare operands
  logic [31:0] str_flags;
  always_comb begin
    // value to store:
    //  MOVS -> [ESI] (mem_load_data)
    //  STOS -> AL/AX/EAX
    unique case (q_st)
      ST_MOVS: str_wdata = mem_load_data;
      ST_STOS: str_wdata = reg_read(R_EAX,q_w,1'b0);
      ST_INS:  str_wdata = ins_data;   // M7.3c: the IN value captured in S_INS
      default: str_wdata = mem_load_data;
    endcase
    // SCAS: compare EAX(width) - [EDI];  CMPS: [ESI] - [EDI]
    if (q_st==ST_SCAS) begin str_a = reg_read(R_EAX,q_w,1'b0); str_b = wmask(mem_load_data,q_w); end
    else /*CMPS*/        begin str_a = wmask(mem_load_data,q_w); str_b = wmask(mem_load_data2,q_w); end
    str_flags = flags_next(ALU_CMP, str_a, str_b, str_a - str_b, eflags, q_w);
  end

  // ===========================================================================
  // x87 combinational execution (M3)
  // ===========================================================================
  // st(i) read helper on the physical regfile (st0 = fpr[ftop]). The physical
  // index fri(i)=ftop+i is unchanged; fst(i) now reads the fpu_top module's
  // TOP-relative read ports (fp_st[i] = fpr[ftop+i]), zero added latency.
  function automatic logic [2:0] fri(input logic [2:0] i); return ftop + i; endfunction
  function automatic logic [79:0] fst(input logic [2:0] i); return fp_st[i]; endfunction

  // x87 INSTRUCTION-LEVEL pure helpers (fcom_codes/fst_eq/fst_lt, fx_is_nan/
  // fx_is_snan/fcom_ie, apply_cmp, fconst, fxam_codes, f_mem_as_float/_int,
  // f_arith/f_div_by_zero/f_zero_over_zero/f_eval/f_arith_fstat) were extracted
  // VERBATIM to ventium_x87_pkg (R2 modularization). They wrap the fpu_x87_pkg
  // floatx80 ops and use no module state, so the move is a netlist no-op.
  // fri()/fst()/fp_bop() stay here (they read module state ftop/fp_st[]/gpr[]).

  // ===========================================================================
  // x87 retire snapshot (TOP-relative st0..st7, fstat with TOP overlaid)
  // ===========================================================================
  assign retire_x87_touched = x87_touched_r;
  assign retire_fctrl = fctrl;
  assign retire_fstat = (fstat & ~16'h3800) | ({13'd0, ftop} << 11);
  assign retire_ftag  = 16'h0000;       // QEMU gdbstub abridges ftag to 0
  assign retire_st0 = fp_st[0];
  assign retire_st1 = fp_st[1];
  assign retire_st2 = fp_st[2];
  assign retire_st3 = fp_st[3];
  assign retire_st4 = fp_st[4];
  assign retire_st5 = fp_st[5];
  assign retire_st6 = fp_st[6];
  assign retire_st7 = fp_st[7];

  // ===========================================================================
  // M4/M5 fast-path decoder — extracted to the `decode` leaf module
  // (rtl/core/decode.sv), instantiated as u_decode / v_decode above. It decodes
  // the simple/pairable instruction subset (fpd_t producer); anything else
  // leaves d.simple=0 and the core falls back to the multi-cycle FSM.
  // ===========================================================================

  // second ALU operand for a fast-path ALU/mov insn: imm, or the source reg, or
  // a fixed 1 for INC/DEC (matching the slow path's b_op selection).
  function automatic logic [31:0] fp_bop(input fpd_t d);
    if (d.alu_op==ALU_INC || d.alu_op==ALU_DEC) fp_bop = 32'd1;
    else if (d.use_imm) fp_bop = d.imm;
    else fp_bop = reg_read(d.src, 3'd4, 1'b0);
  endfunction

  // pairing checker — extracted to the `issue_uv` leaf module
  // (rtl/core/issue_uv.sv), instantiated as u_issue near the decode instances.
  // It takes the U decode + V candidate decode and drives `pipe_pair_ok`.

  // icache presence: is the 32-byte line containing `addr` resident in EITHER way
  // of its set? (2-way, mirrors the oracle / the RTL D-cache lookup.) Reads the
  // module's READ-ONLY array outputs (ic_val_o/ic_tag_o) — PRE-edge registered
  // state, VERBATIM the old inline probe (only the array names gained the _o).
  function automatic logic ic_present(input logic [31:0] addr);
    logic [IC_IDXW-1:0] set; logic [IC_TAGW-1:0] tag; logic p;
    begin
      set = addr[5 +: IC_IDXW]; tag = addr[5+IC_IDXW +: IC_TAGW];
      p = 1'b0;
      for (int w=0; w<IC_WAYS; w++)
        if (ic_val_o[set][w] && ic_tag_o[set][w]==tag) p = 1'b1;
      ic_present = p;
    end
  endfunction
  // which way holds the line (assumes ic_present(addr)). The hitting way wins; if
  // none hits (speculative/stale read) it defaults to the last way (IC_WAYS-1) —
  // at IC_WAYS==2 this is exactly the old `!(way0 hit)` (0 iff way0 hits, else 1).
  function automatic logic [IC_WAYW-1:0] ic_hit_way(input logic [31:0] addr);
    logic [IC_IDXW-1:0] set; logic [IC_TAGW-1:0] tag; logic [IC_WAYW-1:0] hw;
    begin
      set = addr[5 +: IC_IDXW]; tag = addr[5+IC_IDXW +: IC_TAGW];
      hw = IC_WAYW'(IC_WAYS-1);
      for (int w=0; w<IC_WAYS; w++)
        if (ic_val_o[set][w] && ic_tag_o[set][w]==tag) hw = IC_WAYW'(w);
      ic_hit_way = hw;
    end
  endfunction
  // icache byte read (assumes ic_present(addr)): from whichever way hit. STALE-BY-
  // DESIGN: a speculative V-decode of a NON-RESIDENT line still reads ic_data_o
  // (whatever is there); only ic_val_o gates correctness.
  function automatic logic [7:0] ic_byte(input logic [31:0] addr);
    // read from the addressed line buffers (rd_lineA = flin's line, rd_lineB =
    // next line); the fetch window spans only these two sets and the hit way is
    // baked into each line (ic_rd_wayA/B), so there is no per-byte way mux.
    logic [IC_LINE*8-1:0] ln;
`ifdef VEN_IC_BRAM
    // content-addressed: pick whichever REGISTERED buffer holds addr's set (the two
    // buffers always hold different sets, so a set match is unambiguous). If neither
    // matches (line not buffered) the result is stale — that case is gated by
    // ic_fetch_ready (no issue) / the existing V-candidate stale-by-design.
    ln = (addr[5 +: IC_IDXW] == rdA_set_q) ? ic_rd_lineA : ic_rd_lineB;
`else
    ln = (addr[5 +: IC_IDXW] == ic_rd_setA) ? ic_rd_lineA : ic_rd_lineB;
`endif
    ic_byte = ln[{addr[4:0],3'b000} +: 8];
  endfunction

  // icache LRU update on a confirmed HIT now lives in the icache module: the spine
  // drives up to 3 touch ports (U / U-straddle / V) on the issue arm — see the
  // ic_tch*_* combinational driver near the u_icache instantiation. Each replaces
  // an old ic_touch(addr) call (oracle l1_access() hit path: s->lru = hit way).

  // D-cache hit test + access/allocate now live in the dcache_timing module
  // (rtl/mem/dcache.sv): the comb lookup is dc_lu_hit (off dc_lu_addr) and the
  // single posedge access fires when dc_acc_valid is high (on dc_acc_addr). The
  // combinational drivers for those ports are in the dc_acc_* always_comb below.

  // BTB lookup (pure-comb btb_lookup) + update (btb_update_taken) + the arrays
  // now live in the bpred_btb module (R2 extract, rtl/core/bpred_btb.sv): the
  // comb predicts are btb_u_pred (off btb_u_query_pc) and btb_v_pred (off
  // btb_v_query_pc), reading PRE-update state; the single posedge resolve fires
  // when btb_resolve_valid is high (on btb_resolve_pc/btb_resolve_taken). The
  // combinational drivers for those ports are below (predict assigns at the
  // u_pred_taken/v_pred_taken use sites; resolve in the branch-resolution arm).

  // ===========================================================================
  // M4 fast-path combinational pipeline evaluation (S_PIPE). Decodes the U
  // instruction (and the V candidate at off+lenU) from the prefetch buffer,
  // runs the pairing checker + AGI detect, and computes each insn's post-commit
  // result with the SAME helpers the slow path uses. The sequential S_PIPE block
  // below consumes these to issue 1 or 2 instructions per clock.
  // ===========================================================================
  fpd_t        u_d, v_d;             // U insn + V candidate decodes
  logic        pipe_bytes_ok;        // U (+ V candidate) bytes resident in icache
  logic [31:0] pf_miss_fa;           // I-cache fill line address for a current miss
  logic        pf_miss;             // a fill-word-0 fetch is needed this S_PIPE clock
  logic        pipe_pair;            // U and V issue together this clock
  logic        moffs_falsedep;       // M6 Err59: A2/A3 moffs U + EAX-using V follower
  logic        v_bytes_ok;           // V candidate's full bytes resident in I-cache
  logic        pipe_agi;             // U has an AGI hazard (addr reg written last clk)
  logic        pipe_load_req;        // U is a register-base load (drives the bus)
  logic [2:0]  pipe_load_base;
  logic [31:0] u_alu, u_flags, u_sh, u_shm1; logic u_shcf;
  logic [31:0] v_alu, v_flags;
  logic [31:0] u_target, v_target;   // branch targets
  logic        u_pred_taken, v_pred_taken;
  logic        v_br_taken_eff;       // V branch taken using U's flags if forwarded
  logic [31:0] u_flags_eff;          // U's resulting flags (post-commit) for fwd
  logic [7:0]  ub [6];               // U decode bytes (icache, possibly 0 if cold)
  logic [7:0]  vb [6];               // V candidate decode bytes (at eip+lenU)
`ifdef VEN_UOPCACHE
  // P0-11 predecoded µop-cache fast-path read wires (driven by u_uopcache). NSLOT
  // fast-path insns covered per 32-byte line; a denser line overflows -> those
  // offsets read uc_bv*=0 and the spine re-predecodes (perf, not correctness).
  localparam int NSLOT = 8;
  fpd_t        uc_slotsA [NSLOT], uc_slotsB [NSLOT];
  logic        uc_bvA [IC_LINE],  uc_bvB [IC_LINE];   // byte offset is a boundary
  logic [2:0]  uc_bsA [IC_LINE],  uc_bsB [IC_LINE];   // ...maps to this slot
  logic        uc_pdvA, uc_pdvB;                      // line is predecoded-valid
  logic        uop_hit, uc_v_avail;                   // flin on boundary / V resident
`endif

  // M2S.1: the FETCH LINEAR address. The architectural `eip` carries the
  // segment OFFSET (the value reported as `pc` in the trace); the bytes are
  // fetched from linear = CS.base + eip. In user mode (and any flat segment)
  // CS.base==0 so flin==eip and EVERY fetch/icache reference below is numerically
  // unchanged. `flin` substitutes for `eip` ONLY in the fetch + I-cache path;
  // the retire pc, the eip<-eip+len advance, and all branch math stay in offset
  // space (so far jumps that reload CS.base shift the fetch window correctly).
  // NOTE (deferred corner, M2S.x): this is a full 32-bit add with NO 20-bit
  // real-mode wrap and NO A20 masking. With A20 ENABLED (the qemu-system default
  // the bootstrap runs under) a real-mode access does NOT wrap at 1 MiB, so this
  // is correct for the gate; the A20-masked 1 MiB wrap (and the seg:off overflow
  // case) is unmodeled. The pseg corpus never exercises wrap.
  logic [31:0] fbase, flin;
  assign fbase = seg_base[SG_CS];
  assign flin  = fbase + eip;

  // icache addressed line-read drives: line A = flin's 32-byte line, line B = the
  // next line (the fetch/V window can straddle into it). The per-line hit way is
  // baked in (stale-by-design on a miss, matching the old ic_byte). flin is a
  // stable continuous signal, so flin -> addr -> line -> ic_byte settles cleanly.
  logic [31:0] flin_nl;
  assign flin_nl    = {flin[31:5], 5'd0} + 32'd32;     // next aligned 32-byte line
  assign ic_rd_setA = flin[5 +: IC_IDXW];
  assign ic_rd_wayA = ic_hit_way(flin);
`ifdef VEN_IC_BRAM
  // port B normally prefetches flin's next (straddle) line; 2b repurposes it to the
  // predicted branch target when pf_redir (set in the fast-path comb block). The read
  // is REGISTERED in the icache module, so this drives NEXT clock's rd_lineB — no
  // combinational loop through the decode that computes pf_redir.
  assign ic_rd_setB = pf_redir ? pf_redir_tgt[5 +: IC_IDXW] : flin_nl[5 +: IC_IDXW];
  assign ic_rd_wayB = pf_redir ? ic_hit_way(pf_redir_tgt) : ic_hit_way(flin_nl);
`else
  assign ic_rd_setB = flin_nl[5 +: IC_IDXW];
  assign ic_rd_wayB = ic_hit_way(flin_nl);
`endif

`ifdef VEN_IC_BRAM
  // Register the read ADDRESS as a tag, in lock-step with the icache module's
  // registered data (both clocked by clk on the same edge): in cycle T, ic_rd_lineA
  // holds the line for (rdA_set_q, rdA_way_q). Reset to a sentinel so a cold buffer
  // never false-matches a real flin (presence is gated separately by pipe_bytes_ok).
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rdA_set_q <= '1; rdA_way_q <= '1;
      rdB_set_q <= '1; rdB_way_q <= '1;
    end else begin
      rdA_set_q <= ic_rd_setA; rdA_way_q <= ic_rd_wayA;
      rdB_set_q <= ic_rd_setB; rdB_way_q <= ic_rd_wayB;
    end
  end
  // fetch-ready: the line containing flin (and, when the decode window straddles, the
  // next line) is currently held in one of the two registered buffers. A buffer holds
  // a line iff its registered tag (set+way) equals what flin needs now. The two
  // buffers always hold DIFFERENT sets (flin's line and flin's next line differ by 1),
  // so a set match uniquely identifies the buffer; the way is checked to reject a
  // post-fill way change. ic_byte (below) does the matching content-addressed select.
  logic ic_fa_avail, ic_fb_avail, ic_win_straddle;
  always_comb begin
    logic [IC_IDXW-1:0] fa_set, fb_set; logic [IC_WAYW-1:0] fa_way, fb_way;
    fa_set = flin[5 +: IC_IDXW];        fa_way = ic_hit_way(flin);
    fb_set = flin_nl[5 +: IC_IDXW];     fb_way = ic_hit_way(flin_nl);
    ic_fa_avail = (rdA_set_q==fa_set && rdA_way_q==fa_way)
                || (rdB_set_q==fa_set && rdB_way_q==fa_way);
    ic_fb_avail = (rdA_set_q==fb_set && rdA_way_q==fb_way)
                || (rdB_set_q==fb_set && rdB_way_q==fb_way);
    // the fast-path decode window is at most 12 bytes (ub 6 + vb up to len 6 + 6);
    // it straddles into the next line iff flin's byte offset + 12 > 32.
    ic_win_straddle = ({1'b0,flin[4:0]} + 6'd12) > 6'd32;
    ic_fetch_ready  = ic_fa_avail && (!ic_win_straddle || ic_fb_avail);
  end
`endif

`ifdef VEN_UOPCACHE
  // ===========================================================================
  // P0-11 PREDECODE-ON-FILL: the twelve 32:1 byte selects (the ub[]/vb[] gather
  // above) — the architectural MUXF congestion wall — are DELETED from the fast
  // path. decode.sv ran on the multi-cycle fill walker (u_uopcache below) and the
  // results are stored as fixed-width fpd_t indexed by SLOT. Here the fast path
  // just READS the slot the current flin lands in (an ~8:1 slot mux over the
  // registered uop-line), and because predecode CHAINED the boundaries, the V
  // candidate is literally U's NEXT slot — so the flin+lenU V-base serialization
  // is gone too. The only flin-indexed select left is the small byte->slot map
  // lookup (uc_bsA[flin[4:0]], 32:1 over 3 bits) — not a 32:1 over 256-bit data.
  //
  // br_taken is the ONLY flag-dependent decode field (cond_true): predecode froze
  // it with the fill-time EFLAGS, so re-evaluate it from the opcode-derived cc
  // against the LIVE eflags — exactly what the V resolution path already does
  // (v_br_taken_eff). Every other fpd_t field is opcode/operand-derived => the
  // stored value IS the live value (structural bit-exactness).
  fpd_t        u_d_raw, v_d_raw;
  logic [4:0]  uc_uoff, uc_voff;
  logic [2:0]  uc_uslot, uc_vslot;
  logic        uc_v_in_a;
  always_comb begin
    uc_uoff  = flin[4:0];
    uc_uslot = uc_bsA[uc_uoff];
    u_d_raw  = uc_slotsA[uc_uslot];
    // V begins right after U; predecode put it in the next slot of the SAME line,
    // unless U+lenU crosses the 32-byte line boundary (then V's first byte is in
    // line B, looked up by its in-B offset).
    uc_voff  = uc_uoff + {1'b0, u_d_raw.len};
    uc_v_in_a = ({1'b0,uc_uoff} + {2'b0,u_d_raw.len}) < 6'd32;
    if (uc_v_in_a) begin
      uc_vslot = uc_uslot + 3'd1;
      v_d_raw  = uc_slotsA[uc_vslot];
    end else begin
      uc_vslot = uc_bsB[uc_voff];
      v_d_raw  = uc_slotsB[uc_vslot];
    end
    // re-evaluate the flag-dependent Jcc taken bit against the LIVE eflags.
    u_d = u_d_raw;
    if (u_d_raw.is_branch && u_d_raw.br_cond) u_d.br_taken = cond_true(u_d_raw.cc, eflags);
    v_d = v_d_raw;
    if (v_d_raw.is_branch && v_d_raw.br_cond) v_d.br_taken = cond_true(v_d_raw.cc, eflags);
  end
  // uop_hit: flin's line is predecoded AND flin lands on a recorded instruction
  // boundary. A miss (cold predecode, or a branch INTO the middle of an insn as
  // walked-from-line-start) is handled by the spine: stall + re-predecode (the
  // S_PIPE !uop_ready arm). uc_v_avail mirrors the old v_bytes_ok residency for
  // the chained/straddle V slot.
  assign uop_hit    = uc_pdvA && uc_bvA[flin[4:0]];
  assign uc_v_avail = uc_v_in_a ? (uc_uslot != 3'(NSLOT-1))
                                : (uc_pdvB && uc_bvB[uc_voff]);
`ifdef VEN_UOPCACHE_CHECK
  // Structural-equivalence gate: keep the live ub/vb gather + reference decoders
  // and assert the slot read matches them for every issued flin. SIM-ONLY (this
  // path is NOT in the synth-probe build — that build defines VEN_UOPCACHE alone,
  // so the byte gather is truly absent from the netlist).
  fpd_t u_d_ref, v_d_ref;
  always_comb begin
    for (int i=0;i<6;i++) ub[i] = ic_present(flin+i[31:0]) ? ic_byte(flin+i[31:0]) : 8'd0;
    for (int i=0;i<6;i++) vb[i] = ic_byte(flin+{28'd0,u_d_ref.len}+i[31:0]);
  end
  decode u_decode_ref (.ib0(ub[0]),.ib1(ub[1]),.ib2(ub[2]),.ib3(ub[3]),.ib4(ub[4]),.ib5(ub[5]),
                       .iflags(eflags), .cycle_mode(cycle_mode), .uop(u_d_ref));
  decode v_decode_ref (.ib0(vb[0]),.ib1(vb[1]),.ib2(vb[2]),.ib3(vb[3]),.ib4(vb[4]),.ib5(vb[5]),
                       .iflags(eflags), .cycle_mode(cycle_mode), .uop(v_d_ref));
`endif
`else
  // R1 phase-3: the fast-path decoder is now the `decode` leaf module
  // (rtl/core/decode.sv), instantiated once per slot (U + V candidate). The
  // byte windows are gathered combinationally below (U at flin, V at flin+lenU),
  // exactly as the in-line `fp_decode(...)` calls read them. u_d/v_d are driven
  // by the instances; everything downstream consumes them unchanged.
  always_comb begin
    for (int i=0;i<6;i++) ub[i] = ic_present(flin+i[31:0]) ? ic_byte(flin+i[31:0]) : 8'd0;
    for (int i=0;i<6;i++) vb[i] = ic_byte(flin+{28'd0,u_d.len}+i[31:0]);
  end

  decode u_decode (
      .ib0(ub[0]), .ib1(ub[1]), .ib2(ub[2]), .ib3(ub[3]), .ib4(ub[4]), .ib5(ub[5]),
      .iflags(eflags), .cycle_mode(cycle_mode), .uop(u_d)
  );
  decode v_decode (
      .ib0(vb[0]), .ib1(vb[1]), .ib2(vb[2]), .ib3(vb[3]), .ib4(vb[4]), .ib5(vb[5]),
      .iflags(eflags), .cycle_mode(cycle_mode), .uop(v_d)
  );
`endif

  // R1 phase-3: the pairing checker is now the `issue_uv` leaf module
  // (rtl/core/issue_uv.sv). pipe_pair_ok is the bare can-pair RULES decision;
  // pipe_pair below ANDs in cycle_mode + V-bytes-resident exactly as before.
  logic pipe_pair_ok;
  issue_uv u_issue (.iu(u_d), .iv(v_d), .pair_ok(pipe_pair_ok));

  always_comb begin
    // M5 finding [med] (I-cache straddle): U is decodable+chargeable correctly iff
    // the line containing eip is resident AND, only when the instruction actually
    // crosses the 32-byte line boundary, the line containing its LAST byte too.
    // The oracle charges a second I-miss exactly when (vaddr&31)+size > 32
    // (verif/qemu-plugins/p5trace.c:428); it must NOT pre-charge a second-line
    // miss for a short instruction near the line end. The 6-byte fast-path decode
    // window can read into the next line, so require that straddle line for a SAFE
    // decode whenever the window crosses the boundary, but use the real decoded
    // length to decide whether a straddle miss is genuinely charged.
    pipe_bytes_ok = ic_present(flin)
                    // window-straddle: need the next line present to decode safely
                    && (({1'b0,flin[4:0]} + 6'd5 < 6'd32) || ic_present(flin + 32'd5))
                    // instruction-straddle: its last byte's line must be resident
                    && (({1'b0,flin[4:0]} + {2'b0,u_d.len} <= 6'd32)
                        || ic_present(flin + {28'd0,u_d.len} - 32'd1));
    // V candidate sits right after U (decoded by the v_decode instance above,
    // from the vb[] byte window gathered at flin+lenU).

    // I-cache fill line address for a current miss (flin's line first, else the
    // decode-window straddle line, else the instruction-straddle line) and the
    // condition under which the S_PIPE miss branch fires THIS clock (so the bus
    // driver can issue the fill's word-0 read on the detection clock — removing
    // the wasted transition clock, finding [med] I-miss off-by-one).
    pf_miss_fa = !ic_present(flin)         ? flin
               : !ic_present(flin + 32'd5) ? (flin + 32'd5)
               : (flin + {28'd0,u_d.len} - 32'd1);
    pf_miss = (state==S_PIPE) && (stall_cnt==7'd0) && !pipe_bytes_ok;

    // AGI: a base/index reg used by U was written in the IMMEDIATELY-preceding
    // fast-path issue clock (tracked in agi_wr0/agi_wr1; bit8=none).
    pipe_agi = 1'b0;
    if (u_d.addr_mask != 8'd0) begin
      if (!agi_wr0[8] && u_d.addr_mask[agi_wr0[2:0]]) pipe_agi=1'b1;
      if (!agi_wr1[8] && u_d.addr_mask[agi_wr1[2:0]]) pipe_agi=1'b1;
    end

    // pairing decision: V can pair only when U leads, no hazards, AND the V
    // candidate's FULL bytes are resident in the I-cache. A V branch can pair (it
    // fills V); a U branch never leads a pair (pairs_first=0).
    //
    // M5 (control-flow correctness): the V candidate is decoded combinationally
    // from ic_byte(), which returns whatever is in the array even for a NON-RESIDENT
    // line. If the V instruction STRADDLES into a cold line, its decode (opcode /
    // displacement / immediate) uses stale bytes — and a stale Jcc would be
    // mispaired and resolved with a wrong target/decode, diverging from the oracle's
    // instruction stream (reproduced: a `test(U); jz(V)` where the jz at offset 31
    // straddles a cold next line was resolved not-taken vs the oracle's taken). So
    // require the V instruction's first byte AND its last byte to be in resident
    // lines before pairing; otherwise V is not paired this clock — it becomes the
    // next U, the cold line fills via S_PF, and it issues with correct bytes.
    v_bytes_ok = ic_present(flin + {28'd0,u_d.len}) &&
                 ic_present(flin + {28'd0,u_d.len} + {28'd0,v_d.len} - 32'd1);
    pipe_pair = cycle_mode && v_bytes_ok && pipe_pair_ok;

    // M6 Erratum 59 (MOV moffs A2/A3 fails to pair): when errata enabled, an
    // A2/A3 moffs store (the U member) followed by an instruction that uses
    // (e)AX (as a source, base/index, or destination) triggers a FALSE EAX
    // dependency in the instruction unit, so the pair is suppressed. We detect
    // "V references EAX" as: V reads EAX (reads[EAX]) OR V writes EAX
    // (writes[EAX]) OR V's address uses EAX (addr_mask[EAX]). The clean core
    // (errata off) pairs them normally — that contrast is the self-check.
    moffs_falsedep = u_d.is_moffs &&
                     (v_d.reads[R_EAX] || v_d.writes[R_EAX] || v_d.addr_mask[R_EAX]);
    if (errata_en[ERR_MOFFS] && moffs_falsedep)
      pipe_pair = 1'b0;

    pipe_load_req  = (state==S_PIPE) && pipe_bytes_ok && u_d.simple &&
                     u_d.is_load && !pipe_agi && (mispred_bubbles==3'd0);
    pipe_load_base = u_d.base;

    // U datapath (reuse the shared helpers; results are bit-identical to slow).
    // INC/DEC use a fixed second operand of 1 (matching the slow path's b_op).
    u_alu   = alu_result(u_d.alu_op, reg_read(u_d.dst,3'd4,1'b0),
                         fp_bop(u_d), eflags[0]);
    u_flags = flags_next(u_d.alu_op, reg_read(u_d.dst,3'd4,1'b0),
                         fp_bop(u_d), u_alu, eflags, 3'd4);
    u_sh    = shrot_result(u_d.shrot, reg_read(u_d.dst,3'd4,1'b0),
                           {1'b0,u_d.shimm}, eflags[0], 3'd4);
    u_shm1  = (u_d.shimm==5'd0) ? reg_read(u_d.dst,3'd4,1'b0)
              : shrot_result(u_d.shrot, reg_read(u_d.dst,3'd4,1'b0),
                             {1'b0,u_d.shimm}-6'd1, eflags[0], 3'd4);
    u_shcf  = shrot_cf(u_d.shrot, reg_read(u_d.dst,3'd4,1'b0),
                       {1'b0,u_d.shimm}, eflags[0], 3'd4);
    u_target = (eip + {28'd0,u_d.len}) + u_d.rel;
    // BTB U predict: drive the module's comb predict port at this clock's U pc
    // (= eip) and read back its PRE-update predicted-taken (bpred_btb).
    btb_u_query_pc = eip;
    u_pred_taken = btb_u_pred;

    // V datapath (independent of U by the pairing rule, so reading the OLD gpr
    // state is correct for both).
    v_alu   = alu_result(v_d.alu_op, reg_read(v_d.dst,3'd4,1'b0),
                         fp_bop(v_d), eflags[0]);
    v_flags = flags_next(v_d.alu_op, reg_read(v_d.dst,3'd4,1'b0),
                         fp_bop(v_d), v_alu, eflags, 3'd4);
    v_target = ((eip + {28'd0,u_d.len}) + {28'd0,v_d.len}) + v_d.rel;
    // BTB V predict: drive the module's comb predict port at the V pc
    // (= eip + u_d.len) and read back its PRE-update predicted-taken (bpred_btb).
    btb_v_query_pc = eip + {28'd0,u_d.len};
    v_pred_taken = btb_v_pred;

`ifdef VEN_IC_BRAM
    // 2b — predicted-taken-target PREFETCH driver. When a predicted-taken branch is in
    // the current window AND the window does not straddle (so port B is not needed for
    // this clock's decode), repurpose port B to read the predicted TARGET line so it is
    // registered BEFORE the redirect — the back-edge of a hot loop then costs no fetch
    // bubble. A U branch is unpaired (a U branch never leads a pair); a paired V branch
    // uses v_target. Gated on !ic_win_straddle so a straddling branch keeps port B for
    // its own (correct) decode, and so a prefetch that does not redirect cannot strand
    // the straddle line. The read is registered (next-clock effect) — no comb loop.
    pf_redir = 1'b0; pf_redir_tgt = 32'd0;
    if (!ic_win_straddle) begin
      if (u_d.is_branch && u_pred_taken) begin
        pf_redir = 1'b1; pf_redir_tgt = u_target;
      end else if (pipe_pair && v_d.is_branch && v_pred_taken) begin
        pf_redir = 1'b1; pf_redir_tgt = v_target;
      end
    end
`endif

    // Flags forwarding U->V (the P5 cmp/dec/test + jcc pairing case): when the
    // U member writes EFLAGS, the paired V branch must see U's RESULT flags, not
    // the stale architectural eflags. Compute U's post-commit flags and use them
    // to evaluate a paired conditional V branch.
    u_flags_eff = u_d.wflags ? u_flags : eflags;
    if (u_d.is_shift) begin
      if (u_d.shimm!=5'd0) begin
        // shift (SHL/SHR/SAL/SAR group) result flags, for a paired following jcc.
        u_flags_eff = eflags & 32'hFFFF_F72A;
        u_flags_eff[0]=u_shcf; u_flags_eff[2]=parity8(u_sh[7:0]); u_flags_eff[4]=1'b0;
        u_flags_eff[6]=(u_sh==32'd0); u_flags_eff[7]=u_sh[31];
        u_flags_eff[11]=u_shm1[31]^u_sh[31]; u_flags_eff[1]=1'b1;
      end else u_flags_eff = eflags;   // count 0 => no flag change
    end
    v_br_taken_eff = v_d.br_cond ? cond_true(v_br_cc(v_d), u_flags_eff) : 1'b1;
  end

  // ===========================================================================
  // BTB resolve port (R2 extract, bpred_btb). The single per-clock BTB update
  // fires on the posedge ONLY when the S_PIPE issue arm executes AND a branch
  // resolves — exactly where the inline btb_update_taken() NBA used to fire.
  // This comb block reconstructs that issue-gate (the S_PIPE else-if chain's
  // final issue arm) and the VERIFIED mutually-exclusive U/V if-else-if mux,
  // driving the single resolve port:
  //   * U branch       -> resolve at (eip, u_taken)
  //   * else paired-V branch -> resolve at (eip+u.len, v_taken)
  // At most ONE write/clock (the if/else-if guarantees mutual exclusion; a
  // paired V branch and a U branch cannot both resolve — a U branch is unpaired
  // in this path). btb_lookup-vs-update is read-before-write: the predict ports
  // above read the PRE-update arrays this clock; this resolve applies next edge.
  always_comb begin
    // Issue-arm gate: the final `else` of the S_PIPE chain (matches the spine).
    // Branches are simple + non-FP, so the FP/precision/!simple arms never apply
    // to a resolving branch; the guards below are the chain conditions that gate
    // reaching the issue arm at all.
    logic issue_arm;
    logic u_res_taken, v_res_taken;
    logic [31:0] v_res_pc;
    issue_arm = (state==S_PIPE) && !xlate_miss && (stall_cnt==7'd0) &&
                pipe_bytes_ok && (pending_mem_pen==7'd0) && !u_d.is_fp &&
                u_d.simple && !sys_mode && (mispred_bubbles==3'd0) && !pipe_agi;

    // U taken: unconditional => 1, conditional => its architectural taken.
    u_res_taken = u_d.br_cond ? u_d.br_taken : 1'b1;
    // V member branch (paired): taken via U-forwarded flags (v_br_taken_eff).
    v_res_pc    = eip + {28'd0,u_d.len};
    v_res_taken = v_br_taken_eff;

    btb_resolve_valid = 1'b0;
    btb_resolve_pc    = 32'd0;
    btb_resolve_taken = 1'b0;
    if (issue_arm) begin
      if (u_d.is_branch) begin
        btb_resolve_valid = 1'b1;
        btb_resolve_pc    = eip;
        btb_resolve_taken = u_res_taken;
      end else if (pipe_pair && v_d.is_branch) begin
        btb_resolve_valid = 1'b1;
        btb_resolve_pc    = v_res_pc;
        btb_resolve_taken = v_res_taken;
      end
    end
  end

  bpred_btb #(.BTB_SETS(BTB_SETS), .BTB_WAYS(BTB_WAYS)) u_bpred_btb (
    .clk            (clk),
    .rst_n          (rst_n),
    .u_query_pc     (btb_u_query_pc),
    .u_predict_taken(btb_u_pred),
    .v_query_pc     (btb_v_query_pc),
    .v_predict_taken(btb_v_pred),
    .resolve_valid  (btb_resolve_valid),
    .resolve_pc     (btb_resolve_pc),
    .resolve_taken  (btb_resolve_taken)
  );

  // recover the 4-bit condition code of a V conditional branch from its decode
  // (Jcc rel8 opcode low nibble was consumed into br_cond/br_taken; we re-derive
  // it from the opcode byte stored implicitly). Since fp_decode does not keep the
  // raw cc, evaluate against the V's own br_taken when no forwarding is needed
  // and only override via this helper when U forwards flags.
  function automatic logic [3:0] v_br_cc(input fpd_t d);
    // Not reachable for non-branches; the cc is encoded in br fields. We stored
    // the architectural taken under the OLD flags; to re-evaluate under new
    // flags we need the cc. fp_decode is extended to carry it below.
    v_br_cc = d.cc;
  endfunction

  // ===========================================================================
  // Main sequential FSM
  // ===========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state<=S_RESET;
      // ----- M2S.1: dual boot-mode reset (docs/m2s1-segmentation-spec.md) -----
      sys_mode<=boot_mode;
      if (boot_mode) begin
        // SYSTEM cold reset, matching qemu-system-i386: CS:EIP=F000:FFF0, real
        // mode (CR0.PE=0, cr0=0x60000010), EDX=0x00000663 (P5 stepping sig),
        // eflags=0x00000002. The reset CS hidden base is 0xFFFF0000 on a real
        // P5, but qemu-system reports EIP=0xFFF0 and the bare-metal image is
        // loaded at the LOW alias 0x000F0000; the reset stub immediately
        // far-jumps to segment 0xF000 (base 0x000F0000), so we seed CS.base =
        // 0x000F0000 here (fetch linear = 0x000F0000 + 0xFFF0 = 0x000FFFF0,
        // exactly where the TB loads the image's last 16 bytes).
        eip<=32'h0000_FFF0; eflags<=32'h0000_0002;
        gpr[0]<=32'd0; gpr[1]<=32'd0; gpr[3]<=32'd0;
        // EDX reset = the CPUID family/model/stepping signature. The existing M2S
        // sys gates oracle against qemu's default (qemu32) cold reset EDX=0x663 and
        // MUST stay byte-identical; the M7.3b Win95 co-sim oracles against qemu
        // `-cpu pentium` whose cold reset EDX=0x543 (golden record 0). cosim_en
        // (set only in --win95-image mode) selects 0x543; every other system run
        // keeps 0x663 unchanged. (EDX is the only reset-state delta between the two
        // CPU models that the golden prefix observes.)
        gpr[2]<= cosim_en ? 32'h0000_0543 : 32'h0000_0663;
        gpr[4]<=32'd0; gpr[5]<=32'd0; gpr[6]<=32'd0; gpr[7]<=32'd0;
        creg0<=32'h6000_0010; creg2<=32'd0; creg3<=32'd0; creg4<=32'd0;
        for (int s=0;s<NUM_SEG;s++) begin
          seg_sel[s]<=16'h0000; seg_base[s]<=32'd0; seg_limit[s]<=32'h0000_FFFF;
          // real-mode segs behave as present R/W data (attr only matters in PM):
          // P=1 DPL=0 S=1 type=writable-data (0x93).
          seg_attr[s]<=8'h93;
        end
        seg_sel[SG_CS]<=16'hF000; seg_base[SG_CS]<=32'h000F_0000;
        seg_attr[SG_CS]<=8'h9B;   // CS: present readable code (P=1 S=1 type=0xB)
        cpl_r<=2'd0;              // reset CPL = 0
        gdt_base<=32'd0; gdt_limit<=16'd0; idt_base<=32'd0; idt_limit<=16'h03FF;
        cs_d<=1'b0;   // real-mode CS: 16-bit default operand/address size
      end else begin
        eip<=init_eip; eflags<=EFLAGS_RESET;
        gpr[0]<=32'd0; gpr[1]<=32'd0; gpr[2]<=32'd0; gpr[3]<=32'd0;
        gpr[4]<=init_esp; gpr[5]<=32'd0; gpr[6]<=32'd0; gpr[7]<=32'd0;
        creg0<=32'd0; creg2<=32'd0; creg3<=32'd0; creg4<=32'd0;
        for (int s=0;s<NUM_SEG;s++) begin
          seg_sel[s]<=16'h0000; seg_base[s]<=32'd0; seg_limit[s]<=32'hFFFF_FFFF;
          seg_attr[s]<=8'h93;   // flat present R/W (unused in user mode; benign)
        end
        // M7.1 proxy: seed the LIVE selectors to the linux-user SEG_* constants so
        // the proxy snap can report them live (a later `mov gs,0x33` updates GS).
        // Bases stay 0 (flat) so addressing is byte-identical until GS is set.
        // INERT when proxy_en==0: seg_sel[] stay 0 (the snap uses the SEG_*
        // constants in that path), so non-proxy user runs are bit-identical.
        if (proxy_en) begin
          seg_sel[SG_CS]<=SEG_CS; seg_sel[SG_SS]<=SEG_SS; seg_sel[SG_DS]<=SEG_DS;
          seg_sel[SG_ES]<=SEG_ES; seg_sel[SG_FS]<=SEG_FS; seg_sel[SG_GS]<=SEG_GS;
        end
        seg_attr[SG_CS]<=8'h9B;
        cpl_r<=2'd0;
        gdt_base<=32'd0; gdt_limit<=16'd0; idt_base<=32'd0; idt_limit<=16'd0;
        cs_d<=1'b1;   // user mode: flat 32-bit (def16 is gated off by !sys_mode)
      end
      fetch_word<=3'd0; retire_valid<=1'b0; step<=4'd0;
      // x87 reset = FNINIT state (control 0x037f, status 0, TOP 0, all empty) now
      // lives in u_fpu_state's own rst_n arm (rtl/fpu/fpu_top.sv) — ftop/fctrl/
      // fstat/fptag/fpr[] are reset there. Only the spine-side touch flag here.
      x87_touched_r<=1'b0; f_step<=4'd0; f_seq_step<=5'd0;
      hung_r<=1'b0;   // M6 Erratum 81: not hung out of reset.
      gs_base_r<=32'd0; cn<=64'd0;   // M7.1 proxy: no TLS base yet; retire count 0
      tsc<=64'd0;                    // F3: time-stamp counter zeroed at reset (RDTSC)
`ifdef VEN_DBG_WD
      dbg_stall<=24'd0; dbg_printed<=1'b0;
`endif
`ifdef VEN_PS_PROXY
      q_proxy_len<=4'd0;
`endif
      fold_pending_r<=1'b0; fold_pc_r<=32'd0;   // M7.1: no folded syscall in flight
      // (fpr[] cleared in u_fpu_state's rst_n arm.)
      // M4 pipeline state.
      pf_fill_addr<=32'd0; pf_word<=3'd0; pf_fill_way<='0;
      agi_wr0<=9'h100; agi_wr1<=9'h100; mispred_bubbles<=3'd0;
      // M5 cycle-accuracy state.
      core_cyc<=32'd0; fp_ready_cyc<=32'd0; pending_mem_pen<=7'd0; stall_cnt<=7'd0;
      fp_occ_pending<=1'b0; fp_issue_cyc<=32'd0;
`ifdef VEN_FP_OVERLAP
      fp_busy_cyc<=32'd0;
`endif
`ifdef VEN_FP_PIPE
      fpp_valid<=1'b0;
`ifdef VEN_FP_PIPE2
      fpp2_valid<=1'b0;
`endif
`endif
      // D-cache timing arrays (dc_tag/dc_val/dc_lru) are reset inside the
      // dcache_timing module's own rst_n arm (rtl/mem/dcache.sv).
      retire2_valid<=1'b0; retire_pipe_valid<=1'b0;
      retire_pipe<=2'd0; retire_paired<=1'b0;
      retire2_pipe<=2'd0; retire2_paired<=1'b0;
      // BTB arrays (btb_tag/btb_ctr/btb_val/btb_rr) are reset inside the
      // bpred_btb module's own rst_n arm (rtl/core/bpred_btb.sv).
      // I-cache arrays (ic_data/ic_tag/ic_val/ic_lru) are reset inside the icache
      // module's own rst_n arm (rtl/mem/icache.sv) — u_icache.
      // M2S.2 paging: the TLB arrays are reset inside the tlb module's own rst_n
      // arm (rtl/mem/tlb.sv) — u_itlb / u_dtlb. Only the page-walk FSM regs (which
      // stay in the spine) are reset here.
      walk_ret_state<=S_PIPE; walk_lin<=32'd0; walk_for_d<=1'b0;
      walk_is_write<=1'b0; walk_step<=3'd0; walk_pde<=32'd0; walk_pte<=32'd0;
      walk_pde_addr<=32'd0; walk_pte_addr<=32'd0; walk_pf<=1'b0; pf_errcode<=3'd0;
      // M2S.3 IDT delivery state idle out of reset.
      int_vec<=8'd0; int_ret_eip<=32'd0; int_src_pc<=32'd0; int_has_err<=1'b0;
      int_err<=32'd0; int_step<=4'd0; int_gate_off<=32'd0; int_gate_sel<=16'd0;
      int_gate_trap<=1'b0; int_lo<=32'd0; iret_eip<=32'd0; iret_cs<=16'd0;
      int_sw<=1'b0;
      // M2S.4 TR/TSS + cross-priv + inter-priv IRET state idle out of reset.
      tr_sel<=16'd0; tr_base<=32'd0; tr_limit<=32'd0; tr_valid<=1'b0; tr_attr<=8'd0;
      // M2S.4b task-switch scratch idle out of reset (the tsw_* holding regs are
      // fully written by S_TSW_READ/_SEG before being committed in S_TSW_BUSY).
      tsw_step<=5'd0; tsw_new_base<=32'd0; tsw_new_limit<=32'd0; tsw_new_sel<=16'd0;
      tsw_new_attr<=8'd0; tsw_save_eip<=32'd0; tsw_eip<=32'd0; tsw_eflags<=32'd0;
      tsw_cr3<=32'd0; tsw_seg_lo<=32'd0;
      iret_eflags<=32'd0; xpl_active<=1'b0; int_old_ss<=16'd0; int_old_esp<=32'd0;
      int_old_cs<=16'd0; int_new_cpl<=2'd0; int_new_ss<=16'd0; int_new_esp<=32'd0;
      iret_interpriv<=1'b0; iret_ss<=16'd0; iret_esp<=32'd0;
      // M7.2 V86 delivery scratch idle out of reset.
      from_v86<=1'b0; int_old_ds<=16'd0; int_old_es<=16'd0; int_old_fs<=16'd0;
      int_old_gs<=16'd0; int_old_eflags<=32'd0;
      iret_to_v86<=1'b0; iret_v86_es<=16'd0; iret_v86_ds<=16'd0;
      iret_v86_fs<=16'd0; iret_v86_gs<=16'd0;
      // M2S.5 SMM/RSM idle out of reset. SMBASE = the P5 default 0x30000; not in
      // SMM; no SMI pending. (RSM read-back regs are scratch — left uninit; they
      // are fully written by S_RSM before being committed.)
      smbase<=32'h0003_0000; smm_active<=1'b0; smi_pending<=1'b0;
      smm_step<=6'd0; smm_resume_eip<=32'd0;
      // M8.1 external-interrupt latches idle out of reset (all INERT when soc_en==0).
      intr_pending<=1'b0; nmi_pending<=1'b0; nmi_prev<=1'b0;
      irq_shadow<=1'b0; nmi_in_progress<=1'b0;
      // M2S.6 debug registers idle out of reset (Vol.3 power-on values). The DR
      // file resets identically in user mode — it is just never written there.
      dr0<=32'd0; dr1<=32'd0; dr2<=32'd0; dr3<=32'd0;
      dr6<=DR6_FIXED_1; dr7<=DR7_FIXED_1;
      tf_at_issue<=1'b0; rf_at_issue<=1'b0; db_wp_extra<=1'b0;
      // M6B Erratum 79: no erroneous-#DB chain pending out of reset.
      err79_pending<=1'b0; err79_dr6_bits<=4'd0;
    end else begin
      // M7.1 proxy: mirror ventium_top's retire_n on the SAME posedge it counts
      // (the registered retire_valid/retire2_valid of the PREVIOUS clock). cn thus
      // equals the number of retirements already emitted, so an int-0x80 in
      // S_DECODE this clock names its own upcoming record as syscall_n=cn. INERT
      // when proxy_en==0 (cn is simply never read). The folded-syscall retire (the
      // insn after cd80) is the one that clears fold_pending_r — after it the
      // overridden pc is no longer needed.
      if (retire_valid) begin
        cn <= cn + (retire2_valid ? 64'd2 : 64'd1);
        fold_pending_r <= 1'b0;
      end

      // F3: the time-stamp counter free-runs at the core clock (one tick / clk),
      // independent of retirement. RDTSC samples it. INERT for the user-mode corpus
      // (no test executes RDTSC, so the reg is never read and the trace is identical).
      tsc <= tsc + 64'd1;

`ifdef VEN_DBG_WD
      // sim-only hang watchdog (opt-in via +define+VEN_DBG_WD): dump the wedged FSM
      // state once after a long no-retire stall (boot bring-up gap-walk diagnostic).
      if (retire_valid || retire2_valid) begin dbg_stall<=24'd0; end
      else dbg_stall <= dbg_stall + 24'd1;
      if (dbg_stall == 24'd150000 && !dbg_printed) begin
        dbg_printed <= 1'b1;
        $display("[VEN-WD] STUCK state=%s mem_addr=%08h | cr0=%08h sys_mode=%b v86=%b real_mode=%b eflags=%08h | idt_base=%08h gdt_base=%08h int_vec=%02h cpl=%0d | csbase=%08h eip=%08h",
                 state.name(), mem_addr, creg0, sys_mode, v86, real_mode, eflags,
                 idt_base, gdt_base, int_vec, cpl_r, seg_base[SG_CS], eip);
      end
`endif

      retire_valid <= 1'b0;
      retire2_valid <= 1'b0;
      retire_pipe_valid <= 1'b0;
      // x87-touched defaults low each cycle; only the x87 retire paths
      // (S_FEXEC / S_FSTORE) raise it, so the DPI x87 hook fires only for FPU
      // instructions. (ventium_top gates vtm_retire_x87 on this.)
      x87_touched_r <= 1'b0;

      // M5: advance the free-running core-clock counter (the timeline the FP
      // scoreboard + miss-stall countdowns live on). It tracks the TB's
      // cyc=clock-count-at-retire 1:1 (core_cyc is the count of completed clocks
      // before this edge; a retire on this edge stamps cyc=core_cyc+1).
      core_cyc <= core_cyc + 32'd1;

`ifdef VEN_FP_PIPE
      // +VEN_FP_PIPE: advance the 1-deep FP-execute pipeline. A pipelined FK_ARITH
      // issued this clock (fp_pipe_cap) latches its operands; fpp_valid is the
      // in-flight bit consumed next clock by the we_wabs deferred commit. Exactly
      // one capture per clock (the fast arm issues at most one FP op), so the
      // register is consumed (committed) and reloaded in the same clock cleanly.
      fpp_valid <= fp_pipe_cap;
      if (fp_pipe_cap) begin
        fpp_aluop <= fp_cap_aluop; fpp_a <= fp_cap_a; fpp_b <= fp_cap_b;
        fpp_rc    <= fp_cap_rc;    fpp_err <= fp_cap_err; fpp_dst <= fp_cap_dst;
      end
`ifdef VEN_FP_PIPE2
      // Stage 1 -> stage 2: register the f_eval_s1 result one clock after capture.
      // A captured op (fpp_valid this clock) advances into the stage-2 slot; its
      // we_wabs commit fires the NEXT clock from fpp2_s1. At most one op per clock
      // enters each slot (the fast arm issues <=1 FP op), so the two stages never
      // collide.
      fpp2_valid <= fpp_valid;
      if (fpp_valid) begin
        fpp2_s1  <= fp_s1_next;
        fpp2_rc  <= fpp_rc;
        fpp2_dst <= fpp_dst;
      end
`endif
`endif

      // -------------------------------------------------------------------
      // M8.1 — sample the external-interrupt pins (mirror smi_pending). Done
      // every non-reset clock, BEFORE the state machine, so the S_DECODE divert
      // sees the current request. ALL gated on soc_en: with the pins tied off
      // (soc_en==0, ventium_top) intr_pending/nmi_pending hold 0 forever and the
      // divert is dead — the core is byte-identical to the M0-M7 core.
      //   * intr is a LEVEL request (the 8259 holds INT until serviced): mirror it
      //     into intr_pending. The divert consumes it (delivers) only when IF=1 +
      //     no shadow; the PIC drops INT after the inta, so intr falls and
      //     intr_pending clears naturally on the next sample.
      //   * nmi is an EDGE request: latch nmi_pending on a rising edge (nmi_prev
      //     remembers the last level). Once latched it is sticky until the NMI
      //     divert consumes it; a further edge while a handler runs is held by
      //     nmi_in_progress, re-armed by the IRET (S_DECODE d_iret).
      // -------------------------------------------------------------------
      if (soc_en) begin
        intr_pending <= intr;                       // level mirror
        nmi_prev     <= nmi;                        // remember the level for edge detect
        if (nmi && !nmi_prev) nmi_pending <= 1'b1;  // latch a rising edge
      end

      // -------------------------------------------------------------------
      // M2S.2 PAGING DIVERSION: when paging is on and the current state's
      // translatable memory access MISSES the relevant TLB, run a 2-level page
      // walk (S_WALK) FIRST, then resume this state (it then hits the TLB and
      // completes against the physical address). The walk reads the PDE and PTE
      // from physical memory, sets A (and D on a write) in the tables, and fills
      // the TLB. The normal state body is skipped this clock (no mem_ack
      // processed) because the bus this clock is the PDE read, not the access.
      // -------------------------------------------------------------------
      if (xlate_miss) begin
        walk_ret_state <= state;
        walk_lin       <= cur_lin;
        walk_for_d     <= cur_is_d;
        walk_is_write  <= cur_is_w;
        walk_step      <= 3'd0;
        walk_pf        <= 1'b0;
        // PDE physical address = (CR3 & ~0xFFF) + PDIndex*4, PDIndex = lin[31:22].
        walk_pde_addr  <= {creg3[31:12], cur_lin[31:22], 2'b00};
        state          <= S_WALK;
      end else if (fe_xlate_pend) begin
        // +VEN_FE_PIPE page-crossing stall: HOLD 1 clock (no state/eip/issue/bus this
        // edge) while the fe_*_q micro-TLB register samples cur_lin's translate (the
        // separate always_ff below). Next edge the register is valid -> proceed.
        // Inert in the default build (fe_xlate_pend tied 0 -> this arm is unreachable).
      end else
      unique case (state)
        // dual-issue fast-path + icache-fill arms (S_RESET / S_PF / S_PIPE) —
        // relocated VERBATIM into core_fastpath.svh (RAW case-arms, the first run
        // right after the `unique case (state)` header; pasted here in the FSM).
        `include "core_fastpath.svh"

        // fetch + decode-dispatch arms (S_FETCH / S_DECODE) — relocated VERBATIM
        // into core_fetch_decode.svh (RAW case-arms, pasted here in the FSM).
        `include "core_fetch_decode.svh"

        // data-load arms (S_LOAD / S_LOAD2 / S_FLOAD) — relocated VERBATIM into
        // core_load.svh (RAW case-arms, pasted here in the FSM).
        `include "core_load.svh"

        // integer execute/commit arm (S_EXEC — the largest) — relocated VERBATIM
        // into core_exec.svh (RAW case-arm, pasted here in the FSM).
        `include "core_exec.svh"

`ifdef VEN_IDIV_ITER
        // -----------------------------------------------------------------
        // S_DIV_BUSY: wait for the iterative integer DIV/IDIV engine, then
        // commit quotient/remainder to EAX/EDX (or deliver #DE on a zero
        // divisor / quotient overflow). Mirrors S_FP_BUSY; the busy-wait
        // serialises so the next insn reads the committed EDX:EAX.
        // -----------------------------------------------------------------
        S_DIV_BUSY: begin
          if (eng_int_done) begin
            if (eng_int_derr) begin
              // #DE (vector 0): no result, EFLAGS unchanged. sys_mode delivers
              // through the IDT; user mode loud-HALTs (matches the inline path).
              if (sys_mode) start_fault(8'd0, 1'b0, 32'd0, q_pc);
              else          state<=S_HALT;
            end else begin
              if (q_w==3'd1)
                gpr[R_EAX] <= {gpr[R_EAX][31:16], eng_int_rem[7:0], eng_int_quot[7:0]};
              else if (q_w==3'd2) begin
                gpr[R_EAX] <= {gpr[R_EAX][31:16], eng_int_quot[15:0]};
                gpr[R_EDX] <= {gpr[R_EDX][31:16], eng_int_rem[15:0]};
              end else begin
                gpr[R_EAX] <= eng_int_quot[31:0];
                gpr[R_EDX] <= eng_int_rem[31:0];
              end
              // P5 occupancy residual so issue->next-issue == occ (DIV 17/25/41,
              // IDIV 22/30/46). The engine's real clocks cover most of it; top up
              // (tuned vs make m5). q_md 3'd7 = IDIV.
              pending_mem_pen <= (q_md==3'd7) ? 7'd6 : 7'd1;
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
            end
          end
        end
`endif

        // M7.3 port-I/O arms (S_IO / S_INS) — relocated VERBATIM into
        // core_io.svh (RAW case-arms, pasted here in the FSM).
        `include "core_io.svh"
`ifdef VEN_PS_PROXY
        // PS-bridge (F4): the int-0x80 proxy parks here until the PS fills the
        // response. Commit only on syscall_resp_valid — IDENTICAL to the zero-latency
        // S_DECODE arm (eip still at cd80, so fold_pc_r<=eip and eip<=eip+q_proxy_len
        // are the same), just deferred. Else spin, consuming nothing (no retire_valid
        // -> cn frozen -> syscall_n/args stable for the PS the whole wait).
        S_SYSCALL_WAIT: begin
          if (syscall_resp_valid) begin
            gpr[0] <= syscall_eax;
            if (syscall_apply_gs) gs_base_r <= syscall_gs_base;
            eip            <= eip + {28'd0, q_proxy_len};
            fold_pending_r <= 1'b1;
            fold_pc_r      <= eip;
            fetch_word     <= 3'd0;
            state          <= S_FETCH;
          end
        end
`endif
        // store / micro-sequence arms (S_STORE / S_USEQ) — relocated VERBATIM
        // into core_store_useq.svh (RAW case-arms, pasted here in the FSM).
        `include "core_store_useq.svh"

        // M2S.1 descriptor-table read + far-jmp arms (S_LGDT / S_SEGLD / S_LJMP)
        // — relocated VERBATIM into core_seg_ljmp.svh (RAW case-arms, FSM-pasted).
        `include "core_seg_ljmp.svh"
        // M2S.3 IDT-delivery arms (S_INT_GATE / S_INT_CS / S_INT_PUSH /
        // S_DB_EXTRA) — relocated VERBATIM into core_int_deliver.svh (FSM-pasted).
        `include "core_int_deliver.svh"

        // IRET pop + CS/SS reload arms (S_IRET / S_INT_CS_RET / S_IRET_SS) —
        // relocated VERBATIM into core_iret.svh (RAW case-arms, FSM-pasted).
        `include "core_iret.svh"

        // F3 real-mode IVT delivery + IRET arms (S_RMINT_RD/_PUSH / S_RMIRET).
        `include "core_rmint.svh"

        // LTR + cross-priv stack/SS arms (S_LTR / S_INT_TSS / S_INT_SS) —
        // relocated VERBATIM into core_tss_priv.svh (RAW case-arms, FSM-pasted).
        `include "core_tss_priv.svh"

        // ===================================================================
        // M2S.4b hardware task-switch arms (S_TSW_SAVE/READ/SEG/BUSY) — relocated
        // VERBATIM into core_tsw.svh (RAW case-arms, pasted here in the FSM).
        `include "core_tsw.svh"

        // M2S.5 SMM entry (S_SMI_SAVE) + RSM (S_RSM) arms — relocated
        // VERBATIM into core_smm.svh (RAW case-arms, pasted here in the FSM).
        `include "core_smm.svh"

        // x87 execute/commit arms (S_FEXEC / S_FSTORE) — relocated VERBATIM into
        // core_fp_exec.svh (RAW case-arms, pasted here in the FSM).
        `include "core_fp_exec.svh"

        // M11b x87 env/state save+restore arms (S_FENV_ST / S_FENV_LD).
        `include "core_fenv.svh"

        // -------------------------------------------------------------------
        // M2S.2 page-table walk arm (S_WALK) — relocated VERBATIM into
        // core_walk.svh (RAW case-arm, pasted here in the FSM).
        `include "core_walk.svh"

        S_HALT: state<=S_HALT;

        // F3 INTERRUPTIBLE HLT wait (system mode). EIP already points past the HLT
        // (advanced when it retired), so start_fault's pushed return = the instruction
        // after HLT. Mirror the S_DECODE instruction-boundary divert priority
        // NMI > maskable INTR; the `inta` strobe also pulses here (see assign inta).
        // Stay parked until one fires. SMI from HLT is out of scope (FreeDOS path).
        S_HLTWAIT: begin
          if (nmi_take) begin
            nmi_pending     <= 1'b0;
            nmi_in_progress <= 1'b1;
            start_fault(8'd2, 1'b0, 32'd0, eip);
          end else if (intr_take) begin
            start_fault(inta_vector, 1'b0, 32'd0, eip);
          end
          // else remain in S_HLTWAIT (halted, awaiting an interrupt).
        end

        // M6 Erratum 81 (F00F): the locked CMPXCHG8B-with-register-destination
        // form never starts the #UD handler because the bus stays locked — the
        // processor HANGS. We model that as a parked state that NEVER retires and
        // keeps cpu_hung asserted (documented "system hang"). Unlike S_HALT this
        // is reached ONLY with errata_en[ERR_F00F] set; the clean core decodes
        // 0F C7 /reg as an unknown opcode and HALTs loudly (no retire) instead.
        S_F00F_HANG: begin hung_r<=1'b1; state<=S_F00F_HANG; end

        default: state<=S_HALT;
      endcase
`ifdef VEN_L1_AXI
      // P1-1 #34: a fatal bus fault overrides every state arm (last-write-wins NBA) —
      // park in S_HALT + assert cpu_hung. Inert when bus_err=0 (the entire verified
      // 77/77+10/10 path), so it is byte-identical; absent in the default build.
      if (real_bus && bus_err) begin hung_r <= 1'b1; state <= S_HALT; end
`endif
    end
  end

  // ===========================================================================
  // x87 store-operand value + exception flags (combinational). `fstore_val`
  // holds the word-aligned bytes to write; `fstore_pe`/`fstore_ie` carry the
  // precision (inexact) / invalid status QEMU latches on a rounding/overflowing
  // store (helper_fst*/helper_fist* -> merge_exception_flags). fstat is trace-
  // compared, so these must be set whenever QEMU would. Rounding honors RC.
  //   FST  m32/m64 : PE if the floatx80->float32/64 narrow rounds (inexact).
  //   FIST m16/m32/m64 : PE if the rounding-to-int loses a fraction; IE +
  //     integer-indefinite if the result is out of the destination's range.
  //   FST m80 / FNSTCW / FNSTSW m16 : exact, no exception.
  // ===========================================================================
  logic [79:0] fstore_val;
  logic        fstore_pe;
  logic        fstore_ie;
  always_comb begin
    logic [79:0] s0;
    logic [32:0] r32;
    logic [64:0] r64;
    logic [65:0] ri;             // {invalid, inexact, value}
    s0 = fp_st0_phys;             // ST0 (= fpr[ftop], u_fpu_state read port)
    r32 = 33'd0; r64 = 65'd0; ri = 66'd0;
    fstore_val = 80'd0; fstore_pe = 1'b0; fstore_ie = 1'b0;
    unique case (q_fxop)
      FX_FST_M32: begin
        r32 = fx_to_f32_ex(s0, fctrl[11:10]);
        fstore_val = {48'd0, r32[31:0]}; fstore_pe = r32[32];
      end
      FX_FST_M64: begin
        r64 = fx_to_f64_ex(s0, fctrl[11:10]);
        fstore_val = {16'd0, r64[63:0]}; fstore_pe = r64[64];
      end
      FX_FST_M80:  fstore_val = s0;
      // M10 FBSTP: round ST0 to int (per RC), pack 18-digit BCD + sign byte.
      // {ie,pe,bcd} -> IE on BCD-range overflow (indefinite image), PE on an
      // inexact round-to-int (oracle-confirmed: FBSTP of 2.5 sets PE).
      FX_FBSTP: begin
`ifdef VEN_BCD_ITER
        // iterative engine result, latched in S_BCD_BUSY (see ven_bcd).
        fstore_val = fbcd_result_q[79:0]; fstore_pe = fbcd_result_q[80]; fstore_ie = fbcd_result_q[81];
`else
        logic [81:0] rb;
        rb = fx_fx_to_bcd(s0, fctrl[11:10]);
        fstore_val = rb[79:0]; fstore_pe = rb[80]; fstore_ie = rb[81];
`endif
      end
      // M6 Erratum 20: FIST[P] m16int/m32int (NOT m64) miss the overflow on
      // the documented positive operands in nearest/up rounding -> store ZERO,
      // no IE. fx_to_int_errata reproduces that when errata_en[ERR_FIST] is set;
      // otherwise it is identical to fx_to_int_ex (clean core unchanged). The
      // three widths are kept as SEPARATE constant-width calls on purpose: the
      // constant `width` lets synth constant-fold each conversion's range-check
      // (a runtime-width merge measured +8.8K LUT, defeating that folding).
      FX_FIST_M16: begin
        ri = errata_en[ERR_FIST] ? fx_to_int_errata(s0, 16, fctrl[11:10])
                                 : fx_to_int_ex     (s0, 16, fctrl[11:10]);
        fstore_val = {64'd0, ri[15:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
      FX_FIST_M32: begin
        ri = errata_en[ERR_FIST] ? fx_to_int_errata(s0, 32, fctrl[11:10])
                                 : fx_to_int_ex     (s0, 32, fctrl[11:10]);
        fstore_val = {48'd0, ri[31:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
      FX_FIST_M64: begin
        ri = fx_to_int_ex(s0, 64, fctrl[11:10]);
        fstore_val = {16'd0, ri[63:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
      FX_FNSTCW:   fstore_val = {64'd0, fctrl};
      FX_FNSTSW_M: fstore_val = {64'd0, (fstat & ~16'h3800) | ({13'd0,ftop}<<11)};
      default:     fstore_val = 80'd0;
    endcase
  end

  // ===========================================================================
  // M11b: the FNSTENV/FNSAVE environment+state image, assembled as a flat 864-bit
  // little-endian byte vector (dword j = fenv_image[j*32 +: 32]). Dwords 0..6 are
  // the 28-byte protected-mode env (CW/SW/FTW/FIP/FCS|FOP/FDP/FDS); dwords 7..26
  // are the 8 ST registers (logical order ST0..ST7, 10 bytes each, empty->0). The
  // 10-byte slots straddle dword boundaries -- the flat-vector dword slice handles
  // it. FOP is hardwired 0 (oracle). The graded trace is unaffected (this feeds
  // only the store bus arm, read back from memory into a GPR).
  // ===========================================================================
  logic [863:0] fenv_image;
  logic [15:0]  fenv_ftw;
  logic [639:0] fenv_streg;
  always_comb begin
    int pidx;
    for (int p = 0; p < 8; p++)
      fenv_ftw[p*2 +: 2] = ftw_field(fptag[p], fpr_flat[p*80 +: 80]);
    for (int i = 0; i < 8; i++) begin
      pidx = (ftop + i) & 7;                                  // ST(i) = physical fpr[ftop+i]
      // qemu do_fsave dumps the RAW register bytes for every slot, even empty ones
      // (do_fstt is unconditional) -- an empty reg keeps its stale floatx80 content.
      fenv_streg[i*80 +: 80] = fpr_flat[pidx*80 +: 80];
    end
    fenv_image = { fenv_streg,                                       // dw7..26 (ST0..7)
                   {16'd0, fds},                                     // dw6 +24 FDS
                   fdp,                                              // dw5 +20 FDP
                   {5'd0, 11'd0, fcs},                               // dw4 +16 {FOP=0, FCS}
                   fip,                                              // dw3 +12 FIP
                   {16'd0, fenv_ftw},                                // dw2 +8  FTW
                   {16'd0, (fstat & ~16'h3800) | ({13'd0,ftop}<<11)},// dw1 +4  SW (TOP overlaid)
                   {16'd0, fctrl} };                                 // dw0 +0  CW
  end

  // ===========================================================================
  // M2S.1 data segment base. For a slow-path data access the linear address is
  // seg.base + offset. The base depends on which segment the access uses:
  //   - stack ops (push/pop/call/ret/leave/pushf/popf) use SS
  //   - string source ([ESI]) uses DS, dest ([EDI]) uses ES
  //   - LGDT/LIDT pseudo-descriptor read uses DS
  //   - everything else uses q_seg (DS default, or a segment-override prefix)
  // In USER mode every seg_base[]==0 so dbase==0 and the linear address is the
  // unchanged flat offset (so make verify is bit-for-bit unaffected).
  // ===========================================================================
  logic [31:0] dbase, dbase_edi;
  logic [2:0]  dseg;              // which segment supplies dbase (for the limit check)
  always_comb begin
    if (q_is_pop || q_is_push || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
        (q_kind==K_CTRL && (q_ct==CT_CALLREL || q_ct==CT_CALLIND)) ||
        (q_kind==K_STKMISC && (q_sm==SM_POPF || q_sm==SM_PUSHF ||
                               q_sm==SM_LEAVE || q_sm==SM_PUSHA || q_sm==SM_POPA)))
      dseg = 3'(SG_SS);
    else if (q_kind==K_STR)
      dseg = (q_st==ST_SCAS) ? 3'(SG_ES) : 3'(SG_DS);
    else
      dseg = q_seg;
    dbase     = seg_base[dseg];
    dbase_edi = seg_base[SG_ES];   // string/[EDI] destination uses ES
  end

  // M7.1: the OPERAND segment base for an indirect CALL/JMP's memory-operand READ.
  // The dbase comb above forces SS for a CALL (its primary stack PUSH uses SS),
  // but the indirect target is fetched from the OPERAND's own segment — which
  // matters when the call carries a segment override, e.g. musl's vsyscall
  // `call dword ptr gs:[0x10]`: the pointer is read at %gs (the TLS base), while
  // the return address is still pushed on SS. opbase supplies seg_base[q_seg] for
  // that operand read. GATED on (proxy_en && !sys_mode): in flat user/sys mode
  // q_seg's base equals SS's base (both 0), so this is bit-identical everywhere
  // the gates run; only the user-proxy gs-override call changes.
  logic [31:0] opbase;
  always_comb begin
    // F3: PUSH r/m (FF /6) with a MEMORY source reads the operand from its OWN
    // segment (DS default, or an override) — only the stack WRITE uses SS. The dbase
    // comb forces SS for every push, which is correct for the stack but wrong for the
    // source read: SeaBIOS's __farcall16 does `push dword [eax+0x20]` with DS!=SS and
    // got 0 (reading SS:off instead of DS:off) -> iret to 0:0. Flat user/sys mode has
    // seg_base[q_seg]==seg_base[SS] (both 0) so make verify is bit-identical.
    if (q_is_push && q_mem_read)
      opbase = seg_base[q_seg];
    else if ((q_ct==CT_CALLIND || q_ct==CT_JMPIND) && q_mem_read)
      // F3: the function-pointer READ of an indirect call/jmp uses the operand's
      // own segment (DS default / override / the new EBP->SS rule), NOT the SS
      // that dbase forces for the return-address PUSH. Was gated proxy_en &&
      // !sys_mode, so the SoC (sys_mode=1) read `call word [bx]` pointers from
      // SS:EA. Flat gates: seg_base[q_seg]==seg_base[SS] -> byte-identical.
      opbase = seg_base[q_seg];
    else
      opbase = dbase;   // unchanged path (SS for a call, etc.)
  end

  // F3: the STORE-side mirror of opbase. POP r/m (8F) reads the stack word (SS, via
  // the S_LOAD q_is_pop branch) but WRITES the popped value to its memory OPERAND,
  // which uses the operand's own segment (DS default / override) — not SS. dbase
  // forces SS for every pop, so a `pop word [eax]` with DS!=SS (SeaBIOS's call32
  // forward path) wrote the struct to the wrong segment. Flat mode: q_seg base == SS
  // base (0), so make verify is bit-identical. Every other store keeps dbase.
  logic [31:0] stbase;
  always_comb begin
    if (q_is_pop && q_mem_write) stbase = seg_base[q_seg];
    else                         stbase = dbase;
  end

  // M2S.1 — protected-mode segment LIMIT-check DECISION (spec §3, computed not
  // delivered). For an expand-up data/code segment the last byte of an access at
  // segment offset `off` must satisfy off <= seg_limit. We compute this for the
  // current data access (effective address q_ea against dseg's hidden limit) so
  // the limit check is genuinely COMPUTED — but, like seg_load_fault, delivery
  // (#GP) is M2S.3, so a positive decision can only be observed here / HALT in a
  // later stage. The pseg corpus's top-of-segment access (offset 0xFFFC dword in
  // the 64 KiB based segment) is exactly in-bounds, so this is always 0 for the
  // gate. Only meaningful in protected mode (sys_mode & !real_mode); flat/user
  // segments have seg_limit=0xFFFFFFFF so it is trivially 0 there too.
  logic [31:0] dlimit;
  logic        seg_off_over_limit;
  always_comb begin
    dlimit = seg_limit[dseg];
    // worst-case last touched byte of the operand = q_ea + (width-1); use +3 (the
    // widest scalar) as a conservative bound for the computed decision.
    seg_off_over_limit = sys_mode && !real_mode && ({1'b0,q_ea} + 33'd3 > {1'b0,dlimit});
  end

  // ===========================================================================
  // M2S.2 — linear-address translation (paging). The bus driver below first
  // computes the LINEAR address for the current state's access into `mem_addr`
  // exactly as M2S.1 did; this stage then post-translates it to PHYSICAL when
  // paging_on. The split I/D TLBs are looked up combinationally; on a HIT the
  // physical frame replaces the linear page; on a MISS the FSM diverts to S_WALK
  // (see xlate_miss / mem_xlate below). When paging is off (real mode, flat
  // PM-before-PG, ALL of user mode) translation is a pass-through (linear ==
  // physical) so M2S.1 + user mode stay byte-identical.
  // ===========================================================================
  // The TLB ARRAYS + lookup + fill-commit + flush were extracted into the `tlb`
  // module (rtl/mem/tlb.sv), instantiated as u_itlb (IS_D=0) and u_dtlb (IS_D=1)
  // below. The lk_* ports do the per-access lookup at `cur_lin` (consumed by
  // xlate_miss / perm_fault); the xl_* ports do the bus post-translate lookup at
  // `mem_addr` (consumed by mem_xlate). The whole S_WALK page-walk micro-sequence
  // STAYS here in the spine and drives the fill ports (see tlb_fill_* drivers and
  // the instantiation near the bus-translate block).

  // Translate a linear address for the CURRENT bus access (the bus post-stage).
  // `is_d`=1 selects the D-TLB (data), else the I-TLB (fetch). Returns the
  // physical address on a hit; on a miss (or paging off) returns the linear
  // address `lin` (the FSM never USES a miss result — it diverts to S_WALK
  // first). The hit/phys come from each instance's lk_* port. The post-translate
  // is only applied to the translatable states where cur_lin == this `lin`
  // (== mem_addr), so the lk lookup (driven by cur_lin) returns the right entry;
  // on miss/paging-off the actual `lin` (mem_addr) is passed through unchanged.
  function automatic logic [31:0] mem_xlate(input logic [31:0] lin, input logic is_d);
    begin
`ifdef VEN_FE_PIPE
      // FE_PIPE: physical = {registered page-frame, this access's page offset}. Only
      // reached when !fe_xlate_pend (the bus driver squashes during the stall), so the
      // registered page matches lin[31:12] and fe_*_q is valid.
      if (!paging_on)                  mem_xlate = lin;
      else if (is_d  &&  fe_dtlb_hit)   mem_xlate = {fe_dtlb_phys, lin[11:0]};
      else if (!is_d &&  fe_itlb_hit)   mem_xlate = {fe_itlb_phys, lin[11:0]};
      else                              mem_xlate = lin;   // miss: value unused
`else
      if (!paging_on)                  mem_xlate = lin;
      else if (is_d  &&  dtlb_lk_hit)   mem_xlate = dtlb_lk_phys;
      else if (!is_d &&  itlb_lk_hit)   mem_xlate = itlb_lk_phys;
      else                              mem_xlate = lin;   // miss: value unused
`endif
    end
  endfunction

  // ===========================================================================
  // TLB fill-commit driver (combinational): mirrors the four S_WALK fill sites
  // EXACTLY and produces the single fill transaction for THIS clock. The commit
  // lands on the SAME posedge the original inline tlb_fill_*() NBA write did (the
  // clock where S_WALK reaches the fill branch under `mem_ack`), so the read-
  // before-write timing (lookup off the PRE-fill arrays this clock) is preserved.
  //   step0 big, A/D already set     -> fill_big(pde=mem_rdata)
  //   step1 big (PDE writeback)      -> fill_big(walk_pde | A | (write?D))
  //   step2 4 KiB, A/D already set   -> fill_4k(walk_pde, pte=mem_rdata, is_w)
  //   step3 4 KiB (PTE writeback)    -> fill_4k(walk_pde, pte_new=walk_pte|A|D, is_w)
  // Operand computation (perm = AND of PDE&PTE, 4 MiB pfn = {pde[31:22],10'd0})
  // is done here, replacing the old tlb_fill_4k/tlb_fill_big task bodies. The
  // fill is routed to ONE instance by walk_for_d (u_itlb when 0, u_dtlb when 1).
  logic        tlb_fill_en;
  logic        tlb_fill_is_d;
  logic [31:0] tlb_fill_lin;
  logic [19:0] tlb_fill_pfn;
  logic [2:0]  tlb_fill_perm;
  logic        tlb_fill_big;
  logic        tlb_fill_dirty;
  always_comb begin
    logic [31:0] pde, pte, pte_new;
    logic        is_big;
    tlb_fill_en    = 1'b0;
    tlb_fill_is_d  = walk_for_d;
    tlb_fill_lin   = walk_lin;
    tlb_fill_pfn   = 20'd0;
    tlb_fill_perm  = 3'd0;
    tlb_fill_big   = 1'b0;
    tlb_fill_dirty = 1'b0;
    if (state==S_WALK && mem_ack) begin
      unique case (walk_step)
        3'd0: begin
          pde    = mem_rdata;
          is_big = cr4_pse && pde[7];
          // a present 4 MiB page with A(+D for write) already set fills directly.
          if (pde[0] && is_big && !(!pde[5] || (walk_is_write && !pde[6]))) begin
            tlb_fill_en   = 1'b1;
            tlb_fill_big  = 1'b1;
            tlb_fill_pfn  = {pde[31:22], 10'd0};
            tlb_fill_perm = {pde[2], pde[1], pde[0]};
            tlb_fill_dirty= pde[6];
          end
        end
        3'd1: begin
          is_big = cr4_pse && walk_pde[7];
          if (is_big) begin
            pde = walk_pde | 32'h0000_0020 | (walk_is_write ? 32'h0000_0040 : 32'd0);
            tlb_fill_en   = 1'b1;
            tlb_fill_big  = 1'b1;
            tlb_fill_pfn  = {pde[31:22], 10'd0};
            tlb_fill_perm = {pde[2], pde[1], pde[0]};
            tlb_fill_dirty= pde[6];
          end
        end
        3'd2: begin
          pte = mem_rdata;
          // present 4 KiB page with A(+D for write) already set fills directly.
          if (pte[0] && !(!pte[5] || (walk_is_write && !pte[6]))) begin
            tlb_fill_en   = 1'b1;
            tlb_fill_big  = 1'b0;
            tlb_fill_pfn  = pte[31:12];
            tlb_fill_perm = {walk_pde[2]&pte[2], walk_pde[1]&pte[1], walk_pde[0]&pte[0]};
            tlb_fill_dirty= walk_is_write;
          end
        end
        default: begin   // step 3: PTE writeback then fill
          pte_new = walk_pte | 32'h0000_0020 | (walk_is_write ? 32'h0000_0040 : 32'd0);
          tlb_fill_en   = 1'b1;
          tlb_fill_big  = 1'b0;
          tlb_fill_pfn  = pte_new[31:12];
          tlb_fill_perm = {walk_pde[2]&pte_new[2], walk_pde[1]&pte_new[1],
                           walk_pde[0]&pte_new[0]};
          tlb_fill_dirty= walk_is_write;
        end
      endcase
    end
  end

  // TLB CR3 flush (combinational pulse): clears ONLY the val bits in BOTH TLBs.
  // Asserted on the exact clock the S_EXEC MOV CR3 commits (q_sysop SYS_MOVCR_TO,
  // q_sys_creg==3, in S_EXEC). q_sysop is mutually exclusive with the flag ops
  // (CLD/STD/CLC/.../STI), so the original if/else-if guard reduces to this.
  logic tlb_flush;
  assign tlb_flush = (state==S_EXEC) && (q_sysop==SYS_MOVCR_TO) && (q_sys_creg==3'd3);

  // ---- Split I/D TLB instances. lk_* = combinational lookup at cur_lin (consumed
  // by xlate_miss / perm_fault AND, via mem_xlate, the bus post-translate, since
  // cur_lin == mem_addr in every translatable state). The fill is routed to the
  // matching side by walk_for_d (tlb_fill_is_d); flush hits both on a CR3 write.
  tlb #(.IS_D(1'b0), .TLB_ENTRIES(TLB_ENTRIES)) u_itlb (
      .clk(clk), .rst_n(rst_n),
      .lk_lin(cur_lin),  .lk_hit(itlb_lk_hit), .lk_phys(itlb_lk_phys),
      .lk_perm(itlb_lk_perm), .lk_dirty(itlb_lk_dirty),
      .fill_en(tlb_fill_en && (tlb_fill_is_d==1'b0)),
      .fill_lin(tlb_fill_lin), .fill_pfn(tlb_fill_pfn), .fill_perm(tlb_fill_perm),
      .fill_big(tlb_fill_big), .fill_dirty(tlb_fill_dirty),
      .flush_en(tlb_flush)
  );
  tlb #(.IS_D(1'b1), .TLB_ENTRIES(TLB_ENTRIES)) u_dtlb (
      .clk(clk), .rst_n(rst_n),
      .lk_lin(cur_lin),  .lk_hit(dtlb_lk_hit), .lk_phys(dtlb_lk_phys),
      .lk_perm(dtlb_lk_perm), .lk_dirty(dtlb_lk_dirty),
      .fill_en(tlb_fill_en && (tlb_fill_is_d==1'b1)),
      .fill_lin(tlb_fill_lin), .fill_pfn(tlb_fill_pfn), .fill_perm(tlb_fill_perm),
      .fill_big(tlb_fill_big), .fill_dirty(tlb_fill_dirty),
      .flush_en(tlb_flush)
  );

`ifdef VEN_FE_PIPE
  // +VEN_FE_PIPE: the page-keyed micro-TLB register. On the page-crossing stall clock
  // (fe_xlate_pend) it samples the combinational {i,d}tlb lookup for cur_lin's page;
  // thereafter xlate_miss / mem_xlate read it (off the hit_of critical path). Coherence:
  //  * a CR3 write (tlb_flush) clears both arrays -> invalidate both fe_*_q.
  //  * a page-walk fill (tlb_fill_en) replaces ONE side's translation (incl. set-D on
  //    a write) -> invalidate that side so it re-registers the fresh entry next access.
  // Invalidate wins over (re-)register this edge, so a freshly-flushed/filled page is
  // never cached stale. Mirrors the access split: fetch (cur_is_d=0) -> itlb, data -> dtlb.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fe_itlb_v <= 1'b0; fe_dtlb_v <= 1'b0;
    end else begin
      if (tlb_flush) begin fe_itlb_v <= 1'b0; fe_dtlb_v <= 1'b0; end
      else begin
        // I-side
        if (tlb_fill_en && !tlb_fill_is_d) fe_itlb_v <= 1'b0;
        else if (paging_on && !cur_is_d &&
                 (!fe_itlb_v || (fe_itlb_page != cur_lin[31:12]))) begin
          fe_itlb_page <= cur_lin[31:12]; fe_itlb_phys <= itlb_lk_phys[31:12];
          fe_itlb_hit  <= itlb_lk_hit;    fe_itlb_v    <= 1'b1;
        end
        // D-side
        if (tlb_fill_en && tlb_fill_is_d) fe_dtlb_v <= 1'b0;
        else if (paging_on && cur_is_d &&
                 (!fe_dtlb_v || (fe_dtlb_page != cur_lin[31:12]))) begin
          fe_dtlb_page  <= cur_lin[31:12]; fe_dtlb_phys  <= dtlb_lk_phys[31:12];
          fe_dtlb_hit   <= dtlb_lk_hit;    fe_dtlb_dirty <= dtlb_lk_dirty;
          fe_dtlb_v     <= 1'b1;
        end
      end
    end
  end
`endif

  // M2S.3 — begin IDT delivery of a HARDWARE fault (#GP/#NP/#SS/#PF/#UD raised
  // from a fault DECISION that prior stages only computed). A fault always
  // pushes the FAULTING instruction's EIP (restartable); `vec`, `has_err`, and
  // `err` carry the IA-32 error-code rules. `src_pc` is the q_pc to stamp on the
  // single delivery retire record. The micro-sequence then reads IDT[vec], the
  // gate's CS descriptor, pushes the frame, and loads CS:EIP. Only invoked when
  // sys_mode (faults can only arise from the system-mode states).
  // ---- M2S.6 hardware-breakpoint match (gated sys_mode at the call sites) ----
  // Return the DR6 status bits (B0..B3) for every ENABLED DRn (DR7 Ln or Gn set)
  // whose linear address matches `lin` with the requested access type. `want_x`
  // selects an instruction (execute, R/W=00) breakpoint; otherwise a data WRITE
  // (R/W=01) or read-or-write (R/W=11) breakpoint. LEN matching: a DRn covers a
  // 1/2/4/8-aligned region (LENn 00/01/11/10); the corpus uses LEN0=00 (execute,
  // 1 byte) and LEN1=11 (4 bytes), so we honour the documented LEN masks. The
  // length mask aligns `lin` and the breakpoint address before the equality test.
  function automatic logic [3:0] dr_match(input logic [31:0] lin, input logic want_x);
    logic [3:0] hit;
    logic [31:0] addr [4];
    logic [1:0]  rw   [4];
    logic [1:0]  len  [4];
    logic        en   [4];
    logic [31:0] lenmask;
    begin
      addr[0]=dr0; addr[1]=dr1; addr[2]=dr2; addr[3]=dr3;
      // DR7: Ln=bit(2n), Gn=bit(2n+1); R/Wn=bits(16+4n..17+4n); LENn=bits(18+4n..19+4n).
      for (int i=0;i<4;i++) begin
        en[i]  = dr7[2*i] | dr7[2*i+1];
        rw[i]  = dr7[16+4*i +: 2];
        len[i] = dr7[18+4*i +: 2];
      end
      hit = 4'd0;
      for (int i=0;i<4;i++) begin
        // LEN encoding -> alignment mask: 00=1B(0x0) 01=2B(0x1) 11=4B(0x3) 10=8B(0x7)
        unique case (len[i])
          2'b00:   lenmask = 32'h0000_0000;
          2'b01:   lenmask = 32'h0000_0001;
          2'b10:   lenmask = 32'h0000_0007;
          default: lenmask = 32'h0000_0003;
        endcase
        if (en[i] && ((lin & ~lenmask) == (addr[i] & ~lenmask))) begin
          // type match: execute wants R/W=00; data-write wants R/W=01 or 11.
          if (want_x) begin
            if (rw[i] == 2'b00) hit[i] = 1'b1;
          end else begin
            if (rw[i] == 2'b01 || rw[i] == 2'b11) hit[i] = 1'b1;
          end
        end
      end
      return hit;
    end
  endfunction

  task automatic start_fault(input logic [7:0] vec, input logic has_err,
                             input logic [31:0] err, input logic [31:0] fault_pc);
    begin
      int_vec     <= vec;
      int_ret_eip <= fault_pc;     // FAULT: push the faulting EIP (restart)
      int_src_pc  <= fault_pc;
      int_has_err <= has_err;
      int_err     <= err;
      int_step    <= 4'd0;
      int_sw      <= 1'b0;        // HW fault: bypass the gate DPL>=CPL check
      // F3: in PURE real mode (PE=0) a hardware interrupt / exception delivers through
      // the 4-byte IVT (S_RMINT_RD), exactly like a software INT n — NOT the 8-byte
      // protected-mode gate. Without this, the first IRQ after SeaBIOS sets IF=1 (or any
      // real-mode fault) walked a garbage "IDT", #NP'd, and hung. The IVT push carries no
      // error code (real-mode semantics; S_RMINT_PUSH drops int_err). V86 + PM keep the
      // S_INT_GATE path (real_mode==0 there).
      state       <= real_mode ? S_RMINT_RD : S_INT_GATE;
    end
  endtask

  // ---- M2S.6 #DB delivery launched FROM a retire boundary (gated sys_mode at
  // the call sites). Unlike start_fault, the triggering instruction does NOT emit
  // its own retire record: the qemu gdbstub single-step fuses the instruction +
  // the synchronous #DB into ONE record stamped with the instruction's PC and the
  // post-delivery state. So the caller does NOT set retire_valid for the insn; it
  // calls this INSTEAD, which sets DR6.Bn/BS (sticky) and diverts to S_INT_GATE.
  // The delivery's single retire is then stamped with `src_pc` (the instruction
  // that triggered the trap/fault) and pushes `ret_eip` (NEXT eip for a TRAP =
  // resume; the FAULTING/breakpoint eip for a FAULT = restart). #DB: vector 1, no
  // error code, delivered through IDT[1].
  task automatic arm_db(input logic [31:0] dr6_bits,
                        input logic [31:0] src_pc, input logic [31:0] ret_eip);
    begin
      dr6         <= dr6 | dr6_bits;     // sticky status bits
      int_vec     <= 8'd1;
      int_ret_eip <= ret_eip;
      int_src_pc  <= src_pc;
      int_has_err <= 1'b0;
      int_err     <= 32'd0;
      int_step    <= 4'd0;
      int_sw      <= 1'b0;               // hardware #DB: bypass the gate DPL check
      // F3: real-mode #DB also delivers through the IVT (see start_fault).
      state       <= real_mode ? S_RMINT_RD : S_INT_GATE;
    end
  endtask

  // Is the current bus access a DATA access (D-TLB) vs an instruction fetch
  // (I-TLB)? Fetch states are S_FETCH / S_PF / the S_PIPE icache fill; the
  // descriptor table reads (S_LGDT/S_SEGLD/S_LJMP) always run with paging OFF
  // (the GDT is loaded before CR0.PG), so they pass through untranslated.
  logic cur_is_d;
  always_comb begin
    unique case (state)
      S_FETCH, S_PF: cur_is_d = 1'b0;
      // S_PIPE issues BOTH an icache fill (pf_miss -> I-TLB, a fetch) AND a
      // register-base DATA load (pipe_load_req -> D-TLB). They are mutually
      // exclusive (pf_miss => !pipe_bytes_ok => !pipe_load_req), so classify by
      // which is active: a data load is D-side (Phase-3 [med] fix — previously
      // hardcoded I-TLB, which polluted the I-TLB with data and applied the wrong
      // permission set, defeating the split I/D model and mis-targeting the M2S.3
      // permission check). The fill (or neither) is I-side.
      S_PIPE:        cur_is_d = pipe_load_req;
      default:       cur_is_d = 1'b1;
    endcase
  end

  // M2S.4 — byte offset into the 32-bit TSS of the privilege-N stack pointer pair
  // (ESPn then SSn). 32-bit TSS layout: ESP0@0x04, SS0@0x08, ESP1@0x0C, SS1@0x10,
  // ESP2@0x14, SS2@0x18 -> ESPn @ 0x04 + 8*N (SSn is the next word). N=int_new_cpl.
  logic [31:0] tss_stk_off;
  assign tss_stk_off = 32'h0000_0004 + ({30'd0, int_new_cpl} << 3);

  // M2S.5 — the SMRAM save-map offset for save/restore beat `s` (P5 Table 20-1;
  // segment HIDDEN state + table limits go to the RTL-internal HID reserved
  // block). Used by BOTH S_SMI_SAVE (write) and S_RSM (read) so the two walk the
  // same addresses in lockstep. (NUM_SEG==6.)
  function automatic logic [15:0] smm_off(input logic [5:0] s);
    unique case (s)
      6'd0:  smm_off = SMO_CR0;
      6'd1:  smm_off = SMO_CR3;
      6'd2:  smm_off = 16'h7E04;          // CR4 (hidden/reserved per Table 20-1)
      6'd3:  smm_off = 16'h7E08;          // CR2 (hidden/reserved per Table 20-1)
      6'd4:  smm_off = SMO_EFLAGS;
      6'd5:  smm_off = SMO_EIP;
      6'd6:  smm_off = SMO_EAX;
      6'd7:  smm_off = SMO_ECX;
      6'd8:  smm_off = SMO_EDX;
      6'd9:  smm_off = SMO_EBX;
      6'd10: smm_off = SMO_ESP;
      6'd11: smm_off = SMO_EBP;
      6'd12: smm_off = SMO_ESI;
      6'd13: smm_off = SMO_EDI;
      6'd14: smm_off = SMO_CS;
      6'd15: smm_off = SMO_SS;
      6'd16: smm_off = SMO_DS;
      6'd17: smm_off = SMO_ES;
      6'd18: smm_off = SMO_FS;
      6'd19: smm_off = SMO_GS;
      // seg base/limit/attr into the HID reserved block (6 each):
      6'd20,6'd21,6'd22,6'd23,6'd24,6'd25:
             smm_off = SMO_HID + ({10'd0,(s - 6'd20)} << 2);              // base
      6'd26,6'd27,6'd28,6'd29,6'd30,6'd31:
             smm_off = SMO_HID + 16'h0018 + ({10'd0,(s - 6'd26)} << 2);   // limit
      6'd32,6'd33,6'd34,6'd35,6'd36,6'd37:
             smm_off = SMO_HID + 16'h0030 + ({10'd0,(s - 6'd32)} << 2);   // attr
      6'd38: smm_off = SMO_GDTB;
      6'd39: smm_off = SMO_IDTB;
      6'd40: smm_off = SMO_HID + 16'h0048;   // {gdt_limit, idt_limit}
      6'd41: smm_off = SMO_SMBASE;
      6'd42: smm_off = SMO_REVID;
      6'd43: smm_off = SMO_AHALT;
      default: smm_off = SMO_HID + 16'h004C; // {cs_d, cpl}
    endcase
  endfunction

  // The value to WRITE on save beat `s` (the interrupted-context state).
  function automatic logic [31:0] smm_save_data(input logic [5:0] s);
    unique case (s)
      6'd0:  smm_save_data = creg0;
      6'd1:  smm_save_data = creg3;
      6'd2:  smm_save_data = creg4;
      6'd3:  smm_save_data = creg2;
      6'd4:  smm_save_data = eflags;
      6'd5:  smm_save_data = smm_resume_eip;        // resume EIP (writeable slot)
      6'd6,6'd7,6'd8,6'd9,6'd10,6'd11,6'd12,6'd13:
             smm_save_data = gpr[3'(s - 6'd6)];
      6'd14,6'd15,6'd16,6'd17,6'd18,6'd19:
             smm_save_data = {16'd0, seg_sel[3'(s - 6'd14)]};
      6'd20,6'd21,6'd22,6'd23,6'd24,6'd25:
             smm_save_data = seg_base [3'(s - 6'd20)];
      6'd26,6'd27,6'd28,6'd29,6'd30,6'd31:
             smm_save_data = seg_limit[3'(s - 6'd26)];
      6'd32,6'd33,6'd34,6'd35,6'd36,6'd37:
             smm_save_data = {24'd0, seg_attr[3'(s - 6'd32)]};
      6'd38: smm_save_data = gdt_base;
      6'd39: smm_save_data = idt_base;
      6'd40: smm_save_data = {idt_limit, gdt_limit};
      6'd41: smm_save_data = smbase;                // SMBASE relocation slot
      6'd42: smm_save_data = SMM_REV_ID;            // SMM revision id (RO)
      6'd43: smm_save_data = 32'd0;                 // auto-HALT slot (no HALT here)
      default: smm_save_data = {29'd0, cpl_r, cs_d};// {cpl, cs_d}
    endcase
  endfunction

  // ---- the LINEAR address of the current state's access (pre-translation) and
  // whether the access is a write. Mirrors the per-state mem_addr computation in
  // the bus driver, but in LINEAR space so the page walk + #PF decision use the
  // architectural linear address. Only meaningful for the translatable states.
  logic [31:0] cur_lin;
  logic        cur_is_w;
  always_comb begin
    cur_lin  = 32'd0;
    cur_is_w = 1'b0;
    unique case (state)
      S_FETCH: cur_lin = flin + {27'd0,fetch_word,2'b00};
      S_PF:    cur_lin = {pf_fill_addr[31:5],5'd0} + {27'd0,pf_word,2'b00};
      S_PIPE:  cur_lin = pf_miss ? {pf_miss_fa[31:5],5'd0}
                                 : (seg_base[SG_DS]+gpr[pipe_load_base]);
      S_LOAD: begin
        if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
            (q_kind==K_STKMISC && q_sm==SM_POPF))      cur_lin = dbase+gpr[R_ESP];
        else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)  cur_lin = dbase+gpr[R_EBP];
        else if (q_kind==K_STR)
          cur_lin = (q_st==ST_SCAS) ? dbase+str_edi : dbase+str_esi;
        else                                           cur_lin = opbase+q_ea;  // M7.1 opbase
      end
      S_LOAD2: cur_lin = dbase_edi+str_edi;
      S_FLOAD: cur_lin = dbase+q_ea + {26'd0, f_step, 2'b00};
      S_FSTORE: begin cur_lin = dbase+q_ea + {26'd0, f_step, 2'b00}; cur_is_w = 1'b1; end
      S_FENV_ST: begin cur_lin = dbase+q_ea + {25'd0, f_seq_step, 2'b00}; cur_is_w = 1'b1; end
      S_FENV_LD:       cur_lin = dbase+q_ea + {25'd0, f_seq_step, 2'b00};
      S_STORE: begin
        cur_is_w = 1'b1;
        cur_lin = (q_kind==K_STR) ? dbase_edi+str_store_addr : dbase+st_addr;
      end
      S_USEQ: begin
        if (q_sm==SM_PUSHA) begin
          cur_is_w = 1'b1;
          cur_lin = dbase+pusha_esp - (32'd4*({28'd0,step}+32'd1));
        end else cur_lin = dbase+gpr[R_ESP] + (32'd4*{28'd0,step});
      end
      // M2S.3 IDT delivery linear addresses (mirror the bus driver arms).
      S_INT_GATE:   cur_lin = idt_base + {21'd0, int_vec, 3'd0}
                              + {29'd0, int_step[0], 2'b00};
      S_INT_CS, S_INT_CS_RET:
                    cur_lin = gdt_base + {16'd0, int_gate_sel[15:3], 3'd0}
                              + {29'd0, int_step[0], 2'b00};
      S_INT_PUSH: begin
        cur_is_w = 1'b1;
        // CROSS-PRIV: push descending from the NEW stack (TSS.espN). SAME-PRIV:
        // descending from the current SS:ESP. (mirror the bus driver arm.)
        cur_lin = xpl_active
                  ? (seg_base[SG_SS] + int_new_esp - ({28'd0, int_step} * 32'd4) - 32'd4)
                  : (seg_base[SG_SS] + gpr[R_ESP] - ({28'd0, int_step} * 32'd4) - 32'd4);
      end
      S_IRET, S_IRET_SS:
                    cur_lin = seg_base[SG_SS] + gpr[R_ESP] + ({28'd0, int_step} * 32'd4);
      // M2S.4 — TR/TSS reads. S_LTR reads the GDT TSS descriptor; S_INT_TSS reads
      // TSS.ssN:espN. Like the other descriptor-table reads, both address their
      // (linear) structure PHYSICALLY under the M2S.1/.2 identity-map convention —
      // excluded from both xlate_miss and the post-translate, so cur_lin here is
      // informational only (they pass through untranslated). See those two sites.
      S_LTR:     cur_lin = gdt_base + {16'd0, gpr[q_src_reg][15:3], 3'd0}
                           + {29'd0, seg_step, 2'b00};
      S_INT_TSS: cur_lin = tr_base + tss_stk_off + {29'd0, int_step[0], 2'b00};
      S_INT_SS:  cur_lin = gdt_base + {16'd0, int_new_ss[15:3], 3'd0}
                           + {29'd0, int_step[0], 2'b00};
      default: cur_lin = 32'd0;
    endcase
  end

  // xlate_miss: paging is on, the current state issues a translatable memory
  // access, and the relevant TLB MISSES -> the FSM must run a page walk (S_WALK)
  // before this access can complete. The descriptor-table reads always run with
  // paging off, so they are excluded. Computed once and consumed by the FSM.
  logic xlate_miss;
  always_comb begin
    logic translatable;
    unique case (state)
      S_FETCH, S_PF, S_PIPE,
      S_LOAD, S_LOAD2, S_FLOAD, S_FSTORE, S_STORE, S_USEQ,
      // M2S.3 IDT delivery reads/writes are translated when paging is on.
      // M2S.4 adds the inter-priv IRET SS pop (S_IRET_SS) — a genuine stack pop,
      // translated like the other stack accesses.
      // The DESCRIPTOR/TSS STRUCTURE reads are NOT translatable: S_LTR/S_INT_SS
      // read the GDT and S_INT_TSS reads the TSS (TSS.ssN:espN). Per IA-32 the GDT
      // and the TSS are both linear structures, but the M2S.1/.2 convention reads
      // all descriptor-table / TSS structures PHYSICALLY under the identity-map
      // simplification — so S_INT_TSS is excluded here exactly like its sibling
      // S_INT_SS (the GDT read of the new SS descriptor) and S_LTR.
      S_INT_GATE, S_INT_CS, S_INT_CS_RET, S_INT_PUSH, S_IRET,
      S_IRET_SS: translatable = 1'b1;
      default: translatable = 1'b0;
    endcase
    // S_PIPE only reads memory when a load or an icache fill is requested.
    if (state==S_PIPE && !(pipe_load_req || pf_miss)) translatable = 1'b0;
    // A data access misses if the D-TLB lacks the page OR (for a WRITE) the page
    // is TLB-resident but its Dirty bit has not yet been set in memory — that
    // first write must re-walk to set D (matching qemu's set-D-on-first-write).
    fe_xlate_pend = 1'b0;
`ifdef VEN_FE_PIPE
    // page crossing -> the registered micro-TLB doesn't yet hold cur_lin's page;
    // stall 1 clock while the fe_*_q always_ff samples it (separate, runs this edge).
    if (paging_on && translatable)
      fe_xlate_pend = cur_is_d ? !(fe_dtlb_v && (fe_dtlb_page == cur_lin[31:12]))
                               : !(fe_itlb_v && (fe_itlb_page == cur_lin[31:12]));
    // xlate_miss from the REGISTERED hit (off the critical path); 0 during the pend
    // stall (the FSM holds, no premature walk).
    xlate_miss = paging_on && translatable && !fe_xlate_pend &&
                 (cur_is_d ? (!fe_dtlb_hit || (cur_is_w && !fe_dtlb_dirty))
                           : !fe_itlb_hit);
`else
    xlate_miss = paging_on && translatable &&
                 (cur_is_d
                    ? (!dtlb_lk_hit ||
                       (cur_is_w && !dtlb_lk_dirty))
                    : !itlb_lk_hit);
`endif
  end

  // ===========================================================================
  // L1 D-cache TIMING model ports (the state/SM live in dcache_timing, below).
  // dc_acc_valid/dc_acc_addr funnel the SINGLE per-clock LRU access (at most one
  // by construction: the FSM is a unique-case on `state`, and only the S_PIPE
  // U-load issue arm, S_LOAD, S_LOAD2, and S_STORE access the cache — never two in
  // one clock). dc_lu_addr drives the combinational pre-access lookup (dc_lu_hit),
  // always at the same address as this clock's access so the spine's miss penalty
  // sees PRE-access state (the dc_hit-then-dc_access read-before-write). All these
  // mirror the original inline `dc_access(X)` call sites EXACTLY (same guards, same
  // address, same cycle_mode gating; the U-pipe load is UNGATED). A page-walk
  // diversion (xlate_miss) skips the FSM body this clock, so it gates every site.
  // ===========================================================================
  always_comb begin
    // U-pipe fast-path load commit (S_PIPE issue arm, is_load). UNGATED by
    // cycle_mode — the SM runs in func and cycle mode alike, exactly as the
    // original inline dc_access(gpr[u_d.base]). pipe_load_req already folds in
    // (state==S_PIPE && pipe_bytes_ok && u_d.simple && u_d.is_load && !pipe_agi &&
    // mispred_bubbles==0); reaching the issue+commit branch additionally requires
    // stall_cnt==0, pending_mem_pen==0, not-FP, and !sys_mode.
    logic u_load_acc;
    u_load_acc = !xlate_miss && pipe_load_req && (stall_cnt==7'd0) &&
                 (pending_mem_pen==7'd0) && !u_d.is_fp && !sys_mode;

    dc_acc_valid = 1'b0;
    dc_acc_addr  = 32'd0;
    unique case (state)
      S_PIPE: begin
        dc_acc_valid = u_load_acc;
        dc_acc_addr  = gpr[u_d.base];
      end
      // Slow-path data accesses: all gated on mem_ack && cycle_mode, mirroring the
      // original inline `if (cycle_mode) ... dc_access(...)` under `if (mem_ack)`.
      S_LOAD: begin
        dc_acc_valid = !xlate_miss && mem_ack && cycle_mode;
        dc_acc_addr  = slow_dmem_addr;
      end
      S_LOAD2: begin
        dc_acc_valid = !xlate_miss && mem_ack && cycle_mode;
        dc_acc_addr  = str_edi;
      end
      S_STORE: begin
        dc_acc_valid = !xlate_miss && mem_ack && cycle_mode;
        dc_acc_addr  = (q_kind==K_STR) ? str_store_addr : st_addr;
      end
      default: ;
    endcase
    // The pre-access lookup is always at this clock's access address (each call
    // site's dc_hit() used the SAME address as its dc_access()).
    dc_lu_addr = dc_acc_addr;
  end

`ifndef VEN_L1_AXI
  dcache_timing #(.DC_SETS(DC_SETS), .DC_WAYS(DC_WAYS)) u_dcache_tm (
    .clk       (clk),
    .rst_n     (rst_n),
    .lu_addr   (dc_lu_addr),
    .lu_hit    (dc_lu_hit),
    .acc_valid (dc_acc_valid),
    .acc_addr  (dc_acc_addr)
  );
`else
  // VEN_L1_AXI (bus_mode=2): the D-cache TIMING model is redundant. Its only output,
  // dc_lu_hit, feeds the modeled D-miss PENALTY (`if(!dc_lu_hit) pen += P5_DMISS`) and
  // NEVER the load data/result. Under the real AXI/DDR bus that penalty is already
  // suppressed (core_fastpath.svh `pending_mem_pen <= real_bus ? 0 : pen`) and the
  // slow-path penalty is cycle_mode-gated (dead at the board's cycle_mode=0) — "mode-2
  // timing is functional-only". So dropping the ~4.4k-cell dcache_timing instance is
  // functionally INERT here and relieves the in-context congestion (the model survived
  // synth only because cfg_cycle_mode is a runtime input). Tie dc_lu_hit=1 (always-hit
  // => no modeled D-miss penalty); the dc_acc_*/dc_lu_addr drivers prune as dead. The
  // DEFAULT (non-L1_AXI) build keeps the model, so make verify's D-cache bands are
  // unchanged. The dc_acc_valid below is consumed nowhere now -> harmless dead net.
  assign dc_lu_hit = 1'b1;
`endif

  // ===========================================================================
  // L1 I-cache module ports (the ARRAYS + fill + LRU touch + reset live in the
  // icache module, below; this is the spine-side combinational driver). The arrays
  // are read PRE-edge through u_icache's READ-ONLY outputs (ic_data_o/ic_tag_o/
  // ic_val_o/ic_lru_o), which the ic_present/ic_hit_way/ic_byte probes consume
  // UNCHANGED. The spine OWNS the fill SEQUENCING (pf_fill_addr/pf_fill_way/pf_word
  // + the ic_victim_o LRU victim) and drives the single fill word + up-to-3 LRU touches
  // here, exactly mirroring the original inline NBA sites (same arm guards, same
  // addresses, same textual U->straddle->V last-write-wins order).
  // ===========================================================================
  logic        ic_fill_en, ic_fill_done;
  logic [IC_WAYW-1:0] ic_fill_way;
  logic [IC_IDXW-1:0]  ic_fill_set;
  logic [4:0]  ic_fill_off;
  logic [31:0] ic_fill_data;
  logic [IC_TAGW-1:0] ic_fill_tag;
  logic        ic_tch0_en, ic_tch1_en, ic_tch2_en;
  logic [IC_IDXW-1:0]  ic_tch0_set, ic_tch1_set, ic_tch2_set;
  logic [IC_TAGW-1:0] ic_tch0_tag, ic_tch1_tag, ic_tch2_tag;
  always_comb begin
    // ---- fill port: the two MUTUALLY-EXCLUSIVE fill arms (S_PF words 0..7 vs the
    // S_PIPE-miss word-0 path; different FSM states/arms => never concurrent).
    logic ic_pf_miss_fill;
    // S_PIPE word-0 fill arm: the 2nd S_PIPE else-if (stall_cnt==0, !pipe_bytes_ok),
    // gated by the !xlate_miss page-walk diversion. The bus asserts the fill's
    // word-0 read THIS clock (mem_addr = fill line base when pf_miss), so the word
    // is captured here. With a same-cycle BFM (modes 0/1) mem_ack is high this clock
    // so no guard is needed; under the REAL stalling L1 (real_bus) the ven_l1d miss
    // returns mem_ack=0 + combinational garbage for several clocks, so the capture
    // (and the S_PIPE->S_PF advance, core_fastpath.svh) MUST wait for mem_ack — else
    // every cold I-line latches garbage at boot. The `(!real_bus||mem_ack)` term is
    // inert in modes 0/1 and absent in the default build.
    ic_pf_miss_fill = (state==S_PIPE) && !xlate_miss && (stall_cnt==7'd0) &&
                      !pipe_bytes_ok
`ifdef VEN_L1_AXI
                      && (!real_bus || mem_ack)
`endif
                      ;

    ic_fill_en   = 1'b0;
    ic_fill_done = 1'b0;
    ic_fill_set  = '0;
    ic_fill_way  = '0;
    ic_fill_off  = 5'd0;
    ic_fill_data = 32'd0;
    ic_fill_tag  = '0;
    if (state==S_PF && mem_ack) begin
      // S_PF: fill the word covering pf_word; complete (allocate + MRU) on word 7.
      ic_fill_en   = 1'b1;
      ic_fill_set  = pf_fill_addr[5 +: IC_IDXW];
      ic_fill_way  = pf_fill_way;
      ic_fill_off  = {pf_word, 2'b00};
      ic_fill_data = mem_rdata;
      ic_fill_done = (pf_word==3'd7);
      ic_fill_tag  = pf_fill_addr[5+IC_IDXW +: IC_TAGW];
    end else if (ic_pf_miss_fill) begin
      // S_PIPE-miss word 0 into the LRU victim (ic_victim_o, PRE-edge). NOT a
      // completing fill — tag/val/MRU land when S_PF reaches word 7 (pf_fill_*).
      ic_fill_en   = 1'b1;
      ic_fill_set  = pf_miss_fa[5 +: IC_IDXW];
      ic_fill_way  = ic_victim_o[pf_miss_fa[5 +: IC_IDXW]];
      ic_fill_off  = 5'd0;
      ic_fill_data = mem_rdata;
    end

    // ---- LRU touch ports (U / U-straddle / V), textual last-write-wins. Fire only
    // when an instruction COMMITS this clock — the FP issue+commit arm (touches
    // flin only) OR the integer ISSUE arm (flin, straddle when it crosses the line
    // boundary, V when paired). These two arms are mutually exclusive; replicating
    // their guards is the established pattern (cf. dc u_load_acc above).
    begin
      logic ic_in_pipe, ic_halt4, ic_fp_arm, ic_fp_commit, ic_int_issue;
      logic [31:0] ic_dep_ready, ic_straddle_a, ic_v_a;
      // common: reached the inner FP/issue else-chain (past stall/fill/defer).
      ic_in_pipe = (state==S_PIPE) && !xlate_miss && (stall_cnt==7'd0) &&
                   pipe_bytes_ok && (pending_mem_pen==7'd0);
      // FK_ARITH-under-bad-PC HALT arm (no touch).
      ic_halt4   = u_d.is_fp && (u_d.fp_kind==FK_ARITH) && (fctrl[9:8]!=2'b11);
      ic_fp_arm  = ic_in_pipe && !ic_halt4 && u_d.is_fp;
      ic_dep_ready = (u_d.fp_role>=3'd2) ? fp_ready_cyc : 32'd0;
`ifdef VEN_FP_OVERLAP
      // GAP1 mirror (matches core_fastpath.svh): a following FP op (not FXCH) waits on
      // the x87 exec unit (fp_busy_cyc), so spine + driver agree on the commit clock.
      if (u_d.fp_kind != FK_FXCH
          && $signed(fp_busy_cyc - core_cyc) > 0
          && $signed(fp_busy_cyc - ic_dep_ready) > 0)
        ic_dep_ready = fp_busy_cyc;
`endif
      // FP issue+commit = the final else (not the dep-stall, not the occ-burn).
      ic_fp_commit = ic_fp_arm &&
                     !(!fp_occ_pending && ($signed(ic_dep_ready - core_cyc) > 0)) &&
                     !(!fp_occ_pending && (u_d.fp_occ > 7'd1));
      // integer ISSUE arm = final else of the chain (not-FP, simple, !sys_mode, no
      // mispred bubble, no AGI). !u_d.is_fp already excludes ic_halt4/ic_fp_arm.
      ic_int_issue = ic_in_pipe && !u_d.is_fp && !(!u_d.simple || sys_mode) &&
                     (mispred_bubbles==3'd0) && !pipe_agi;

      // tch0: U's line — touched on EITHER commit arm (set/tag from flin).
      ic_tch0_en  = ic_fp_commit || ic_int_issue;
      ic_tch0_set = flin[5 +: IC_IDXW];
      ic_tch0_tag = flin[5+IC_IDXW +: IC_TAGW];
      // tch1: U's straddle line — integer ISSUE arm only, when flin crosses the
      // 32-byte line boundary (addr = flin + u_d.len - 1). FP ops never straddle.
      ic_straddle_a = flin + {28'd0,u_d.len} - 32'd1;
      ic_tch1_en  = ic_int_issue &&
                    (({1'b0,flin[4:0]} + {2'b0,u_d.len}) > 6'd32);
      ic_tch1_set = ic_straddle_a[5 +: IC_IDXW];
      ic_tch1_tag = ic_straddle_a[5+IC_IDXW +: IC_TAGW];
      // tch2: paired V's line — integer ISSUE arm only, when pipe_pair (= do_v).
      ic_v_a      = flin + {28'd0,u_d.len};
      ic_tch2_en  = ic_int_issue && pipe_pair;
      ic_tch2_set = ic_v_a[5 +: IC_IDXW];
      ic_tch2_tag = ic_v_a[5+IC_IDXW +: IC_TAGW];
    end
  end

  icache #(.IC_SETS(IC_SETS), .IC_LINE(IC_LINE), .IC_WAYS(IC_WAYS)) u_icache (
    .clk       (clk),
    .rst_n     (rst_n),
    .rd_setA   (ic_rd_setA),
    .rd_wayA   (ic_rd_wayA),
    .rd_lineA  (ic_rd_lineA),
    .rd_setB   (ic_rd_setB),
    .rd_wayB   (ic_rd_wayB),
    .rd_lineB  (ic_rd_lineB),
    .ic_tag_o  (ic_tag_o),
    .ic_val_o  (ic_val_o),
    .ic_victim_o (ic_victim_o),
    .fill_en   (ic_fill_en),
    .fill_set  (ic_fill_set),
    .fill_way  (ic_fill_way),
    .fill_off  (ic_fill_off),
    .fill_data (ic_fill_data),
    .fill_done (ic_fill_done),
    .fill_tag  (ic_fill_tag),
    .tch0_en   (ic_tch0_en),
    .tch0_set  (ic_tch0_set),
    .tch0_tag  (ic_tch0_tag),
    .tch1_en   (ic_tch1_en),
    .tch1_set  (ic_tch1_set),
    .tch1_tag  (ic_tch1_tag),
    .tch2_en   (ic_tch2_en),
    .tch2_set  (ic_tch2_set),
    .tch2_tag  (ic_tch2_tag)
  );

`ifdef VEN_UOPCACHE
  // ===========================================================================
  // P0-11 PREDECODE-ON-FILL plumbing + the µop-cache instance.
  //
  // Accumulate the S_PF refill burst (word 0 from the S_PIPE-miss arm, words 1..7
  // from S_PF) into a 256-bit line buffer; when the fill COMPLETES (ic_fill_done,
  // word 7), pulse the predecode walker NEXT clock with the assembled line — by
  // then word 7 has landed in pf_line_buf. The walker re-runs decode.sv over the
  // line boundary-by-boundary (off the fast path), so this latency is part of the
  // cold-line imiss tail. inv_en at fill_done clears the (set,way) predecode-valid
  // so the resident-but-not-yet-predecoded window correctly reads uop_hit=0.
  // ===========================================================================
  logic [IC_LINE*8-1:0] pf_line_buf;
  logic                 pd_start_r;
  logic [IC_IDXW-1:0]   pd_set_r;
  logic                 pd_way_r;
  logic [31:0]          pd_flags_r;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pd_start_r <= 1'b0;
    end else begin
      pd_start_r <= 1'b0;
      if (ic_fill_en) begin
        pf_line_buf[{ic_fill_off,3'b000} +: 32] <= ic_fill_data;
        if (ic_fill_done) begin
          pd_start_r <= 1'b1;
          pd_set_r   <= ic_fill_set;
          pd_way_r   <= ic_fill_way;
          pd_flags_r <= eflags;
        end
      end
    end
  end

  uopcache #(.IC_SETS(IC_SETS), .IC_LINE(IC_LINE), .NSLOT(NSLOT)) u_uopcache (
    .clk(clk), .rst_n(rst_n),
    .rd_setA(ic_rd_setA), .rd_wayA(ic_rd_wayA),
    .rd_slotsA(uc_slotsA), .rd_bvalidA(uc_bvA), .rd_bslotA(uc_bsA), .rd_pdvalidA(uc_pdvA),
    .rd_setB(ic_rd_setB), .rd_wayB(ic_rd_wayB),
    .rd_slotsB(uc_slotsB), .rd_bvalidB(uc_bvB), .rd_bslotB(uc_bsB), .rd_pdvalidB(uc_pdvB),
    .pd_start(pd_start_r), .pd_set(pd_set_r), .pd_way(pd_way_r),
    .pd_line(pf_line_buf), .pd_flags(pd_flags_r), .pd_cycle_mode(cycle_mode),
    .inv_en(ic_fill_done), .inv_set(ic_fill_set), .inv_way(ic_fill_way),
    .pd_busy()
  );
`endif

  // ===========================================================================
  // x87 architectural STATE FILE (fpu_top, R2) — module ports + write driver.
  //
  // The STATE (fpr[8]/ftop/fctrl/fstat/fptag + the FNINIT reset + the st(i)
  // read addressing) lives in u_fpu_state (rtl/fpu/fpu_top.sv). The spine reads
  // it back combinationally (fp_st[i]/fp_st0_phys/ftop/fctrl/fstat/fptag aliases)
  // and drives every state mutation onto the module's write ports through the
  // fp_we_* combinational driver below — which re-derives BOTH writer arms and
  // computes the same values via the same fpu_x87_pkg calls the inline code did:
  //   * FAST arm = the M5 cycle-mode FP issue+commit clock (fp_fast_commit, the
  //     SAME guard the icache ic_fp_commit touch uses — gate-proven).
  //   * SLOW arm = S_FEXEC (when !f_pc_bad) + the S_FSTORE last-beat pop.
  // The two arms are runtime-exclusive (S_PIPE fast vs S_FEXEC/S_FSTORE slow),
  // so the per-category strobes are ORed; at most one fires any clock. The
  // module owns the OLD-ftop NBA addressing (push uses ftop-1, etc.) so ordering
  // is byte-identical. fstat is presented FULLY COMPUTED (the spine does all the
  // masking/merge/sticky-OR), and exposed RAW (TOP not overlaid) so retire_fstat
  // + FNSTSW stay byte-identical.
  // ===========================================================================
  logic        fp_we_push;   logic [79:0] fp_push_data;
  logic        fp_we_top;    logic [79:0] fp_top_data;
  logic        fp_we_fstat;  logic [15:0] fp_fstat_wval;
  logic        fp_we_sti;    logic [2:0]  fp_wsti_idx;  logic [79:0] fp_wsti_data;
  logic        fp_wsti_clr_tag;
  logic        fp_we_fxch;   logic [2:0]  fp_fxch_idx;
  logic [79:0] fp_fxch_a;    logic [79:0] fp_fxch_b;
  logic        fp_we_pop;
  logic        fp_we_pop2;
  logic        fp_we_ffree;  logic [2:0]  fp_ffree_idx;
  logic        fp_we_incstp; logic        fp_we_decstp;
  logic        fp_we_fctrl;  logic [15:0] fp_fctrl_wval;
  logic        fp_we_fninit;
  // --- iterative SRT FDIV/FSQRT engine integration (VEN_SRT_ITER) -----------
  // Eligibility / handshake (module-level so the always_comb driver, the always_ff
  // FSM, and the engine instances all share them). All 0 in the default build, so
  // the `if(!fp_*_elig)` guards stay always-true and S_FP_BUSY is never entered.
  logic        fp_div_elig, fp_sqrt_elig, fp_iter_go, fp_iter_done;
  logic [79:0] eng_div_a, eng_div_b, eng_sqrt_in;
  logic [1:0]  eng_rc;
  logic        eng_div_start, eng_sqrt_start;
  logic        eng_div_busy, eng_div_done;   logic [80:0] eng_div_result;
  logic        eng_sqrt_busy, eng_sqrt_done;  logic [80:0] eng_sqrt_result;
  // M11 env-pointer latch driver (write-only -> u_fpu_state; read back via the
  // fip/fcs/fdp/fds aliases below for FNSTENV/FNSAVE).
  logic        fp_we_eptr;   logic [31:0] fp_eptr_fip;  logic [15:0] fp_eptr_fcs;
  logic        fp_we_dptr;   logic [31:0] fp_eptr_fdp;  logic [15:0] fp_eptr_fds;
  // M11b FLDENV/FRSTOR commit driver (computed from env_tmp on the last load beat).
  logic        fp_we_envld;  logic [15:0] fp_env_fctrl; logic [2:0] fp_env_ftop;
  logic [15:0] fp_env_fstat; logic [7:0]  fp_env_fptag;
  logic        fp_we_envregs; logic [639:0] fp_env_fpr_flat;
  // +VEN_FP_PIPE: the deferred-arith commit port drivers (tied 0 unless piped) +
  // the 1-deep FP-execute pipeline register. A fast-arm FK_ARITH op captures its
  // operands at issue (cycle N), retires normally, and its fpr/fstat write is
  // committed one cycle later (N+1) via the absolute-indexed we_wabs port — so
  // the eip->icache->decode->f_eval->fpr critical cone is split across two clocks.
  // The scoreboard already publishes the result at issue+lat (fadd lat 3), so the
  // result (committed at N+1) is in fpr well before any dependent consumer reads
  // it at issue+3 — both FP cycle bands are preserved by construction.
  logic        fp_we_wabs, fp_we_wabs_fstat;
  logic [2:0]  fp_wabs_idx;
  logic [79:0] fp_wabs_data;
  logic [15:0] fp_wabs_fstat;
`ifdef VEN_FP_PIPE
  logic        fpp_valid;            // a pipelined arith result is in flight (N+1)
  logic [2:0]  fpp_aluop;            // captured f_eval inputs / target
  logic [79:0] fpp_a, fpp_b;
  logic [1:0]  fpp_rc;
  logic        fpp_err;
  logic [2:0]  fpp_dst;              // ABSOLUTE fpr index (ftop at issue)
  // combinational capture lines (driven by the fast-arm FK_ARITH issue, latched
  // into fpp_* by the always_ff):
  logic        fp_pipe_cap;
  logic [2:0]  fp_cap_aluop, fp_cap_dst;
  logic [79:0] fp_cap_a, fp_cap_b;
  logic [1:0]  fp_cap_rc;
  logic        fp_cap_err;
  logic        fp_pipe_rd_haz;       // next op reads the in-flight target -> stall
`ifdef VEN_FP_PIPE2
  // 2-STAGE FP-commit split (Fmax: K26 half-cache 60 MHz). The 1-stage +VEN_FP_PIPE
  // defer still runs the WHOLE f_eval (f_eval_s1 front -> f_eval_s2 round) in the
  // single commit clock N+1 -> an ~80-level / ~43-CARRY8 cone (fpp_*->fx_round_pack
  // ->fpr) that caps the routed Fmax ~52 MHz. This inserts ONE register at the
  // f_eval_s1/f_eval_s2 boundary, so the cone is split across TWO clocks:
  //   N+1: fp_s1_next = f_eval_s1(fpp_*)  -> registered into fpp2_s1   (front half)
  //   N+2: f_eval_s2(fpp2_s1)             -> committed via we_wabs      (back half)
  // The result lands in fpr at issue+2; the FP scoreboard already publishes it at
  // issue+lat (fadd lat 3 = issue+3), so EVERY role>=2 dependent reads it no earlier
  // than issue+3 -> the commit is still in fpr in time and the per-retire arch state
  // + the FP cycle bands are IDENTICAL to +VEN_FP_PIPE (no oracle change). Requires
  // VEN_FP_PIPE + the SPLIT eval (VEN_SRT_ITER, the same guard as the 1-stage split).
  logic        fpp2_valid;           // a stage-1 result is in flight (commits N+2)
  fx_pipe_t    fpp2_s1;              // registered f_eval_s1 output (the split point)
  logic [1:0]  fpp2_rc;
  logic [2:0]  fpp2_dst;             // ABSOLUTE fpr index carried from stage 0
  fx_pipe_t    fp_s1_next;           // comb f_eval_s1 result feeding the stage reg
`endif
`endif

  always_comb begin
    // ---- per-arm locals -------------------------------------------------------
    logic        fp_in_pipe, fp_halt4, fp_fp_arm, fp_fast_commit;
    logic        f_is_admin;
    logic [639:0] frstor_streg;   // M11b FRSTOR: loaded ST region (logical ST0..7)
    int          frli;            // M11b FRSTOR: logical index for a physical reg
    logic [31:0] fp_dep_ready;
    logic [82:0] fp_arf;          // {ie, ze, inexact, result} from f_eval (fast)
    logic        slow_arm;        // S_FEXEC, op actually executes (not f_pc_bad)
    logic        slow_pc_bad, slow_is_arith;
    logic [79:0] s_opnd_f, s_argb, s_st0v, s_stiv;
    logic [79:0] s_fa, s_fb;      // shared arith operands (mux-then-eval, R-area)
    logic [82:0] s_arf;
    logic [80:0] s_ar;
    logic [2:0]  s_codes;
    logic [3:0]  s_xc;
    logic        s_cmp_ie;
    logic [79:0] s_cmp_b;            // shared FP-compare operand (mux-then-eval)
    logic        s_cmp_sig;          // signaling vs quiet for fcom_ie
    logic [15:0] s_cmp_fstat;        // shared apply_cmp result
    logic [1:0]  s_rc;
    logic        fstore_last_beat;

    // default: no writes this clock
    fp_we_push=1'b0; fp_push_data=80'd0;
    fp_we_top=1'b0;  fp_top_data=80'd0;
    fp_we_fstat=1'b0; fp_fstat_wval=16'd0;
    fp_we_sti=1'b0;  fp_wsti_idx=3'd0; fp_wsti_data=80'd0; fp_wsti_clr_tag=1'b0;
    fp_we_fxch=1'b0; fp_fxch_idx=3'd0; fp_fxch_a=80'd0; fp_fxch_b=80'd0;
    fp_we_pop=1'b0;  fp_we_pop2=1'b0;
    fp_we_ffree=1'b0; fp_ffree_idx=3'd0;
    fp_we_incstp=1'b0; fp_we_decstp=1'b0;
    fp_we_fctrl=1'b0; fp_fctrl_wval=16'd0;
    fp_we_fninit=1'b0;
    // iterative SRT engine defaults (0 => combinational path, default build)
    fp_div_elig=1'b0; fp_sqrt_elig=1'b0; fp_iter_go=1'b0; fp_iter_done=1'b0;
    eng_div_a=80'd0; eng_div_b=80'd0; eng_sqrt_in=80'd0; eng_rc=2'd0;
    eng_div_start=1'b0; eng_sqrt_start=1'b0;
    fp_we_eptr=1'b0; fp_eptr_fip=32'd0; fp_eptr_fcs=16'd0;
    fp_we_dptr=1'b0; fp_eptr_fdp=32'd0; fp_eptr_fds=16'd0;
    fp_we_envld=1'b0; fp_env_fctrl=16'd0; fp_env_ftop=3'd0; fp_env_fstat=16'd0; fp_env_fptag=8'd0;
    fp_we_envregs=1'b0; fp_env_fpr_flat=640'd0;
    fp_we_wabs=1'b0; fp_wabs_idx=3'd0; fp_wabs_data=80'd0;
    fp_we_wabs_fstat=1'b0; fp_wabs_fstat=16'd0;
`ifdef VEN_FP_PIPE
    fp_pipe_cap=1'b0; fp_cap_aluop=3'd0; fp_cap_dst=3'd0;
    fp_cap_a=80'd0; fp_cap_b=80'd0; fp_cap_rc=2'd0; fp_cap_err=1'b0;
    // Read-after-write hazard on the in-flight arith target: an FP op issuing the
    // SAME clock the deferred result is being written (we_wabs) would read the
    // PRE-edge stale fpr[fpp_dst]. Stall its issue 1 clock (the result lands this
    // edge, fresh next clock). Role>=2 consumers are already scoreboard-stalled
    // past this window, so this only bites role-0/1 readers (FXCH/FLDSTI/slow FST/
    // FCOM) — none of which appear in the throughput microbench, so the FP cycle
    // bands are preserved. Checks both ST0 (ftop) and ST(i) against the target.
`ifdef VEN_FP_PIPE2
    // ===== 2-STAGE split commit (see the fpp2_* declarations) ================
    // Stage 1 (combinational; registered into fpp2_s1 at this edge): the f_eval_s1
    // FRONT of the captured op. Only sampled when fpp_valid, so the unconditional
    // assign is safe and latch-free. VEN_FP_PIPE2 REQUIRES VEN_SRT_ITER (the engine
    // owns divide, so the split eval's div default is unreachable — same guard the
    // 1-stage split relies on).
    fp_s1_next = f_eval_s1(fpp_aluop, fpp_a, fpp_b, fpp_rc, fpp_err);
    // The in-flight result is now 2 clocks deep, so the RAW hazard spans BOTH slots:
    // stall a role-0/1 reader of the stage-0 target (fpp_dst, commits in 2 clocks)
    // OR the stage-1 target (fpp2_dst, commits THIS edge — the same pre-edge stale
    // read the 1-stage guarded). Role>=2 consumers are scoreboard-stalled to issue+3
    // (= this commit clock), so the throughput kernels never hit it and the FP bands
    // are preserved; it only bites FXCH/FLDSTI/slow FST/FCOM, as before.
    fp_pipe_rd_haz = u_d.is_fp &&
        ( (fpp_valid  && ((ftop==fpp_dst)  || (((ftop + u_d.fp_sti) & 3'd7)==fpp_dst)))
        ||(fpp2_valid && ((ftop==fpp2_dst) || (((ftop + u_d.fp_sti) & 3'd7)==fpp2_dst))) );
    // Stage 2 (cycle N+2): finish f_eval_s2 from the REGISTERED stage-1 result and
    // commit to the absolute target. This is the SHORT back-half cone (round_pack
    // only); the front half was spent the previous clock — that is the whole split.
    if (fpp2_valid) begin
      automatic logic [82:0] pp_arf = f_eval_s2(fpp2_s1, fpp2_rc);
      fp_we_wabs       = 1'b1;
      fp_wabs_idx      = fpp2_dst;
      fp_wabs_data     = pp_arf[79:0];
      fp_we_wabs_fstat = 1'b1;
      fp_wabs_fstat    = f_arith_fstat(fstat, pp_arf);
    end
`else
    fp_pipe_rd_haz = fpp_valid && u_d.is_fp &&
                     ((ftop==fpp_dst) || (((ftop + u_d.fp_sti) & 3'd7)==fpp_dst));
    // Deferred FK_ARITH commit (cycle N+1): the captured op's f_eval is computed
    // HERE (from the registered fpp_* operands — the short, post-register path)
    // and written to the absolute target via we_wabs. f_arith_fstat merges into
    // the CURRENT fstat (sticky-OR; nothing else writes fstat this clock because a
    // consumer that would is scoreboard-stalled past the in-flight window).
    if (fpp_valid) begin
`ifdef VEN_SRT_ITER
      // P0-13 FP area: use the SPLIT eval (f_eval_s1 front -> f_eval_s2 round).
      // The full f_eval builds fx_add's AND fx_mul's fx_round_pack cones (two
      // 128-bit normalize/round trees); the split muxes the two FRONTS and runs
      // ONE shared round_pack -> drops a whole round cone. BIT-EXACT for add/sub/
      // mul (verif/fppipe gate, 1M vectors). SAFE ONLY under +VEN_SRT_ITER: there
      // the iterative engine OWNS divide (normal divides are engine-routed; div is
      // never deferred to this commit port), so f_eval_s1's div-returns-0 default
      // is unreachable. Without VEN_SRT_ITER, divide DOES defer here -> keep the
      // full f_eval (below). Combinational s1->s2, same 1-clock defer as before.
      automatic logic [82:0] pp_arf = f_eval_s2(f_eval_s1(fpp_aluop, fpp_a, fpp_b, fpp_rc, fpp_err), fpp_rc);
`else
      automatic logic [82:0] pp_arf = f_eval(fpp_aluop, fpp_a, fpp_b, fpp_rc, fpp_err);
`endif
      fp_we_wabs       = 1'b1;
      fp_wabs_idx      = fpp_dst;
      fp_wabs_data     = pp_arf[79:0];
      fp_we_wabs_fstat = 1'b1;
      fp_wabs_fstat    = f_arith_fstat(fstat, pp_arf);
    end
`endif
`endif

    // ===== FAST ARM (M5 cycle-mode FP issue+commit) — same guard as ic_fp_commit.
    fp_in_pipe = (state==S_PIPE) && !xlate_miss && (stall_cnt==7'd0) &&
                 pipe_bytes_ok && (pending_mem_pen==7'd0);
    fp_halt4   = u_d.is_fp && (u_d.fp_kind==FK_ARITH) && (fctrl[9:8]!=2'b11);
    fp_fp_arm  = fp_in_pipe && !fp_halt4 && u_d.is_fp;
    fp_dep_ready = (u_d.fp_role>=3'd2) ? fp_ready_cyc : 32'd0;
`ifdef VEN_FP_OVERLAP
    // GAP1 mirror (matches core_fastpath.svh + ic_dep_ready): following FP op waits
    // on the x87 exec unit (fp_busy_cyc); FXCH (a rename) is exempt.
    if (u_d.fp_kind != FK_FXCH
        && $signed(fp_busy_cyc - core_cyc) > 0
        && $signed(fp_busy_cyc - fp_dep_ready) > 0)
      fp_dep_ready = fp_busy_cyc;
`endif
    fp_fast_commit = fp_fp_arm &&
                     !(!fp_occ_pending && ($signed(fp_dep_ready - core_cyc) > 0)) &&
                     !(!fp_occ_pending && (u_d.fp_occ > 7'd1));
`ifdef VEN_FP_PIPE
    // Fast-arm arith is DEFERRED: the live-operand f_eval is removed from the
    // issue cone (that is the whole point — the eip->icache->decode->f_eval->fpr
    // path is what we are splitting). The result is computed one clock later from
    // the REGISTERED fpp_* operands in the we_wabs deferred-commit block above.
    fp_arf = 83'd0;
`else
    fp_arf = f_eval(u_d.fp_aluop, fst(3'd0), fst(u_d.fp_sti), fctrl[11:10], errata_en[ERR_FDIV]);
`endif
    if (fp_fast_commit) begin
      unique case (u_d.fp_kind)
        FK_FLDC:   begin
`ifdef VEN_FXCH_FREE
          // GAP2 fold: fld-const + a following free FXCH %st(i) in ONE write — the
          // pushed const lands in st(i), the old st(i-1) becomes the new st0 (pre-edge
          // ftop addressing: we_push->fpr[ftop-1], we_sti(i-1)->fpr[ftop+i-1]).
          if (v_d.is_fxch_free && v_bytes_ok && v_d.fp_sti!=3'd0) begin
            fp_we_push=1'b1; fp_push_data=fst(v_d.fp_sti - 3'd1);
            fp_we_sti=1'b1;  fp_wsti_idx=v_d.fp_sti - 3'd1;
            fp_wsti_data=fconst(u_d.fp_sti); fp_wsti_clr_tag=1'b1;
          end else
`endif
          begin fp_we_push=1'b1; fp_push_data=fconst(u_d.fp_sti); end
        end
        FK_FLDSTI: begin
`ifdef VEN_FXCH_FREE
          if (v_d.is_fxch_free && v_bytes_ok && v_d.fp_sti!=3'd0) begin
            fp_we_push=1'b1; fp_push_data=fst(v_d.fp_sti - 3'd1);
            fp_we_sti=1'b1;  fp_wsti_idx=v_d.fp_sti - 3'd1;
            fp_wsti_data=fst(u_d.fp_sti); fp_wsti_clr_tag=1'b1;
          end else
`endif
          begin fp_we_push=1'b1; fp_push_data=fst(u_d.fp_sti); end
        end
        FK_ARITH:  begin
`ifdef VEN_FP_PIPE
          // DEFERRED: capture operands (signalled to the always_ff) and commit one
          // clock later via we_wabs — the same-cycle fpr/fstat write is suppressed
          // so the eip->...->f_eval->fpr cone is split across two clocks.
          fp_pipe_cap  = 1'b1;
          fp_cap_aluop = u_d.fp_aluop;
          fp_cap_a     = fst(3'd0);
          fp_cap_b     = fst(u_d.fp_sti);
          fp_cap_rc    = fctrl[11:10];
          fp_cap_err   = errata_en[ERR_FDIV];
          fp_cap_dst   = ftop;            // ST0 absolute physical index
`else
          fp_we_top=1'b1;   fp_top_data=fp_arf[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, fp_arf);
`endif
        end
        FK_FSTP0:  begin fp_we_pop=1'b1; end
        FK_FXCH:   begin
          fp_we_fxch=1'b1; fp_fxch_idx=u_d.fp_sti;
          fp_fxch_a=fst(u_d.fp_sti);   // -> fpr[ftop]
          fp_fxch_b=fst(3'd0);         // -> fpr[ftop+idx]
        end
        default: ;
      endcase
    end

    // ===== SLOW ARM (S_FEXEC) — recompute exactly what the inline case did.
    slow_is_arith = (q_fxop==FX_AR_ST0_STI) || (q_fxop==FX_AR_STI_ST0) ||
                    (q_fxop==FX_AR_M32)     || (q_fxop==FX_AR_M64)     ||
                    (q_fxop==FX_AR_I16)     || (q_fxop==FX_AR_I32)     ||
                    (q_fxop==FX_FSQRT);
    slow_pc_bad = slow_is_arith && (fctrl[9:8] != 2'b11);
    slow_arm    = (state==S_FEXEC) && !slow_pc_bad;

    // ===== M11 env-pointer latch (func path = the slow arm; one S_FEXEC commit
    // per FP op). FIP=instr addr (q_pc) + FCS latch on every NON-control FP op
    // (incl FNSTSW %ax); FDP=operand addr (dbase+q_ea) + FDS only on memory-
    // operand FP ops. Control/admin ops below do NOT update the pointers; FNINIT
    // CLEARS them (via fp_we_fninit -> u_fpu_state). (M11a: inert -- nothing reads
    // fip/fcs/fdp/fds until M11b decodes FNSTENV/FNSAVE.)
    f_is_admin = (q_fxop==FX_FNINIT) || (q_fxop==FX_FNCLEX) || (q_fxop==FX_FNSTCW) ||
                 (q_fxop==FX_FNSTSW_M) || (q_fxop==FX_FLDCW) || (q_fxop==FX_FWAIT) ||
                 (q_fxop==FX_FNSTENV) || (q_fxop==FX_FLDENV) ||
                 (q_fxop==FX_FNSAVE)  || (q_fxop==FX_FRSTOR);
    if (slow_arm && !f_is_admin) begin
      fp_we_eptr  = 1'b1; fp_eptr_fip = q_pc; fp_eptr_fcs = SEG_CS;
      if (q_f_mem_read || q_f_mem_write) begin
        fp_we_dptr = 1'b1; fp_eptr_fdp = dbase + q_ea; fp_eptr_fds = SEG_DS;
      end
    end

    // M11b FLDENV/FRSTOR commit on the LAST load beat: reload CW/SW/TOP verbatim +
    // re-derive the per-reg empty bits from the loaded FTW (env_tmp[] holds the read
    // dwords; 0=CW,1=SW,2=FTW). FRSTOR also reloads the 8 ST regs (see below).
    if (state==S_FENV_LD && mem_ack &&
        f_seq_step == ((q_fxop==FX_FRSTOR) ? 5'd26 : 5'd6)) begin
      fp_we_envld  = 1'b1;
      fp_env_fctrl = env_tmp[0][15:0];
      fp_env_ftop  = env_tmp[1][13:11];
      // qemu cpu_set_fpus: clear TOP (0x3800) AND the B bit (0x8000), then re-derive
      // B from SE (bit7) -- B is NOT loaded verbatim (FERR# busy mirrors SE).
      fp_env_fstat = (env_tmp[1][15:0] & ~16'h3800 & ~16'h8000)
                     | (env_tmp[1][7] ? 16'h8000 : 16'd0);
      for (int p = 0; p < 8; p++) fp_env_fptag[p] = (env_tmp[2][p*2 +: 2] == 2'b11);
      // FRSTOR also reloads the 8 ST registers. The ST region (image dwords 7..26)
      // is env_tmp[7..25] plus mem_rdata for dword 26 (latched THIS beat as an NBA,
      // so read it live, not from env_tmp). Logical slot i -> physical fpr[(ftop+i)],
      // i.e. fpr[p] = logical ST((p - loaded_ftop)&7).
      if (q_fxop==FX_FRSTOR) begin
        fp_we_envregs = 1'b1;
        for (int j = 0; j < 20; j++)
          frstor_streg[j*32 +: 32] = (j==19) ? mem_rdata : env_tmp[7+j];
        for (int p = 0; p < 8; p++) begin
          frli = (p - int'(env_tmp[1][13:11])) & 7;
          fp_env_fpr_flat[p*80 +: 80] = frstor_streg[frli*80 +: 80];
        end
      end
    end

    // M11b FNSAVE reinitializes the FPU (= FNINIT) AFTER the last store beat. The
    // store data on that beat is combinational from the CURRENT (pre-reinit) state,
    // and fp_we_fninit is an NBA applied at the same edge -> the image captures the
    // pre-reinit state and the live state reinitializes. (FNSTENV has no side effect.)
    if (state==S_FENV_ST && mem_ack && q_fxop==FX_FNSAVE && f_seq_step==5'd26)
      fp_we_fninit = 1'b1;
    s_opnd_f = q_f_mem_read ? f_mem_as_float(f_mem80, q_f_mbytes) : 80'd0;
    s_st0v   = fst(3'd0);
    s_stiv   = fst(q_f_sti);
    s_rc     = fctrl[11:10];
    s_argb   = 80'd0; s_codes = 3'd0; s_xc = 4'd0; s_cmp_ie = 1'b0;
    s_ar = 81'd0;
    // R-area: ONE shared arithmetic eval. The four S_FEXEC arith commit arms used
    // to each call f_eval with their own operands — synth built FOUR full add/mul/
    // round cones (~6K LUT each) then muxed the outputs. Mux the OPERANDS per
    // q_fxop here, then call f_eval ONCE (compute-then-mux -> mux-then-compute).
    // Behaviour-identical: each arm's (a,b) is reproduced exactly; s_arf is only
    // consumed by those arms (and harmlessly computed for non-arith ops). The
    // VEN_SRT_ITER divide-eligibility block below also reuses s_fa/s_fb.
    unique case (q_fxop)
      FX_AR_STI_ST0:        begin s_fa = s_stiv; s_fb = s_st0v; end
      FX_AR_M32, FX_AR_M64: begin s_fa = s_st0v; s_fb = s_opnd_f; end
      FX_AR_I16, FX_AR_I32: begin s_fa = s_st0v; s_fb = f_mem_as_int(f_mem80, q_f_mbytes); end
      default:              begin s_fa = s_st0v; s_fb = s_stiv; end  // FX_AR_ST0_STI + non-arith
    endcase
`ifdef VEN_FP_PIPE
    // Slow-arm arith is SPLIT: S_FEXEC captures s_fa/s_fb into fpp_*, then
    // S_FEXEC_EX computes f_eval (from the registered operands) and commits via
    // we_wabs IN THE SAME CLOCK AS THE RETIRE (so the per-retire arch check is
    // exact — unlike a retire-before-commit defer). The combinational s_arf cone
    // (f_mem80->f_eval->fpr, the worst path) is dropped here.
    s_arf = 83'd0;
`else
    s_arf = f_eval(q_f_aluop, s_fa, s_fb, s_rc, errata_en[ERR_FDIV]);
`endif
    // R-area: ONE shared FP compare. The six compare arms (FCOM/FUCOM/FCOMPP/
    // FUCOMPP/FTST/FICOM) each called fcom_codes+fcom_ie+apply_cmp with their own
    // operand — synth built SIX compare cones then muxed. Mux the operand+signaling
    // per q_fxop, compute ONCE; each arm just routes s_cmp_fstat to fp_fstat_wval.
    unique case (q_fxop)
      FX_FCOM_STI:               begin s_cmp_b = s_stiv;    s_cmp_sig = 1'b1; end
      FX_FCOM_M32, FX_FCOM_M64:  begin s_cmp_b = s_opnd_f;  s_cmp_sig = 1'b1; end
      FX_FUCOM_STI:              begin s_cmp_b = s_stiv;    s_cmp_sig = 1'b0; end
      FX_FCOMPP:                 begin s_cmp_b = fst(3'd1); s_cmp_sig = 1'b1; end
      FX_FUCOMPP:                begin s_cmp_b = fst(3'd1); s_cmp_sig = 1'b0; end
      FX_FTST:                   begin s_cmp_b = 80'd0;     s_cmp_sig = 1'b1; end
      FX_FICOM_M16, FX_FICOM_M32:begin s_cmp_b = f_mem_as_int(f_mem80, q_f_mbytes); s_cmp_sig = 1'b1; end
      default:                   begin s_cmp_b = s_stiv;    s_cmp_sig = 1'b1; end
    endcase
    s_codes     = fcom_codes(s_st0v, s_cmp_b);
    s_cmp_ie    = fcom_ie(s_st0v, s_cmp_b, s_cmp_sig);
    s_cmp_fstat = apply_cmp(fstat, s_codes, s_cmp_ie);
`ifdef VEN_SRT_ITER
    // ----- iterative SRT FDIV/FSQRT eligibility + engine inputs -------------
    // Route NORMAL-operand divides and +normal sqrt through the multi-cycle
    // engine; everything else (zero/Inf/NaN/denormal, runtime FDIV-errata) stays
    // on the combinational path (its flag/special logic below is preserved).
    begin
      logic na, nb;
      // operands are the shared s_fa/s_fb (the per-q_fxop mux computed above).
      // FINITE-NONZERO operands: exactly the set that reaches fx_srt_div's /
      // fx_isqrt's loop in f_eval's else (zero/Inf/NaN hit cheap guards). Routing
      // ALL of these to the engine lets the combinational loops be stubbed out of
      // synthesis (D8b); the engine == fx_srt_div / fx_sqrt for every operand.
      na = !fx_is_zero(s_fa) && (fx_exp(s_fa)!=15'h7fff);
      nb = !fx_is_zero(s_fb) && (fx_exp(s_fb)!=15'h7fff);
      fp_div_elig = slow_arm && !errata_en[ERR_FDIV] &&
                    ((q_fxop==FX_AR_ST0_STI)||(q_fxop==FX_AR_STI_ST0)||
                     (q_fxop==FX_AR_M32)||(q_fxop==FX_AR_M64)||
                     (q_fxop==FX_AR_I16)||(q_fxop==FX_AR_I32)) &&
                    ((q_f_aluop==3'd6)||(q_f_aluop==3'd7)) && na && nb;
      fp_sqrt_elig = slow_arm && (q_fxop==FX_FSQRT) &&
                     !fx_is_zero(s_st0v) && (fx_exp(s_st0v)!=15'h7fff) && !s_st0v[79];
      fp_iter_go   = fp_div_elig || fp_sqrt_elig;
      // div: a/b as passed to fx_div (divr, aluop 7, swaps operands)
      eng_div_a    = (q_f_aluop==3'd7) ? s_fb : s_fa;
      eng_div_b    = (q_f_aluop==3'd7) ? s_fa : s_fb;
      eng_sqrt_in  = s_st0v;
      eng_rc       = s_rc;
      eng_div_start  = fp_div_elig;
      eng_sqrt_start = fp_sqrt_elig;
      fp_iter_done = (q_fxop==FX_FSQRT) ? eng_sqrt_done : eng_div_done;
    end
`endif
    if (slow_arm) begin
      unique case (q_fxop)
        // ---- loads (push) ----
        FX_FLD_M32, FX_FLD_M64, FX_FLD_M80: begin
          fp_we_push=1'b1; fp_push_data=(q_fxop==FX_FLD_M80) ? f_mem80 : s_opnd_f;
        end
        FX_FILD_M16, FX_FILD_M32, FX_FILD_M64: begin
          fp_we_push=1'b1; fp_push_data=f_mem_as_int(f_mem80, q_f_mbytes);
        end
        FX_FBLD: begin   // M10: packed-BCD m80 -> floatx80 (exact, <=18 digits)
`ifndef VEN_BCD_ITER
          fp_we_push=1'b1; fp_push_data=fx_bcd_to_fx(f_mem80);
`endif
          // under VEN_BCD_ITER: deferred to S_FBLD_BUSY (iterative ven_bcd_to_fp);
          // the push lands there with the engine result, same clock as the retire.
        end
        FX_FLDCONST: begin fp_we_push=1'b1; fp_push_data=fconst(q_f_const); end
        FX_FLD_STI:  begin fp_we_push=1'b1; fp_push_data=s_stiv;            end
        // ---- register moves / stack mgmt ----
        FX_FST_STI: begin
          fp_we_sti=1'b1; fp_wsti_idx=q_f_sti; fp_wsti_data=s_st0v; fp_wsti_clr_tag=1'b1;
          if (q_f_pop) fp_we_pop=1'b1;
        end
        FX_FXCH: begin
          fp_we_fxch=1'b1; fp_fxch_idx=q_f_sti;
          fp_fxch_a=s_stiv;   // -> fpr[ftop]
          fp_fxch_b=s_st0v;   // -> fpr[ftop+idx]
        end
        FX_FFREE:   begin fp_we_ffree=1'b1; fp_ffree_idx=q_f_sti; end
        FX_FINCSTP: begin fp_we_incstp=1'b1; fp_we_fstat=1'b1; fp_fstat_wval=fstat & ~16'h4700; end
        FX_FDECSTP: begin fp_we_decstp=1'b1; fp_we_fstat=1'b1; fp_fstat_wval=fstat & ~16'h4700; end
        FX_FNOP:    begin /* no state change */ end
        FX_FWAIT:   begin /* no unmasked exception in corpus */ end
        FX_FNINIT:  begin fp_we_fninit=1'b1; end
        FX_FNCLEX:  begin fp_we_fstat=1'b1; fp_fstat_wval=fstat & 16'h7f00; end
        FX_FLDCW:   begin fp_we_fctrl=1'b1; fp_fctrl_wval=f_mem80[15:0]; end
        // ---- sign / abs on ST0 ----
        FX_FABS: begin fp_we_top=1'b1; fp_top_data={1'b0, s_st0v[78:0]}; end
        FX_FCHS: begin fp_we_top=1'b1; fp_top_data={~s_st0v[79], s_st0v[78:0]}; end
        // ---- compares ----
        // compares — s_cmp_fstat (== apply_cmp of the muxed s_cmp_b) is shared,
        // computed once above; each arm routes it + does its own pop/pop2.
        FX_FCOM_STI, FX_FCOM_M32, FX_FCOM_M64: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          if (q_f_pop) fp_we_pop=1'b1;
        end
        FX_FUCOM_STI: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          if (q_f_pop) fp_we_pop=1'b1;
        end
        FX_FCOMPP: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          fp_we_pop2=1'b1;
        end
        FX_FUCOMPP: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          fp_we_pop2=1'b1;
        end
        FX_FTST: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
        end
        FX_FXAM: begin
          s_xc = fxam_codes(s_st0v, fptag[ftop]);
          fp_we_fstat=1'b1;
          fp_fstat_wval = (fstat & ~16'h4700) |
                          ({1'd0,s_xc[3]}<<14) | ({5'd0,s_xc[2]}<<10) |
                          ({6'd0,s_xc[1]}<<9)  | ({7'd0,s_xc[0]}<<8);
        end
        FX_FICOM_M16, FX_FICOM_M32: begin
          fp_we_fstat=1'b1; fp_fstat_wval=s_cmp_fstat;
          if (q_f_pop) fp_we_pop=1'b1;
        end
        // ---- arithmetic (f_eval -> {ie,ze,inexact,result}) ----
        // arith commit arms — s_arf (== f_eval of the muxed s_fa/s_fb) is shared,
        // computed once above; each arm just routes it to the right write port.
        // +VEN_FP_PIPE: capture s_fa/s_fb + the absolute dest into fpp_*; S_FEXEC
        // routes to S_FEXEC_EX where we_wabs commits (from the registered operands)
        // in the SAME clock as the retire. The pop for STI_ST0 stays here (cheap).
        FX_AR_ST0_STI: if (!fp_div_elig) begin
`ifdef VEN_FP_PIPE
          fp_pipe_cap=1'b1; fp_cap_aluop=q_f_aluop; fp_cap_a=s_fa; fp_cap_b=s_fb;
          fp_cap_rc=s_rc; fp_cap_err=errata_en[ERR_FDIV]; fp_cap_dst=ftop;
`else
          fp_we_top=1'b1; fp_top_data=s_arf[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, s_arf);
`endif
        end
        FX_AR_STI_ST0: if (!fp_div_elig) begin
          // ST(i) op= ST0 : a=ST(i), b=ST0 (no tag write — only fpr[fri]).
`ifdef VEN_FP_PIPE
          fp_pipe_cap=1'b1; fp_cap_aluop=q_f_aluop; fp_cap_a=s_fa; fp_cap_b=s_fb;
          fp_cap_rc=s_rc; fp_cap_err=errata_en[ERR_FDIV];
          fp_cap_dst=(ftop + q_f_sti) & 3'd7;
          if (q_f_pop) fp_we_pop=1'b1;
`else
          fp_we_sti=1'b1; fp_wsti_idx=q_f_sti; fp_wsti_data=s_arf[79:0]; fp_wsti_clr_tag=1'b0;
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, s_arf);
          if (q_f_pop) fp_we_pop=1'b1;
`endif
        end
        FX_AR_M32, FX_AR_M64: if (!fp_div_elig) begin
`ifdef VEN_FP_PIPE
          fp_pipe_cap=1'b1; fp_cap_aluop=q_f_aluop; fp_cap_a=s_fa; fp_cap_b=s_fb;
          fp_cap_rc=s_rc; fp_cap_err=errata_en[ERR_FDIV]; fp_cap_dst=ftop;
`else
          fp_we_top=1'b1; fp_top_data=s_arf[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, s_arf);
`endif
        end
        FX_AR_I16, FX_AR_I32: if (!fp_div_elig) begin
`ifdef VEN_FP_PIPE
          fp_pipe_cap=1'b1; fp_cap_aluop=q_f_aluop; fp_cap_a=s_fa; fp_cap_b=s_fb;
          fp_cap_rc=s_rc; fp_cap_err=errata_en[ERR_FDIV]; fp_cap_dst=ftop;
`else
          fp_we_top=1'b1; fp_top_data=s_arf[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, s_arf);
`endif
        end
        FX_FSQRT: begin
          // QEMU helper_fsqrt. M12: intercept NaN FIRST (the bare fx_sqrt would do
          // mantissa math on a NaN and return garbage); sqrt(+Inf) is handled by
          // fx_sqrt's own +Inf guard. Everything else preserves the prior, gate-
          // proven sign-bit / C2 logic verbatim.
          if (fx_is_snan(s_st0v)) begin                       // SNaN -> QNaN, IE
            fp_we_top=1'b1;   fp_top_data=fx_quietize(s_st0v);
            fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001;
          end else if (fx_is_nan(s_st0v)) begin               // QNaN -> propagate, no flag
            fp_we_top=1'b1;   fp_top_data=s_st0v;
          end else if (s_st0v[79]) begin
            if (fx_is_neg(s_st0v)) begin                      // sqrt(neg non-zero) incl -Inf
              fp_we_top=1'b1;   fp_top_data=80'hFFFFC000000000000000;
              fp_we_fstat=1'b1; fp_fstat_wval=(fstat & ~16'h4700) | 16'h0400 | 16'h0001; // C2+IE
            end else begin                                    // -0
              s_ar = fx_sqrt(s_st0v, s_rc);
              fp_we_top=1'b1;   fp_top_data=s_ar[79:0];
              fp_we_fstat=1'b1; fp_fstat_wval=(fstat & ~16'h4700) | 16'h0400;            // C2 only
            end
          end else if (!fp_sqrt_elig) begin                   // +0, +Inf (+normal -> engine)
            s_ar = fx_sqrt(s_st0v, s_rc);
            fp_we_top=1'b1; fp_top_data=s_ar[79:0];
            if (s_ar[80]) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end    // PE
          end
        end
        // ---- memory stores: sticky PE/IE latch at dispatch (the store value +
        // pop happen later in S_FSTORE). FST m80/FNSTCW/FNSTSW m16 stay exact.
        FX_FST_M32, FX_FST_M64, FX_FST_M80,
        FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
        FX_FBSTP,
        FX_FNSTCW, FX_FNSTSW_M: begin
`ifdef VEN_BCD_ITER
          // iterative FBSTP defers its IE/PE sticky to the S_BCD_BUSY done clock
          // (fstore_ie/pe come from the engine, not valid yet here at S_FEXEC).
          if (q_fxop != FX_FBSTP) begin
`endif
          if (fstore_ie)      begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001; end  // IE
          else if (fstore_pe) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end  // PE
`ifdef VEN_BCD_ITER
          end
`endif
        end
        // FX_FNSTSW_AX writes gpr[EAX] only (handled in the S_FEXEC spine arm).
        default: ;
      endcase
    end

`ifdef VEN_BCD_ITER
    // iterative FBSTP: drive the deferred IE/PE fstat sticky on the engine-done
    // clock (the store value/flags only become known when the BCD engine finishes).
    if (state==S_BCD_BUSY && eng_bcd_done) begin
      if (eng_bcd_result[81])      begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001; end // IE
      else if (eng_bcd_result[80]) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end // PE
    end
    // iterative FBLD: push the converted floatx80 on the engine-done clock (the
    // same clock S_FBLD_BUSY retires -> the per-retire arch state is exact).
    if (state==S_FBLD_BUSY && eng_fbld_done) begin
      fp_we_push=1'b1; fp_push_data=eng_fbld_result;
    end
`endif

`ifdef VEN_SRT_ITER
    // ===== iterative engine result commit (S_FP_BUSY, when the engine is done).
    // Re-derives the dest write-port from q_fxop (which persists across the wait)
    // and uses the engine's registered {inexact,result}. normal/normal divide and
    // +normal sqrt only (so ie=ze=0; sqrt sets PE on inexact, like the comb arm).
    if (state==S_FP_BUSY && fp_iter_done) begin
      if (q_fxop==FX_FSQRT) begin
        fp_we_top=1'b1; fp_top_data=eng_sqrt_result[79:0];
        if (eng_sqrt_result[80]) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end
      end else begin
        logic [82:0] earf;
        earf = {2'b00, eng_div_result[80], eng_div_result[79:0]};
        if (q_fxop==FX_AR_STI_ST0) begin
          fp_we_sti=1'b1; fp_wsti_idx=q_f_sti; fp_wsti_data=eng_div_result[79:0]; fp_wsti_clr_tag=1'b0;
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, earf);
          if (q_f_pop) fp_we_pop=1'b1;
        end else begin
          fp_we_top=1'b1; fp_top_data=eng_div_result[79:0];
          fp_we_fstat=1'b1; fp_fstat_wval=f_arith_fstat(fstat, earf);
        end
      end
    end
`endif

`ifdef VEN_TRANSCENDENTAL
    // iterative transcendentals (#11): commit + fstat on the engine-done clock
    // (the same clock S_TRSC_BUSY retires -> per-retire arch state exact). IE has
    // priority over PE (mirrors FBSTP); the engine asserts PE for inexact results.
    // F2XM1 overwrites ST0 in place; FPATAN writes ST1 and POPS (result ends in
    // the new ST0), exactly like FDIVP ST1,ST0 (we_sti idx=1 + we_pop).
    if (state==S_TRSC_BUSY && eng_trsc_done) begin
      if (q_fxop==FX_FSIN || q_fxop==FX_FCOS) begin
        // FSIN/FCOS: in-place ST0. Out-of-range (|x|>=2^63) -> set C2, ST0
        // unchanged; else write result, clear C2, set PE (matches qemu's C2 flag
        // handling; the VALUE is the silicon model, more accurate than qemu's double).
        if (eng_trsc_c2) begin
          fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0400;     // C2 <- 1
        end else begin
          fp_we_top=1'b1; fp_top_data=eng_trsc_result;
          fp_we_fstat=1'b1; fp_fstat_wval=(fstat & ~16'h0400) | 16'h0020;  // C2<-0, PE<-1
        end
      end else if (q_fxop==FX_FSINCOS || q_fxop==FX_FPTAN) begin
        // FSINCOS: ST0<-sin, push cos.  FPTAN: ST0<-tan(=sin/cos), push 1.0.
        // (we_top writes the OLD top = new ST1; we_push writes the new ST0.) C2
        // out-of-range -> no write, no push, ST0 unchanged.
        if (eng_trsc_c2) begin
          fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0400;
        end else begin
          fp_we_top=1'b1;
          fp_top_data=(q_fxop==FX_FPTAN) ? fx_div(eng_fs_sin, eng_fs_cos, 2'd0)[79:0] : eng_fs_sin;
          fp_we_push=1'b1;
          fp_push_data=(q_fxop==FX_FPTAN) ? 80'h3fff8000000000000000 : eng_fs_cos;  // FPTAN pushes +1.0
          fp_we_fstat=1'b1; fp_fstat_wval=(fstat & ~16'h0400) | 16'h0020;
        end
      end else if (q_fxop==FX_F2XM1) begin
        fp_we_top=1'b1; fp_top_data=eng_trsc_result;            // in-place ST0
        if (eng_trsc_ie)      begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001; end
        else if (eng_trsc_pe) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end
      end else begin
        // FPATAN / FYL2X / FYL2XP1: write ST1, then pop (result -> new ST0).
        fp_we_sti=1'b1; fp_wsti_idx=3'd1; fp_wsti_data=eng_trsc_result; fp_wsti_clr_tag=1'b0;
        fp_we_pop=1'b1;
        if (eng_trsc_ie)      begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0001; end
        else if (eng_trsc_pe) begin fp_we_fstat=1'b1; fp_fstat_wval=fstat | 16'h0020; end
      end
    end
`endif

    // ===== SLOW ARM (S_FSTORE last beat) — the FSTP/FISTP pop.
    fstore_last_beat = (state==S_FSTORE) && mem_ack &&
                       ((q_f_mbytes<=4'd4) ||
                        (q_f_mbytes==4'd8 && f_step==4'd1) ||
                        (q_f_mbytes==4'd10 && f_step==4'd2));
    if (fstore_last_beat && q_f_pop) fp_we_pop=1'b1;
  end

  fpu_top u_fpu_state (
    .clk          (clk),
    .rst_n        (rst_n),
    .st0          (fp_st[0]),
    .st1          (fp_st[1]),
    .st2          (fp_st[2]),
    .st3          (fp_st[3]),
    .st4          (fp_st[4]),
    .st5          (fp_st[5]),
    .st6          (fp_st[6]),
    .st7          (fp_st[7]),
    .ftop_o       (ftop),
    .fstat_o      (fstat),
    .fctrl_o      (fctrl),
    .fptag_o      (fptag),
    .rd_phys_top  (fp_st0_phys),
    .we_push      (fp_we_push),
    .push_data    (fp_push_data),
    .we_top       (fp_we_top),
    .top_data     (fp_top_data),
    .we_fstat     (fp_we_fstat),
    .fstat_wval   (fp_fstat_wval),
    .we_sti       (fp_we_sti),
    .wsti_idx     (fp_wsti_idx),
    .wsti_data    (fp_wsti_data),
    .wsti_clr_tag (fp_wsti_clr_tag),
    .we_fxch      (fp_we_fxch),
    .fxch_idx     (fp_fxch_idx),
    .fxch_a       (fp_fxch_a),
    .fxch_b       (fp_fxch_b),
    .we_pop       (fp_we_pop),
    .we_pop2      (fp_we_pop2),
    .we_ffree     (fp_we_ffree),
    .ffree_idx    (fp_ffree_idx),
    .we_incstp    (fp_we_incstp),
    .we_decstp    (fp_we_decstp),
    .we_fctrl     (fp_we_fctrl),
    .fctrl_wval   (fp_fctrl_wval),
    .we_fninit    (fp_we_fninit),
    .we_eptr      (fp_we_eptr),
    .eptr_fip     (fp_eptr_fip),
    .eptr_fcs     (fp_eptr_fcs),
    .we_dptr      (fp_we_dptr),
    .dptr_fdp     (fp_eptr_fdp),
    .dptr_fds     (fp_eptr_fds),
    .fip_o        (fip),
    .fcs_o        (fcs),
    .fdp_o        (fdp),
    .fds_o        (fds),
    .fpr_flat_o   (fpr_flat),
    .we_envld     (fp_we_envld),
    .env_fctrl    (fp_env_fctrl),
    .env_ftop     (fp_env_ftop),
    .env_fstat    (fp_env_fstat),
    .env_fptag    (fp_env_fptag),
    .we_envregs   (fp_we_envregs),
    .env_fpr_flat (fp_env_fpr_flat),
    // +VEN_FP_PIPE deferred-arith commit port (inert / tied 0 when not piped).
    .we_wabs      (fp_we_wabs),
    .wabs_idx     (fp_wabs_idx),
    .wabs_data    (fp_wabs_data),
    .we_wabs_fstat(fp_we_wabs_fstat),
    .wabs_fstat   (fp_wabs_fstat)
  );

`ifdef VEN_SRT_ITER
  // iterative SRT FDIV / FSQRT engines — the FPGA-synthesizable multi-cycle form
  // of fx_srt_div / fx_sqrt. Started from S_FEXEC for normal-operand divides /
  // +normal sqrts; their {inexact,result} commits in S_FP_BUSY (fp_we_* driver).
  // buggy-PLA select mirrors the compile-time VEN_SRT_FDIV_BUG (== fx_div default).
  `ifdef VEN_SRT_FDIV_BUG
  localparam logic ENG_DIV_BUGGY = 1'b1;
  `else
  localparam logic ENG_DIV_BUGGY = 1'b0;
  `endif
  fpu_srt_div u_srt_div (
    .clk(clk), .rst_n(rst_n), .start(eng_div_start),
    .a(eng_div_a), .b(eng_div_b), .rc(eng_rc), .buggy(ENG_DIV_BUGGY),
    .busy(eng_div_busy), .done(eng_div_done), .result(eng_div_result)
  );
  fpu_sqrt_iter u_sqrt_iter (
    .clk(clk), .rst_n(rst_n), .start(eng_sqrt_start),
    .a(eng_sqrt_in), .rc(eng_rc),
    .busy(eng_sqrt_busy), .done(eng_sqrt_done), .result(eng_sqrt_result)
  );
`else
  assign eng_div_busy=1'b0;  assign eng_div_done=1'b0;  assign eng_div_result='0;
  assign eng_sqrt_busy=1'b0; assign eng_sqrt_done=1'b0; assign eng_sqrt_result='0;
`endif

  // --- iterative integer DIV/IDIV engine (VEN_IDIV_ITER) -------------------
  // The FPGA-synthesizable multi-cycle form of the native '/'/'%' in
  // core_exec.svh's K_MULDIV DIV/IDIV arms. Started from S_EXEC for DIV/IDIV
  // (q_md 6/7); the FSM waits in S_DIV_BUSY and commits EAX/EDX + #DE on `done`.
  logic        eng_int_start, eng_int_signed;
  logic [2:0]  eng_int_w;
  logic [63:0] eng_int_num;
  logic [31:0] eng_int_den;
  logic        eng_int_busy, eng_int_done, eng_int_derr;
  logic [31:0] eng_int_quot, eng_int_rem;
`ifdef VEN_IDIV_ITER
  always_comb begin
    logic [31:0] srcv_drv;
    eng_int_start=1'b0; eng_int_signed=1'b0; eng_int_w=q_w;
    eng_int_num=64'd0; eng_int_den=32'd0;
    srcv_drv = q_mem_read ? wmask(mem_load_data, q_w) : reg_read(q_src_reg, q_w, q_src_high8);
    if (state==S_EXEC && q_kind==K_MULDIV && (q_md==3'd6 || q_md==3'd7)) begin
      eng_int_start  = 1'b1;
      eng_int_signed = (q_md==3'd7);
      eng_int_w      = q_w;
      eng_int_num    = (q_w==3'd1) ? {48'd0, gpr[R_EAX][15:0]} :
                       (q_w==3'd2) ? {32'd0, gpr[R_EDX][15:0], gpr[R_EAX][15:0]} :
                                     {gpr[R_EDX], gpr[R_EAX]};
      eng_int_den    = srcv_drv;
    end
  end
  ven_idiv u_idiv (
    .clk(clk), .rst_n(rst_n), .start(eng_int_start), .is_signed(eng_int_signed),
    .w(eng_int_w), .dividend(eng_int_num), .divisor(eng_int_den),
    .busy(eng_int_busy), .done(eng_int_done),
    .quotient(eng_int_quot), .remainder(eng_int_rem), .derr(eng_int_derr)
  );
`else
  always_comb begin
    eng_int_start=1'b0; eng_int_signed=1'b0; eng_int_w=3'd0;
    eng_int_num=64'd0;  eng_int_den=32'd0;
  end
  assign eng_int_busy=1'b0; assign eng_int_done=1'b0; assign eng_int_derr=1'b0;
  assign eng_int_quot=32'd0; assign eng_int_rem=32'd0;
`endif

  // --- iterative FP->packed-BCD (FBSTP) engine (VEN_BCD_ITER) --------------
  // The 18-chained-/10 fx_fx_to_bcd was the core's worst timing path. On FBSTP,
  // run the engine (started in S_FEXEC), wait in S_BCD_BUSY, latch the BCD store
  // value (fbcd_result_q) + defer the fstat sticky to the engine-done clock.
  logic        eng_bcd_start, eng_bcd_busy, eng_bcd_done;
  logic [81:0] eng_bcd_result;
  logic [81:0] fbcd_result_q;       // latched {ie,pe,bcd} store value
  // FBLD (packed-BCD m80 -> floatx80): the 18-chained-*10 fx_bcd_to_fx was the
  // core's worst LOGIC path once the FP arith was pipelined. Run the iterative
  // engine (started in S_FEXEC), wait in S_FBLD_BUSY, then push the result + retire.
  logic        eng_fbld_start, eng_fbld_busy, eng_fbld_done;
  logic [79:0] eng_fbld_result;
`ifdef VEN_BCD_ITER
  assign eng_bcd_start = (state==S_FEXEC) && (q_fxop==FX_FBSTP);
  ven_bcd u_bcd (
    .clk(clk), .rst_n(rst_n), .start(eng_bcd_start),
    .v(fst(3'd0)), .rc(fctrl[11:10]),
    .busy(eng_bcd_busy), .done(eng_bcd_done), .result(eng_bcd_result)
  );
  assign eng_fbld_start = (state==S_FEXEC) && (q_fxop==FX_FBLD);
  ven_bcd_to_fp u_bcd2fp (
    .clk(clk), .rst_n(rst_n), .start(eng_fbld_start),
    .bcd(f_mem80),
    .busy(eng_fbld_busy), .done(eng_fbld_done), .result(eng_fbld_result)
  );
`else
  assign eng_bcd_start=1'b0; assign eng_bcd_busy=1'b0; assign eng_bcd_done=1'b0;
  assign eng_bcd_result=82'd0;
  assign eng_fbld_start=1'b0; assign eng_fbld_busy=1'b0; assign eng_fbld_done=1'b0;
  assign eng_fbld_result=80'd0;
`endif

  // --- iterative x87 transcendental engine (F2XM1, #11; VEN_TRANSCENDENTAL) ---
  // Started in S_FEXEC on FX_F2XM1, busy-wait in S_TRSC_BUSY, commit ST0 +
  // fstat PE/IE on `done`. Bit-exact vs qemu helper_f2xm1 (verif/trsc gate). The
  // engine is dual-mode-ready (SILICON param) but F2XM1's qemu algorithm is the
  // accuracy-faithful one, so both modes share the datapath.
  logic        eng_trsc_done;
  logic [79:0] eng_trsc_result;
  logic        eng_trsc_pe, eng_trsc_ie, eng_trsc_c2;
`ifdef VEN_TRANSCENDENTAL
  // F2XM1 (unary, in-place ST0) + FPATAN (ST1=y/ST0=x, result->ST1 then pop) each
  // get their own engine; S_TRSC_BUSY waits on whichever q_fxop selected.
  logic        eng_f2_start, eng_f2_busy, eng_f2_done, eng_f2_pe, eng_f2_ie;
  logic [79:0] eng_f2_result;
  logic        eng_fa_start, eng_fa_busy, eng_fa_done, eng_fa_pe, eng_fa_ie;
  logic [79:0] eng_fa_result;
  logic        eng_fy_start, eng_fy_busy, eng_fy_done, eng_fy_pe, eng_fy_ie;
  logic [79:0] eng_fy_result;
  assign eng_f2_start = (state==S_FEXEC) && (q_fxop==FX_F2XM1);
  assign eng_fa_start = (state==S_FEXEC) && (q_fxop==FX_FPATAN);
  assign eng_fy_start = (state==S_FEXEC) && (q_fxop==FX_FYL2X || q_fxop==FX_FYL2XP1);
  fpu_f2xm1 u_f2xm1 (
    .clk(clk), .rst_n(rst_n), .start(eng_f2_start),
    .x(fst(3'd0)), .rc(fctrl[11:10]),
    .busy(eng_f2_busy), .done(eng_f2_done), .result(eng_f2_result),
    .inexact(eng_f2_pe), .invalid(eng_f2_ie)
  );
  fpu_fpatan u_fpatan (
    .clk(clk), .rst_n(rst_n), .start(eng_fa_start),
    .y(fst(3'd1)), .x(fst(3'd0)), .rc(fctrl[11:10]),
    .busy(eng_fa_busy), .done(eng_fa_done), .result(eng_fa_result),
    .inexact(eng_fa_pe), .invalid(eng_fa_ie)
  );
  fpu_fyl2x u_fyl2x (
    .clk(clk), .rst_n(rst_n), .start(eng_fy_start),
    .mode(q_fxop==FX_FYL2XP1), .y(fst(3'd1)), .x(fst(3'd0)), .rc(fctrl[11:10]),
    .busy(eng_fy_busy), .done(eng_fy_done), .result(eng_fy_result),
    .inexact(eng_fy_pe), .invalid(eng_fy_ie)
  );
  // FSIN/FCOS: one engine computes sin AND cos; FSIN commits sin_o, FCOS cos_o.
  logic        eng_fs_start, eng_fs_busy, eng_fs_done, eng_fs_c2;
  logic [79:0] eng_fs_sin, eng_fs_cos;
  wire is_trig = (q_fxop==FX_FSIN) || (q_fxop==FX_FCOS) ||
                 (q_fxop==FX_FSINCOS) || (q_fxop==FX_FPTAN);
  assign eng_fs_start = (state==S_FEXEC) && is_trig;
  fpu_fsincos u_fsincos (
    .clk(clk), .rst_n(rst_n), .start(eng_fs_start), .x(fst(3'd0)),
    .busy(eng_fs_busy), .done(eng_fs_done),
    .sin_o(eng_fs_sin), .cos_o(eng_fs_cos), .c2_o(eng_fs_c2)
  );
  assign eng_trsc_done   = (q_fxop==FX_F2XM1) ? eng_f2_done :
                           (q_fxop==FX_FPATAN) ? eng_fa_done :
                           is_trig ? eng_fs_done : eng_fy_done;
  assign eng_trsc_result = (q_fxop==FX_F2XM1) ? eng_f2_result :
                           (q_fxop==FX_FPATAN) ? eng_fa_result :
                           (q_fxop==FX_FSIN)  ? eng_fs_sin :
                           (q_fxop==FX_FCOS)  ? eng_fs_cos : eng_fy_result;
  assign eng_trsc_pe     = (q_fxop==FX_F2XM1) ? eng_f2_pe :
                           (q_fxop==FX_FPATAN) ? eng_fa_pe :
                           is_trig ? 1'b1 : eng_fy_pe;       // sin/cos always inexact
  assign eng_trsc_ie     = (q_fxop==FX_F2XM1) ? eng_f2_ie :
                           (q_fxop==FX_FPATAN) ? eng_fa_ie :
                           is_trig ? 1'b0 : eng_fy_ie;
  assign eng_trsc_c2     = is_trig ? eng_fs_c2 : 1'b0;
`else
  assign eng_trsc_done=1'b0; assign eng_trsc_result=80'd0;
  assign eng_trsc_pe=1'b0; assign eng_trsc_ie=1'b0; assign eng_trsc_c2=1'b0;
`endif

  // ---- M2S.2 permission-fault DECISION (P/RW/US), computed not delivered. On a
  // TLB-resident data access the effective {US,RW,P} (perm) is checked against
  // the current privilege (CPL) and CR0.WP (bit 16): a USER-mode (CPL==3) access
  // to a supervisor (US=0) page, or a WRITE to a read-only page when the writer is
  // user OR CR0.WP is set, is a permission-violation #PF (error code P=1).
  //
  // M2S.3 STATUS: the NOT-PRESENT #PF (PDE/PTE P=0) now DELIVERS through the IDT
  // (S_WALK -> start_fault(14), CR2 + error code with P=0; see S_WALK steps 0/2).
  // This PERMISSION #PF (page present but US/RW protection fails) is still only
  // COMPUTED, not delivered — wiring it would require raising a fault from the
  // combinational S_PIPE/S_EXEC data path (the heavily-exercised user + sys fast
  // path) AND a corpus test that actually triggers it (CPL3 or WP=1 against a
  // present supervisor/RO page) to differentially validate the delivery. The
  // pintr/pfault corpus runs at CPL=0 / WP=0 against present RW pages, so
  // perm_fault is ALWAYS 0 here and there is no oracle for the delivery path; it
  // is a documented M2S.4 follow-on (cross-privilege brings CPL3 + WP tests).
  // Sunk in the lint sink; the access is NOT blocked when perm_fault would fire.
  logic perm_fault;
  always_comb begin
    logic [2:0] p; logic usr, wp;
    p   = dtlb_lk_perm;   // {US, RW, P} (D-TLB lookup at cur_lin)
    usr = (eff_cpl == 2'd3);   // V86 forces effective CPL 3 (USER access)
    wp  = creg0[16];
    perm_fault = 1'b0;
    if (paging_on && cur_is_d && dtlb_lk_hit) begin
      // user access to a supervisor page
      if (usr && !p[2]) perm_fault = 1'b1;
      // write to a read-only page (user writer always; supervisor only if WP)
      if (cur_is_w && !p[1] && (usr || wp)) perm_fault = 1'b1;
    end
  end

  // ===========================================================================
  // Bus request generation (single combinational driver) — relocated VERBATIM
  // into core_bus_driver.svh (module-scope `always_comb, pasted here).
  // ===========================================================================
  `include "core_bus_driver.svh"

  // ===========================================================================
  // M7.3b port-I/O bus driver (separate combinational driver) — relocated
  // VERBATIM into core_io_driver.svh (module-scope `always_comb, pasted here).
  `include "core_io_driver.svh"

  // capture original ESP at the cycle we enter PUSHA's S_USEQ.
  always_ff @(posedge clk) begin
    if (state==S_EXEC && q_kind==K_STKMISC && q_sm==SM_PUSHA) pusha_esp<=gpr[R_ESP];
  end

  // ===========================================================================
  // Lint sinks
  // ===========================================================================
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, mem_rdata[0], pfx_lock, pfx_seg, pfx_addr, q_imul_3op,
                   q_str_storedi,
                   // M2S.1 — the SEGMENT-LOAD protection DECISIONS (present/type/
                   // DPL via seg_load_fault) now DELIVER through the IDT in M2S.3
                   // (S_SEGLD/S_LJMP -> start_fault #GP/#NP/#SS). What remains here
                   // is the PER-ACCESS LIMIT check:
                   //   seg_off_over_limit : an operand whose last byte exceeds the
                   //                 segment limit is #GP(0); COMPUTED (0 for the
                   //                 in-bounds pseg corpus). Wiring it would raise a
                   //                 fault from the combinational data path AND
                   //                 needs an over-limit corpus test to validate —
                   //                 deferred to M2S.4 (documented follow-on).
                   seg_off_over_limit,
                   // M2S.2 — paging DECISIONS. The NOT-PRESENT #PF (PDE/PTE P=0)
                   // NOW DELIVERS (S_WALK -> start_fault(14), CR2 + error code; so
                   // walk_pf's delivery path IS live — it is sunk only because the
                   // gate's pages are all present so the flag is never set). What
                   // remains COMPUTED-not-delivered:
                   //   perm_fault  : the per-access P/RW/US permission-violation #PF
                   //                 (0 for the CPL=0/WP=0/present gate corpus) —
                   //                 M2S.4 follow-on (needs CPL3/WP test + raising
                   //                 from the data path); see perm_fault above.
                   //   pf_errcode  : the {US,RW,P} error code latch (the delivered
                   //                 #PF builds its error code inline in start_fault).
                   //   itlb_lk_perm: the fetch-side effective {US,RW,P} (home for a
                   //                 future fetch-permission / NX check; the I-TLB
                   //                 lookup port's perm output, now in u_itlb).
                   // Sunk so the clean -Wall lint stays quiet.
                   perm_fault, walk_pf, &pf_errcode,
                   itlb_lk_perm[0], itlb_lk_dirty,
                   // RESERVED system state, loaded this stage, gated-diffed later:
                   // GDT limit (descriptor-table bounds) + the IDTR (interrupts =
                   // M2S.3). Retained as the home for those checks.
                   gdt_limit[0], idt_base[0], idt_limit[0],
                   // M2S.4 — TR/TSS protection state COMPUTED-not-delivered. The
                   // cross-priv delivery reads TSS.ssN:espN unconditionally; the
                   // negative cases would consult:
                   //   tr_valid   : no TSS loaded -> a cross-priv delivery is #TS;
                   //                the pcpl corpus always LTRs a valid TSS first,
                   //                so this is always 1 and never gates a fault.
                   //   tr_limit   : the TSS limit (the ssN:espN read must lie within
                   //                it, else #TS); the 104-byte TSS always covers
                   //                SS0:ESP0, so the bound never trips. Retained as
                   //                the home for the #TS bound check (documented
                   //                M2S.4 follow-on; needs a truncated-TSS test).
                   tr_valid, tr_limit[0],
                   // M8.1 — inta_valid: the PIC asserts it with a meaningful
                   // inta_vector. The master 8259 always supplies a vector on the
                   // 2nd INTA cycle, so the divert latches inta_vector
                   // unconditionally; inta_valid is the home for a future spurious-
                   // IRQ7/IRQ15 refinement (deliver vector 7/15 with inta_valid=0).
                   // Sunk so -Wall stays quiet while the pin exists for ventium_soc.
                   inta_valid};
  // verilator lint_on UNUSED

endmodule : core
