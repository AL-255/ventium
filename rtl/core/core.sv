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

    // M6: errata-enable bus (docs/m6-errata-spec.md). DEFAULT 0 = clean core
    // (M0-M5, bit-exact vs QEMU). When a bit is set, the core reproduces the
    // corresponding DOCUMENTED P5/P54C silicon defect (a "buggy stepping"). The
    // flag fully gates each bug: with errata_en==0 the datapath is unchanged, so
    // `make verify` stays GREEN. Bit assignment (ERR_* localparams below):
    //   [0] FDIV/SRT divide flaw      (Erratum 23)
    //   [1] FIST/FISTP overflow       (Erratum 20)
    //   [2] F00F LOCK CMPXCHG8B reg    hang (Erratum 81)
    //   [3] MOV moffs A2/A3 non-pair   (Erratum 59, cycle-mode only)
    input  logic [3:0]  errata_en,

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
  // real_mode = system-mode core with CR0.PE==0. In real mode the addressing is
  // linear = (sel<<4)+offset (and the CS default operand size is 16-bit).
  logic        real_mode;
  assign real_mode = sys_mode && !creg0[0];

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
  // I-TLB (instruction fetches)
  logic                   itlb_val   [TLB_ENTRIES];
  logic [19:0]            itlb_vpn   [TLB_ENTRIES];   // linear page number lin[31:12]
  logic [19:0]            itlb_pfn   [TLB_ENTRIES];   // physical frame phys[31:12]
  logic [2:0]             itlb_perm  [TLB_ENTRIES];   // {US, RW, P} effective
  logic                   itlb_big   [TLB_ENTRIES];   // 1 = 4 MiB page
  // D-TLB (data accesses) — separately tracks the Dirty bit so a write marks D.
  logic                   dtlb_val   [TLB_ENTRIES];
  logic [19:0]            dtlb_vpn   [TLB_ENTRIES];
  logic [19:0]            dtlb_pfn   [TLB_ENTRIES];
  logic [2:0]             dtlb_perm  [TLB_ENTRIES];
  logic                   dtlb_big   [TLB_ENTRIES];
  logic                   dtlb_dirty [TLB_ENTRIES];   // page already marked D in mem

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
  // Physical register file (8 x 80-bit) + TOP. st(i) = fpr[(ftop+i)&7]. Push
  // decrements TOP then writes; pop increments TOP (leaving the stale value, so
  // the trace's "empty" st-slots keep their last contents — matches QEMU).
  logic [79:0] fpr [8];
  logic [2:0]  ftop;
  logic [15:0] fctrl;            // control word; reset 0x037f
  // fstat holds the condition codes (C0/C1/C2/C3) + exception flags, with the
  // TOP field (bits[13:11]) kept ZERO internally; it is overlaid from `ftop` on
  // read (mirrors QEMU helper_fnstsw). fstat[15:11] are never written here.
  logic [15:0] fstat;
  // Architectural tag: 1=empty, 0=valid (drives FXAM's empty-detect + the FXAM
  // C1 sign bit). NOT reported in the trace (QEMU's gdbstub abridges ftag to 0).
  logic [7:0]  fptag;           // bit i = tag for fpr[i] (1=empty)
  logic        x87_touched_r;   // retired insn touched the FPU (drives DPI call)

  // ===========================================================================
  // M6 errata-enable bit positions (docs/m6-errata-spec.md). Each gates exactly
  // one documented defect; all default OFF (errata_en==0 == clean M0-M5 core).
  // ===========================================================================
  localparam int ERR_FDIV  = 0;   // Erratum 23  : FDIV/SRT divide flaw
  localparam int ERR_FIST  = 1;   // Erratum 20  : FIST/FISTP overflow undetected
  localparam int ERR_F00F  = 2;   // Erratum 81  : LOCK CMPXCHG8B reg-dst hang
  localparam int ERR_MOFFS = 3;   // Erratum 59  : MOV moffs A2/A3 non-pairing

  // ===========================================================================
  // FSM
  // ===========================================================================
  typedef enum logic [4:0] {
    S_RESET, S_FETCH, S_DECODE, S_LOAD, S_LOAD2, S_EXEC, S_STORE, S_USEQ, S_HALT,
    S_FLOAD, S_FEXEC, S_FSTORE,
    S_PF, S_PIPE, S_F00F_HANG,
    // M2S.1 system-mode descriptor + table micro-sequences:
    S_LGDT, S_SEGLD, S_LJMP,
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
    S_LTR, S_INT_TSS, S_INT_SS, S_IRET_SS
  } state_e;
  state_e state;
  // M2S.2 page-walk return state (declared here so it can use state_e).
  state_e walk_ret_state;          // state to resume after a page walk

  // M6 Erratum 81: latched once the core enters the F00F hang (never clears
  // until reset). Drives the cpu_hung output and keeps the FSM parked.
  logic hung_r;
  assign cpu_hung = hung_r;

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
  localparam int IC_SETS = 128;
  localparam int IC_LINE = 32;
  logic [7:0]  ic_data [IC_SETS][2][IC_LINE];
  logic [19:0] ic_tag  [IC_SETS][2];   // addr[31:12]
  logic        ic_val  [IC_SETS][2];
  logic        ic_lru  [IC_SETS];      // 2-way LRU: way most-recently-used (== D$)
  logic [31:0] pf_fill_addr;         // line base currently being filled
  logic        pf_fill_way;          // 2-way victim way chosen for the fill
  logic [2:0]  pf_word;              // refill word counter (8 words = 32 bytes)

  // BTB: 64 sets x 4 ways, 2-bit saturating counters (Alpert & Avnon / AP-500).
  localparam int BTB_SETS = 64;
  localparam int BTB_WAYS = 4;
  logic [25:0] btb_tag [BTB_SETS][BTB_WAYS];   // pc/64
  logic [1:0]  btb_ctr [BTB_SETS][BTB_WAYS];   // 2-bit saturating
  logic        btb_val [BTB_SETS][BTB_WAYS];
  logic [1:0]  btb_rr  [BTB_SETS];             // round-robin replacement ptr

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

  // L1 D-cache TIMING model: 8 KB / 2-way / 32 B line / 128 sets, LRU. Data still
  // comes from the BFM (mem_rdata); this only gates WHEN a load completes. A read
  // miss adds dmiss; a misaligned access adds +3 (AP-500). Matches p5_mem() +
  // l1_access() in verif/qemu-plugins/p5trace.c (read-allocate, 2-way LRU).
  localparam int DC_SETS = 128;
  logic [19:0] dc_tag [DC_SETS][2];   // addr/32/128
  logic        dc_val [DC_SETS][2];
  logic        dc_lru [DC_SETS];      // 2-way LRU: way most-recently-used
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
  logic        d_unknown;
  // M2S.3 software/conditional interrupt + return decode (gated sys_mode in the
  // FSM; in user mode INT n still HALTs as before). d_int_n carries the vector.
  logic        d_int;            // INT n / INT3 / INTO -> IDT delivery (a TRAP)
  logic [7:0]  d_int_vec;        // the vector for d_int
  logic        d_int_cond_of;    // INTO: deliver only if OF (eflags bit 11) set
  logic        d_iret;           // IRET (CF): pop EIP/CS/EFLAGS
  logic        d_ud2;            // UD2 (0F 0B) -> #UD (vector 6) in sys mode
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
    SYS_LTR, SYS_STR
  } sysop_e;
  sysop_e      d_sysop;
  logic [2:0]  d_sys_sreg;     // target/source segment register index (mov sreg)
  logic [2:0]  d_sys_creg;     // CR index (0/2/3/4) for MOV CRn
  logic [31:0] d_ljmp_off;     // far-jump target offset
  logic [15:0] d_ljmp_sel;     // far-jump target selector
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

  // M2S.1 — ModR/M length contribution under EFFECTIVE addressing size. In
  // 32-bit addressing this is exactly the existing mfl(); in 16-bit addressing
  // (real mode w/o 0x67) the ONLY form the gate uses is [disp16] (mod00,rm110) =
  // 1 ModR/M byte + 2 disp = 3 bytes. (No SIB in 16-bit mode.) Other 16-bit
  // forms are unused by the gate and decode as length-2 here, but their handlers
  // also raise d_unknown so the wrong length is never committed.
  function automatic logic [3:0] mfl_e(input logic a16, input logic [1:0] mod,
                                       input logic [2:0] rm, input logic sib,
                                       input logic [2:0] base);
    if (!a16) return mfl(mod, rm, sib, base);
    // 16-bit addressing:
    if (mod==2'b00 && rm==3'b110) return 4'd3;       // [disp16]
    else if (mod==2'b00)          return 4'd1;       // [reg]/[reg+reg]
    else if (mod==2'b01)          return 4'd2;       // +disp8
    else if (mod==2'b10)          return 4'd3;       // +disp16
    else                          return 4'd1;       // reg-direct
  endfunction

  // x86 8-byte GDT/LDT descriptor field extraction (docs/m2s1-segmentation-spec).
  //   base  = desc[63:56]<<24 | desc[39:16]
  //   limit = desc[51:48]<<16 | desc[15:0]; granularity (G=desc[55]) scales by 4K.
  function automatic logic [31:0] desc_base(input logic [63:0] d);
    desc_base = {d[63:56], d[39:16]};
  endfunction
  function automatic logic [31:0] desc_limit(input logic [63:0] d);
    logic [19:0] lim20;
    begin
      lim20 = {d[51:48], d[15:0]};
      desc_limit = d[55] ? {lim20, 12'hFFF} : {12'd0, lim20};
    end
  endfunction
  // The descriptor access byte = d[47:40] = P|DPL[1:0]|S|type[3:0].
  function automatic logic [7:0] desc_attr (input logic [63:0] d); desc_attr = d[47:40]; endfunction
  function automatic logic       desc_present(input logic [7:0] a); desc_present = a[7];      endfunction
  function automatic logic [1:0] desc_dpl    (input logic [7:0] a); desc_dpl     = a[6:5];    endfunction
  function automatic logic       desc_s      (input logic [7:0] a); desc_s       = a[4];      endfunction
  function automatic logic [3:0] desc_type   (input logic [7:0] a); desc_type    = a[3:0];    endfunction
  // Type-bit helpers within a code/data (S=1) descriptor (type=a[3:0]):
  //   bit3 = executable (1=code,0=data); for code bit1=readable, for data bit1=writable.
  function automatic logic seg_is_code(input logic [7:0] a); seg_is_code = a[3]; endfunction
  function automatic logic seg_writable(input logic [7:0] a);  // data segment & W
    seg_writable = desc_s(a) && !a[3] && a[1];
  endfunction
  function automatic logic seg_readable(input logic [7:0] a);  // data, or readable code
    seg_readable = desc_s(a) && (!a[3] || a[1]);
  endfunction

  // -------------------------------------------------------------------------
  // PROTECTED-mode descriptor-load protection DECISION (IA-32 §5 / spec §3).
  // Computes whether a MOV-to-Sreg / far-JMP descriptor load WOULD fault. This
  // is the protection *decision* (#GP/#NP/#SS selector) — it is fully computed
  // here; fault *delivery* (vectoring through the IDT) is M2S.3, so for now a
  // raised decision can only HALT (the pseg corpus loads clean descriptors, so
  // the decision is always "no fault" and the core never halts on it). Encodes
  // the architectural rules:
  //   - a NULL selector (idx 0) into DS/ES/FS/GS is legal (loads a null seg, no
  //     fault); a null selector into SS or CS is #GP.
  //   - not-present (P=0)            -> #NP (#SS for SS)
  //   - system descriptor (S=0) used as a data/stack/code segment -> #GP
  //   - SS load: must be a writable data segment, DPL==CPL==RPL          -> #GP/#SS
  //   - DS/ES/FS/GS data load: must be readable; if non-conforming code/data,
  //     max(CPL,RPL) must be <= DPL                                      -> #GP
  //   - CS (far jmp, same-priv): must be executable (code)               -> #GP
  // `is_cs` selects the CS rules, `is_ss` the SS rules; `cpl`/`rpl` are the
  // current privilege and the selector RPL.
  function automatic logic seg_load_fault(
      input logic        is_cs, input logic is_ss,
      input logic [15:0] sel,   input logic [7:0] a,
      input logic [1:0]  cpl);
    logic       nullsel;
    logic [1:0] rpl, dpl;
    logic       fault;
    begin
      nullsel = (sel[15:3] == 13'd0);   // selector index 0 (RPL/TI ignored)
      rpl     = sel[1:0];
      dpl     = desc_dpl(a);
      fault   = 1'b0;
      if (nullsel) begin
        // null in CS or SS is illegal; null in DS/ES/FS/GS is fine.
        fault = is_cs || is_ss;
      end else begin
        if (!desc_present(a))          fault = 1'b1;            // #NP / #SS
        else if (!desc_s(a))           fault = 1'b1;            // system desc as seg -> #GP
        else if (is_cs) begin
          if (!seg_is_code(a))         fault = 1'b1;            // CS must be code
        end else if (is_ss) begin
          // SS: writable data, and DPL==CPL==RPL.
          if (!seg_writable(a))        fault = 1'b1;
          else if (dpl != cpl || rpl != cpl) fault = 1'b1;
        end else begin
          // DS/ES/FS/GS: readable; privilege max(CPL,RPL) <= DPL (data/non-conf code).
          if (!seg_readable(a))        fault = 1'b1;
          else if ((cpl > dpl) || (rpl > dpl)) fault = 1'b1;
        end
      end
      seg_load_fault = fault;
    end
  endfunction

  // M2S.3 — the IDT VECTOR for a raised descriptor-load fault (companion to
  // seg_load_fault; only meaningful when that returns 1). #NP(11) when a non-SS
  // present check fails; #SS(12) when an SS present check fails; #GP(13) for
  // every other descriptor-load fault (type/privilege/null-CS-SS). A NULL DS/ES/
  // FS/GS load is legal (no fault), so it never reaches here.
  function automatic logic [7:0] seg_fault_vec(
      input logic is_cs, input logic is_ss, input logic [15:0] sel,
      input logic [7:0] a);
    logic nullsel;
    begin
      nullsel = (sel[15:3] == 13'd0);
      if (!nullsel && !desc_present(a)) seg_fault_vec = is_ss ? 8'd12 : 8'd11;
      else                              seg_fault_vec = 8'd13;   // #GP
    end
  endfunction

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
    d_len=4'd1; d_halt=1'b0; d_unknown=1'b0; d_f00f=1'b0; d_is_branch=1'b0; d_branch_taken=1'b0;
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
    d_fxop=FX_NONE; d_is_x87=1'b0; d_f_mem_read=1'b0; d_f_mem_write=1'b0;
    d_f_msize=3'd0; d_f_mbytes=4'd0; d_f_pop=1'b0; d_f_pop2=1'b0; d_f_sti=3'd0;
    d_f_aluop=3'd0; d_f_const=3'd0;
    // M2S.1 system-decode defaults. d_seg defaults to DS for data accesses (stack
    // ops override to SS in their handlers below); a segment-override prefix wins.
    d_sysop=SYS_NONE; d_sys_sreg=3'd0; d_sys_creg=3'd0;
    d_ljmp_off=32'd0; d_ljmp_sel=16'd0;
    d_seg = d_pfx_seg_en ? d_pfx_seg_idx : 3'(SG_DS);
    // M2S.3 interrupt/return decode defaults.
    d_int=1'b0; d_int_vec=8'd0; d_int_cond_of=1'b0; d_iret=1'b0; d_ud2=1'b0;

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
    end

    // M2S.1 — 16-bit ADDRESSING (eff_addr==1, i.e. real mode w/o a 0x67 prefix).
    // The bare-metal bootstrap uses ONLY the direct form `[disp16]` (modrm
    // mod=00, rm=110) for the GDT-pointer writes + LGDT; recompute d_ea + the
    // ModR/M length contribution for it. Other 16-bit modes ([bx+si] etc) are a
    // DEFERRED corner (the pseg gate never uses them) -> d_unknown (loud HALT).
    // `amode16_len` is the ModR/M+disp byte count under 16-bit addressing; the
    // opcode handlers below use mfl() (32-bit) so we correct d_len when amode16.
    if (eff_addr) begin
      if (modrm_mod==2'b00 && modrm_rm==3'b110) begin
        // [disp16] direct: 2-byte displacement at m_idx+1.
        d_ea = {16'd0, ibuf[m_idx+2], ibuf[m_idx+1]};
      end
      // other 16-bit forms not needed by the gate -> flagged unknown below via
      // the per-opcode handler (which sees mod!=11 mem but we have no EA).
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
        // ---- M2S.1 system 0F opcodes ---------------------------------------
        8'h01: begin // 0F 01 /2 LGDT, /3 LIDT (memory operand = 6 bytes)
          if (modrm_reg==3'd2 || modrm_reg==3'd3) begin
            d_sysop=(modrm_reg==3'd2)?SYS_LGDT:SYS_LIDT;
            d_mem_read=1'b1;       // read the 6-byte pseudo-descriptor from memory
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
        8'b1000_????: begin // Jcc rel32
          d_len=pfx_len+4'd6; d_is_branch=1'b1; d_branch_taken=cond_true(op1[3:0],eflags);
          d_rel={ibuf[m_idx+3],ibuf[m_idx+2],ibuf[m_idx+1],ibuf[m_idx]};
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
        8'h8C: begin // MOV r/m16, Sreg  (M2S.1)
          // store the selector value of segment modrm_reg into r/m16. Reg form
          // only here (the corpus uses reg-form); a memory dest defers (HALT).
          d_sysop=SYS_MOVSREG_FROM; d_sys_sreg=sreg_idx(modrm_reg); d_w=3'd2;
          if (modrm_mod==2'b11) begin d_writes_reg=1'b1; d_dst_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_unknown=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
        end
        8'h8D: begin // LEA
          d_is_lea=1'b1; d_writes_reg=1'b1; d_dst_reg=modrm_reg;
          d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base);
        end
        8'h8E: begin // MOV Sreg, r/m16  (M2S.1)
          // load segment register modrm_reg from r/m16. Reg-form source only
          // here (the corpus loads sregs from a GPR); memory source defers.
          d_sysop=SYS_MOVSREG_TO; d_sys_sreg=sreg_idx(modrm_reg); d_w=3'd2;
          if (modrm_mod==2'b11) begin d_src_reg=modrm_rm; d_len=pfx_len+4'd2; end
          else begin d_unknown=1'b1; d_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
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
        8'hA0: begin // MOV AL, moffs8 (8-bit load, preserve [31:8])
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_mem_read=1'b1;
          d_w=3'd1;
          d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_len=pfx_len+4'd5;
        end
        8'hA1: begin // MOV eAX, moffs
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_writes_reg=1'b1; d_dst_reg=R_EAX; d_mem_read=1'b1;
          d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd5;
        end
        8'hA2: begin // MOV moffs8, AL (8-bit store)
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_mem_dst=1'b1; d_src_reg=R_EAX;
          d_w=3'd1;
          d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_len=pfx_len+4'd5;
        end
        8'hA3: begin // MOV moffs, eAX
          d_is_mov=1'b1; d_alu_op=ALU_MOV; d_mem_write=1'b1; d_mem_dst=1'b1; d_src_reg=R_EAX;
          d_ea={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]};
          d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd5;
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
              end else d_unknown=1'b1;
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
              d_kind=K_CTRL; d_ct=CT_CALLIND; d_mem_write=1'b1; d_w=3'd4;
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
            default: begin d_unknown=1'b1; d_len=pfx_len+4'd2; end
          endcase
        end
        8'hEB: begin d_len=pfx_len+4'd2; d_is_branch=1'b1; d_branch_taken=1'b1;
          d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE9: begin d_len=pfx_len+4'd5; d_is_branch=1'b1; d_branch_taken=1'b1;
          d_rel={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; end
        8'b0111_????: begin d_len=pfx_len+4'd2; d_is_branch=1'b1;
          d_branch_taken=cond_true(op0[3:0],eflags); d_rel={{24{ibuf[pfx_len+1][7]}},ibuf[pfx_len+1]}; end
        8'hE8: begin d_kind=K_CTRL; d_ct=CT_CALLREL; d_mem_write=1'b1; d_w=eff_opsize?3'd2:3'd4;
          // 0x66 near CALL: 16-bit rel (cw), push 16-bit next-IP, ESP-=2, and
          // EIP=(next_eip+rel16)&0xFFFF (operand-size-16 truncates EIP).
          if (eff_opsize) begin d_rel={16'd0,ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
          else begin d_rel={ibuf[pfx_len+4],ibuf[pfx_len+3],ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd5; end
        end
        8'hC3: begin d_kind=K_CTRL; d_ct=CT_RETN; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4; d_len=pfx_len+4'd1; end
        8'hC2: begin d_kind=K_CTRL; d_ct=CT_RETN_IMM; d_mem_read=1'b1; d_w=eff_opsize?3'd2:3'd4;
          d_ret_imm={ibuf[pfx_len+2],ibuf[pfx_len+1]}; d_len=pfx_len+4'd3; end
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
          if (sys_mode) begin d_int=1'b1; d_int_vec=ibuf[pfx_len+1]; end
          else d_halt=(ibuf[pfx_len+1]==8'h80);
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
        8'hF4: begin // HLT — stop retiring (a clean spin in the bare-metal test)
          d_halt=1'b1; d_len=pfx_len+4'd1;
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
                  3'd5: begin d_fxop=FX_FLDCW;    d_f_mem_read=1'b1;  d_f_mbytes=4'd2; end
                  3'd7: begin d_fxop=FX_FNSTCW;   d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  default: d_unknown=1'b1;   // /4 FLDENV /6 FNSTENV deferred
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
                  3'd7: begin d_fxop=FX_FNSTSW_M; d_f_mem_write=1'b1; d_f_mbytes=4'd2; end
                  default: d_unknown=1'b1;   // FRSTOR/FSAVE deferred
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
                  3'd5: begin d_fxop=FX_FILD_M64; d_f_mem_read=1'b1;  d_f_mbytes=4'd8; end
                  3'd7: begin d_fxop=FX_FIST_M64; d_f_mem_write=1'b1; d_f_mbytes=4'd8; d_f_pop=1'b1; end
                  default: d_unknown=1'b1;   // FBLD/FBSTP deferred
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
  ctk_e        q_ct;
  logic [15:0] q_ret_imm;
  logic        q_cld, q_std;
  logic        q_clc, q_stc, q_cmc;
  logic        q_cli, q_sti;
  logic        q_cnt16;

  // latched M2S.1 system decode
  sysop_e      q_sysop;
  logic [2:0]  q_sys_sreg, q_sys_creg, q_seg;
  logic [31:0] q_ljmp_off;
  logic [15:0] q_ljmp_sel;
  logic        seg_step;          // SEGLD descriptor-fetch beat counter (0/1)
  logic [31:0] gdt_lo;            // first dword of the in-flight 8-byte descriptor

  // -------------------------------------------------------------------------
  // M2S.3 IDT delivery state (latched when a fault/INT vectors). The delivery
  // micro-sequence (S_INT_GATE -> S_INT_CS -> S_INT_PUSH) reads the gate, reads
  // the target CS descriptor, and pushes the exception frame, then loads
  // CS:EIP. The frame is pushed at the gate's target privilege stack (here:
  // same-privilege, so the current SS:ESP — cross-priv stack switch via TSS is
  // M2S.4). All of this is INERT when !sys_mode.
  // -------------------------------------------------------------------------
  logic [7:0]  int_vec;           // the vector being delivered (0..255)
  logic [31:0] int_ret_eip;       // EIP to PUSH (faulting EIP for a FAULT, next
                                  // EIP for a TRAP / software INT)
  logic [31:0] int_src_pc;        // the q_pc to stamp on the delivery retire
                                  // record (the faulting/INT instruction's PC)
  logic        int_has_err;       // push a 32-bit error code for this vector
  logic [31:0] int_err;           // the error code value (selector / #PF bits)
  logic [2:0]  int_step;          // beat counter within S_INT_GATE/_CS/_PUSH
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
  logic [1:0]  int_new_cpl;       // target privilege level (= target CS.DPL)
  logic [15:0] int_new_ss;        // new SS selector from TSS.ssN
  logic [31:0] int_new_esp;       // new ESP from TSS.espN
  // M2S.4 inter-privilege IRET scratch. When the IRET-popped CS.RPL > current
  // CPL the return is to a LESS-privileged level: additionally pop ESP/SS, switch
  // to the outer stack, and null any data segment not accessible at the new CPL.
  logic        iret_interpriv;    // this IRET returns to a lower privilege
  logic [15:0] iret_ss;           // IRET-popped SS selector (inter-priv)
  logic [31:0] iret_esp;          // IRET-popped ESP (inter-priv)

  // latched x87 decode
  fxop_e       q_fxop;
  logic        q_is_x87;
  logic        q_f_mem_read, q_f_mem_write;
  logic [3:0]  q_f_mbytes;
  logic        q_f_pop, q_f_pop2;
  logic [2:0]  q_f_sti, q_f_aluop, q_f_const;
  logic [3:0]  f_step;             // x87 memory beat counter
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
    end else begin
      snap.cs=SEG_CS; snap.ss=SEG_SS; snap.ds=SEG_DS; snap.es=SEG_ES; snap.fs=SEG_FS; snap.gs=SEG_GS;
    end
  end
  assign retire_state=snap;
  assign retire_pc=q_pc;

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
      if (q_st==ST_SCAS)                           slow_dmem_addr = gpr[R_EDI];
      else                                         slow_dmem_addr = gpr[R_ESI];
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
      st_data = q_use_imm ? q_imm
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
    end else if (q_is_pop) begin
      // POP m: write the popped stack word to the memory destination.
      st_data = mem_load_data;
    end else if (q_is_mov) begin
      st_data = q_use_imm ? q_imm : reg_read(q_src_reg,q_w,q_src_high8);
    end else begin
      // ALU RMW / NEG / NOT / INC / DEC to memory
      st_data = alu_out;
    end

    // CALL/JMP indirect target
    if (q_ct==CT_CALLIND || q_ct==CT_JMPIND)
      call_target = q_mem_read ? mem_load_data : gpr[q_src_reg];
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
  // st(i) read helper on the physical regfile (st0 = fpr[ftop]).
  function automatic logic [2:0] fri(input logic [2:0] i); return ftop + i; endfunction
  function automatic logic [79:0] fst(input logic [2:0] i); return fpr[ftop + i]; endfunction

  // Compare two floatx80, return {C3,C2,C0} per QEMU fcom_ccval. The C1 bit is
  // left to the caller (compares clear only C3/C2/C0). less->001, equal->100,
  // greater->000, unordered->111 (unordered also when either is NaN).
  function automatic logic [2:0] fcom_codes(input logic [79:0] a, input logic [79:0] b);
    logic an, bn;   // NaN? (exp all-ones, mantissa != the pure-infinity pattern)
    begin
      an = (fx_exp(a)==15'h7fff) && (fx_man(a)!=64'h8000000000000000);
      bn = (fx_exp(b)==15'h7fff) && (fx_man(b)!=64'h8000000000000000);
      if (an || bn) fcom_codes = 3'b111;           // unordered: C3=1,C2=1,C0=1
      else if (fx_is_zero(a) && fx_is_zero(b)) fcom_codes = 3'b100;  // +0==-0 equal
      else if (fst_lt(a,b)) fcom_codes = 3'b001;   // less:  C0=1
      else if (fst_eq(a,b)) fcom_codes = 3'b100;   // equal: C3=1
      else                  fcom_codes = 3'b000;   // greater
    end
  endfunction
  // Ordered numeric < and == on normal/zero floatx80 (no NaN here).
  function automatic logic fst_eq(input logic [79:0] a, input logic [79:0] b);
    if (fx_is_zero(a) && fx_is_zero(b)) return 1'b1;
    return (a==b);
  endfunction
  function automatic logic fst_lt(input logic [79:0] a, input logic [79:0] b);
    logic sa, sb;
    logic [78:0] mag_a, mag_b;
    begin
      if (fx_is_zero(a) && fx_is_zero(b)) return 1'b0;
      sa=fx_sign(a); sb=fx_sign(b);
      mag_a = a[78:0]; mag_b = b[78:0];   // exp:mant magnitude
      if (fx_is_zero(a)) sa = sb ? 1'b0 : 1'b0;  // 0 vs nonzero handled by mag below
      if (sa != sb) return sa & ~(fx_is_zero(a)&&fx_is_zero(b));  // a<b if a negative
      // same sign: compare magnitudes
      if (!sa) return (mag_a < mag_b);   // both positive
      else     return (mag_a > mag_b);   // both negative: larger magnitude is smaller
    end
  endfunction

  // NaN classifiers on floatx80 (x86 convention, snan_bit_is_one=false). A NaN
  // has exp==0x7fff and is not the pure-infinity pattern (mantissa 0x8000..).
  // QNaN = the quiet bit (mantissa bit 62) is set; SNaN = quiet bit clear with
  // some other mantissa bit set. Mirrors softfloat floatx80_is_{quiet,signaling}.
  function automatic logic fx_is_nan(input logic [79:0] v);
    return (fx_exp(v)==15'h7fff) && (fx_man(v)!=64'h8000000000000000);
  endfunction
  function automatic logic fx_is_snan(input logic [79:0] v);
    // exp all-ones, quiet bit (62) clear, and (low<<1) with bit62 masked != 0.
    return (fx_exp(v)==15'h7fff) && !fx_man(v)[62] &&
           (({fx_man(v)[63], 1'b0, fx_man(v)[61:0]} << 1) != 64'd0);
  endfunction

  // Compare-time invalid (#IA) per QEMU: FCOM/FTST/FICOM use floatx80_compare
  // (SIGNALING) -> IE on ANY NaN operand; FUCOM uses floatx80_compare_quiet ->
  // IE only on a SIGNALING NaN. `signaling` selects which rule applies.
  function automatic logic fcom_ie(input logic [79:0] a, input logic [79:0] b,
                                    input logic signaling);
    if (signaling) return fx_is_nan(a) || fx_is_nan(b);
    else           return fx_is_snan(a) || fx_is_snan(b);
  endfunction

  // Apply compare condition codes to fstat: clear C3/C2/C0 (mask 0x4500, NOT C1)
  // and set per {C3,C2,C0} (QEMU helper_fcom: fpus = (fpus & ~0x4500) | ccval).
  // `ie` latches the invalid-operation flag (fstat bit0), sticky, when the
  // compare is unordered against a NaN that the op signals on.
  function automatic logic [15:0] apply_cmp(input logic [15:0] cur,
                                            input logic [2:0] codes, input logic ie);
    logic [15:0] r;
    begin
      r = cur & ~16'h4500;
      if (codes[2]) r[14] = 1'b1;   // C3
      if (codes[1]) r[10] = 1'b1;   // C2
      if (codes[0]) r[8]  = 1'b1;   // C0
      if (ie)       r[0]  = 1'b1;   // IE (sticky)
      return r;
    end
  endfunction

  // The ROM constants QEMU emits (default rounding). 80-bit canonical.
  function automatic logic [79:0] fconst(input logic [2:0] sel);
    unique case (sel)
      3'd0: fconst = 80'h3fff8000000000000000;          // 1.0
      3'd1: fconst = 80'h4000d49a784bcd1b8afe;          // log2(10)
      3'd2: fconst = 80'h3fffb8aa3b295c17f0bc;          // log2(e)
      3'd3: fconst = 80'h4000c90fdaa22168c235;          // pi
      3'd4: fconst = 80'h3ffd9a209a84fbcff799;          // log10(2)
      3'd5: fconst = 80'h3ffeb17217f7d1cf79ac;          // ln(2)
      default: fconst = 80'h00000000000000000000;       // 0.0
    endcase
  endfunction

  // FXAM condition codes {C3,C2,C1,C0} per QEMU helper_fxam_ST0 (C1=sign always).
  function automatic logic [3:0] fxam_codes(input logic [79:0] v, input logic empty);
    logic c1;
    logic [14:0] e;
    logic [63:0] m;
    begin
      c1 = v[79];                    // C1 = sign bit (set even when empty)
      if (empty) return {1'b1, 1'b0, c1, 1'b1};   // Empty: C3=1,C2=0,C0=1
      e = fx_exp(v); m = fx_man(v);
      if (e==15'h7fff) begin
        // QEMU helper_fxam_ST0: Inf -> 0x500 (C2+C0), NaN -> 0x100 (C0). The C1
        // sign bit (0x200) is overlaid by the caller for both.
        if (m==64'h8000000000000000) return {1'b0,1'b1,c1,1'b1};  // Inf: C2=1,C0=1 (0x500)
        else                          return {1'b0,1'b0,c1,1'b1};  // NaN: C0=1   (0x100)
      end else if (e==15'd0) begin
        if (m==64'd0) return {1'b1,1'b0,c1,1'b0};   // Zero: C3=1
        else          return {1'b1,1'b1,c1,1'b0};   // Denormal: C3=1,C2=1
      end else begin
        return {1'b0,1'b1,c1,1'b0};                 // Normal: C2=1
      end
    end
  endfunction

  // The assembled memory operand value -> floatx80, by size/kind.
  function automatic logic [79:0] f_mem_as_float(input logic [79:0] m80, input logic [3:0] bytes);
    unique case (bytes)
      4'd4:  f_mem_as_float = fx_from_f32(m80[31:0]);
      4'd8:  f_mem_as_float = fx_from_f64(m80[63:0]);
      default: f_mem_as_float = m80;     // m80 already floatx80
    endcase
  endfunction
  function automatic logic [79:0] f_mem_as_int(input logic [79:0] m80, input logic [3:0] bytes);
    unique case (bytes)
      4'd2:  f_mem_as_int = fx_from_int({{48{m80[15]}}, m80[15:0]});
      4'd4:  f_mem_as_int = fx_from_int({{32{m80[31]}}, m80[31:0]});
      default: f_mem_as_int = fx_from_int($signed(m80[63:0]));
    endcase
  endfunction

  // ARITHMETIC: compute {inexact, result} for ST(dst) given two floatx80 ops and
  // the x87 group sub-op (0 add,1 mul,4 sub,5 subr,6 div,7 divr). For the memory/
  // ST0-dest forms, a=ST0, b=mem/ST(i). For STI-dest forms, a=ST(i), b=ST0.
  // `fdiv_err` (M6 Erratum 23): when 1, the div/divr group routes through the
  // SRT-flaw-aware divide (fx_div_errata); when 0 (default) it uses the exact
  // fx_div, so the clean core is bit-identical. add/sub/mul are never affected.
  function automatic logic [80:0] f_arith(input logic [2:0] sub,
                                          input logic [79:0] a, input logic [79:0] b,
                                          input logic [1:0] rc,
                                          input logic fdiv_err);
    unique case (sub)
      3'd0: f_arith = fx_add(a, b, rc);                       // add
      3'd1: f_arith = fx_mul(a, b, rc);                       // mul
      3'd4: f_arith = fx_add(a, {~b[79], b[78:0]}, rc);       // sub: a - b
      3'd5: f_arith = fx_add(b, {~a[79], a[78:0]}, rc);       // subr: b - a
      3'd6: f_arith = fdiv_err ? fx_div_errata(a, b, rc)
                               : fx_div(a, b, rc);            // div: a / b
      default: f_arith = fdiv_err ? fx_div_errata(b, a, rc)
                                  : fx_div(b, a, rc);         // divr: b / a
    endcase
  endfunction

  // The two arithmetic operands for the current x87 op, in the canonical
  // (dividend/divisor, minuend/subtrahend) order f_arith expects, so the
  // execute stage can pre-test them for the special cases QEMU handles
  // explicitly (0/0 -> QNaN+IE, x/0 -> Inf+ZE, sqrt(neg) -> QNaN+IE) WITHOUT
  // duplicating the per-form operand selection. `fa` is the left operand,
  // `fb` the right, matching f_arith(sub, fa, fb).
  function automatic logic f_div_by_zero(input logic [2:0] sub,
                                         input logic [79:0] a, input logic [79:0] b);
    // x/0 with x finite-nonzero. Only the div/divr group can zero-divide.
    unique case (sub)
      3'd6:    return fx_is_zero(b) && !fx_is_zero(a) && !fx_is_nan(a);  // a/b
      3'd7:    return fx_is_zero(a) && !fx_is_zero(b) && !fx_is_nan(b);  // b/a
      default: return 1'b0;
    endcase
  endfunction
  function automatic logic f_zero_over_zero(input logic [2:0] sub,
                                            input logic [79:0] a, input logic [79:0] b);
    unique case (sub)
      3'd6:    return fx_is_zero(a) && fx_is_zero(b);   // 0/0
      3'd7:    return fx_is_zero(a) && fx_is_zero(b);   // 0/0
      default: return 1'b0;
    endcase
  endfunction

  // Full arithmetic evaluation with the exception cases QEMU handles explicitly
  // for masked, default-control operands. Returns {ie, ze, inexact, result}:
  //   0/0          -> real-indefinite QNaN, IE                 (helper_fdiv)
  //   x/0 (x!=0)   -> signed Inf, ZE                           (helper_fdiv)
  //   otherwise    -> normal-operand datapath via f_arith, PE = inexact.
  // (a,b) are in f_arith canonical order: div = a/b, divr = b/a, etc.
  function automatic logic [82:0] f_eval(input logic [2:0] sub,
                                         input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc,
                                         input logic fdiv_err);
    logic [80:0] r;
    begin
      if (f_zero_over_zero(sub, a, b))
        f_eval = {1'b1, 1'b0, 1'b0, 80'hFFFFC000000000000000};   // IE, indefinite
      else if (f_div_by_zero(sub, a, b)) begin
        r = f_arith(sub, a, b, rc, fdiv_err);                   // fx_div -> signed Inf
        f_eval = {1'b0, 1'b1, 1'b0, r[79:0]};                   // ZE
      end else begin
        r = f_arith(sub, a, b, rc, fdiv_err);
        f_eval = {1'b0, 1'b0, r[80], r[79:0]};                  // PE = inexact
      end
    end
  endfunction

  // Latch arithmetic status flags (sticky) into fstat from f_eval's flag bits.
  function automatic logic [15:0] f_arith_fstat(input logic [15:0] cur,
                                                input logic [82:0] arf);
    logic [15:0] r;
    begin
      r = cur;
      if (arf[82]) r[0] = 1'b1;   // IE
      if (arf[81]) r[2] = 1'b1;   // ZE
      if (arf[80]) r[5] = 1'b1;   // PE
      return r;
    end
  endfunction

  // ===========================================================================
  // x87 retire snapshot (TOP-relative st0..st7, fstat with TOP overlaid)
  // ===========================================================================
  assign retire_x87_touched = x87_touched_r;
  assign retire_fctrl = fctrl;
  assign retire_fstat = (fstat & ~16'h3800) | ({13'd0, ftop} << 11);
  assign retire_ftag  = 16'h0000;       // QEMU gdbstub abridges ftag to 0
  assign retire_st0 = fpr[ftop + 3'd0];
  assign retire_st1 = fpr[ftop + 3'd1];
  assign retire_st2 = fpr[ftop + 3'd2];
  assign retire_st3 = fpr[ftop + 3'd3];
  assign retire_st4 = fpr[ftop + 3'd4];
  assign retire_st5 = fpr[ftop + 3'd5];
  assign retire_st6 = fpr[ftop + 3'd6];
  assign retire_st7 = fpr[ftop + 3'd7];

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
  // of its set? (2-way, mirrors the oracle / the RTL D-cache lookup.)
  function automatic logic ic_present(input logic [31:0] addr);
    logic [6:0] set; logic [19:0] tag;
    begin
      set = addr[11:5]; tag = addr[31:12];
      ic_present = (ic_val[set][0] && ic_tag[set][0]==tag) ||
                   (ic_val[set][1] && ic_tag[set][1]==tag);
    end
  endfunction
  // which way holds the line (assumes ic_present(addr)); way 1 iff way0 misses.
  function automatic logic ic_hit_way(input logic [31:0] addr);
    logic [6:0] set; logic [19:0] tag;
    begin
      set = addr[11:5]; tag = addr[31:12];
      ic_hit_way = !(ic_val[set][0] && ic_tag[set][0]==tag);
    end
  endfunction
  // icache byte read (assumes ic_present(addr)): from whichever way hit.
  function automatic logic [7:0] ic_byte(input logic [31:0] addr);
    ic_byte = ic_data[addr[11:5]][ic_hit_way(addr)][addr[4:0]];
  endfunction

  // icache LRU update on a confirmed HIT (the line's set marks the hit way MRU).
  // Mirrors the oracle l1_access() hit path (s->lru = w) and the RTL D-cache
  // dc_access hit path, so the I-cache replacement SEQUENCE matches the oracle.
  task automatic ic_touch(input logic [31:0] addr);
    logic [6:0] set; logic [19:0] tag;
    begin
      set = addr[11:5]; tag = addr[31:12];
      for (int w=0; w<2; w++)
        if (ic_val[set][w] && ic_tag[set][w]==tag) ic_lru[set]<=w[0];
    end
  endtask

  // D-cache hit test (timing only): is the 32-byte line containing `addr`
  // resident in either way of its set? Mirrors p5model l1_access() lookup. Does
  // NOT mutate state (the allocate/LRU update is done in the sequential block on
  // a confirmed access, so the model is a true LRU SM, not a combinational peek).
  function automatic logic dc_hit(input logic [31:0] addr);
    logic [6:0]  set; logic [19:0] tag;
    begin
      set = addr[11:5]; tag = addr[31:12];
      dc_hit = (dc_val[set][0] && dc_tag[set][0]==tag) ||
               (dc_val[set][1] && dc_tag[set][1]==tag);
    end
  endfunction

  // D-cache access: update LRU on a hit, else allocate the not-MRU way (2-way
  // LRU replacement, exactly p5model l1_access()). Called once per load access
  // from the sequential block (so it advances the real cache SM, emergent).
  task automatic dc_access(input logic [31:0] addr);
    logic [6:0]  set; logic [19:0] tag; logic hit; logic victim;
    begin
      set = addr[11:5]; tag = addr[31:12]; hit = 1'b0; victim = ~dc_lru[set];
      for (int w=0; w<2; w++)
        if (dc_val[set][w] && dc_tag[set][w]==tag) begin hit=1'b1; dc_lru[set]<=w[0]; end
      if (!hit) begin
        dc_val[set][victim]<=1'b1; dc_tag[set][victim]<=tag; dc_lru[set]<=victim;
      end
    end
  endtask

  // BTB lookup: predicted-taken iff a valid matching entry has counter>=2.
  function automatic logic btb_lookup(input logic [31:0] pc);
    logic [5:0]  set; logic [25:0] tag; logic hit;
    begin
      set = pc[5:0]; tag = pc[31:6]; hit = 1'b0; btb_lookup = 1'b0;
      for (int w=0; w<BTB_WAYS; w++)
        if (btb_val[set][w] && btb_tag[set][w]==tag) begin
          hit=1'b1; btb_lookup = (btb_ctr[set][w] >= 2'd2);
        end
    end
  endfunction

  // BTB update after a branch resolves (mirrors p5model btb_update): a hit
  // saturates its 2-bit counter toward taken/not-taken; a miss on a TAKEN
  // branch allocates a way (pseudo-random/round-robin replacement) with a
  // weakly-taken counter; a miss on a not-taken branch allocates nothing.
  task automatic btb_update_taken(input logic [31:0] pc, input logic taken);
    logic [5:0]  set; logic [25:0] tag; logic hit; logic [1:0] way;
    begin
      set = pc[5:0]; tag = pc[31:6]; hit = 1'b0; way = 2'd0;
      for (int w=0; w<BTB_WAYS; w++)
        if (btb_val[set][w] && btb_tag[set][w]==tag) begin hit=1'b1; way=2'(w); end
      if (hit) begin
        if (taken && btb_ctr[set][way]!=2'd3) btb_ctr[set][way]<=btb_ctr[set][way]+2'd1;
        if (!taken && btb_ctr[set][way]!=2'd0) btb_ctr[set][way]<=btb_ctr[set][way]-2'd1;
      end else if (taken) begin
        btb_val[set][btb_rr[set]]<=1'b1;
        btb_tag[set][btb_rr[set]]<=tag;
        // first-taken => STRONGLY taken (ctr=3), matching the p5model oracle
        // (plugin/p5model.c:371 's->ctr[v]=3'). Allocating weakly-taken (2) would
        // diverge after a loop-exit not-taken: 2->1 (predict not-taken) re-warms a
        // mispredict on the next entry, whereas the oracle 3->2 stays predict-taken.
        btb_ctr[set][btb_rr[set]]<=2'd3;     // allocate strongly-taken (oracle)
        btb_rr[set]<=btb_rr[set]+2'd1;
      end
    end
  endtask

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
    u_pred_taken = btb_lookup(eip);

    // V datapath (independent of U by the pairing rule, so reading the OLD gpr
    // state is correct for both).
    v_alu   = alu_result(v_d.alu_op, reg_read(v_d.dst,3'd4,1'b0),
                         fp_bop(v_d), eflags[0]);
    v_flags = flags_next(v_d.alu_op, reg_read(v_d.dst,3'd4,1'b0),
                         fp_bop(v_d), v_alu, eflags, 3'd4);
    v_target = ((eip + {28'd0,u_d.len}) + {28'd0,v_d.len}) + v_d.rel;
    v_pred_taken = btb_lookup(eip + {28'd0,u_d.len});

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
        gpr[0]<=32'd0; gpr[1]<=32'd0; gpr[2]<=32'h0000_0663; gpr[3]<=32'd0;
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
        seg_attr[SG_CS]<=8'h9B;
        cpl_r<=2'd0;
        gdt_base<=32'd0; gdt_limit<=16'd0; idt_base<=32'd0; idt_limit<=16'd0;
        cs_d<=1'b1;   // user mode: flat 32-bit (def16 is gated off by !sys_mode)
      end
      fetch_word<=3'd0; retire_valid<=1'b0; step<=4'd0;
      // x87 reset = FNINIT state (control 0x037f, status 0, TOP 0, all empty).
      ftop<=3'd0; fctrl<=16'h037f; fstat<=16'h0000; fptag<=8'hFF;
      x87_touched_r<=1'b0; f_step<=4'd0;
      hung_r<=1'b0;   // M6 Erratum 81: not hung out of reset.
      for (int fi=0; fi<8; fi++) fpr[fi]<=80'd0;
      // M4 pipeline state.
      pf_fill_addr<=32'd0; pf_word<=3'd0; pf_fill_way<=1'b0;
      agi_wr0<=9'h100; agi_wr1<=9'h100; mispred_bubbles<=3'd0;
      // M5 cycle-accuracy state.
      core_cyc<=32'd0; fp_ready_cyc<=32'd0; pending_mem_pen<=7'd0; stall_cnt<=7'd0;
      fp_occ_pending<=1'b0; fp_issue_cyc<=32'd0;
      for (int s=0;s<DC_SETS;s++) begin
        dc_lru[s]<=1'b0; dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0;
        dc_tag[s][0]<=20'd0; dc_tag[s][1]<=20'd0;
      end
      retire2_valid<=1'b0; retire_pipe_valid<=1'b0;
      retire_pipe<=2'd0; retire_paired<=1'b0;
      retire2_pipe<=2'd0; retire2_paired<=1'b0;
      for (int s=0;s<BTB_SETS;s++) begin
        btb_rr[s]<=2'd0;
        for (int w=0;w<BTB_WAYS;w++) begin
          btb_val[s][w]<=1'b0; btb_tag[s][w]<=26'd0; btb_ctr[s][w]<=2'd0;
        end
      end
      for (int s=0;s<IC_SETS;s++) begin
        ic_lru[s]<=1'b0;
        ic_val[s][0]<=1'b0; ic_val[s][1]<=1'b0;
        ic_tag[s][0]<=20'd0; ic_tag[s][1]<=20'd0;
      end
      // M2S.2 paging: TLBs empty + walk idle out of reset.
      for (int t=0;t<TLB_ENTRIES;t++) begin
        itlb_val[t]<=1'b0; itlb_vpn[t]<=20'd0; itlb_pfn[t]<=20'd0;
        itlb_perm[t]<=3'd0; itlb_big[t]<=1'b0;
        dtlb_val[t]<=1'b0; dtlb_vpn[t]<=20'd0; dtlb_pfn[t]<=20'd0;
        dtlb_perm[t]<=3'd0; dtlb_big[t]<=1'b0; dtlb_dirty[t]<=1'b0;
      end
      walk_ret_state<=S_PIPE; walk_lin<=32'd0; walk_for_d<=1'b0;
      walk_is_write<=1'b0; walk_step<=3'd0; walk_pde<=32'd0; walk_pte<=32'd0;
      walk_pde_addr<=32'd0; walk_pte_addr<=32'd0; walk_pf<=1'b0; pf_errcode<=3'd0;
      // M2S.3 IDT delivery state idle out of reset.
      int_vec<=8'd0; int_ret_eip<=32'd0; int_src_pc<=32'd0; int_has_err<=1'b0;
      int_err<=32'd0; int_step<=3'd0; int_gate_off<=32'd0; int_gate_sel<=16'd0;
      int_gate_trap<=1'b0; int_lo<=32'd0; iret_eip<=32'd0; iret_cs<=16'd0;
      int_sw<=1'b0;
      // M2S.4 TR/TSS + cross-priv + inter-priv IRET state idle out of reset.
      tr_sel<=16'd0; tr_base<=32'd0; tr_limit<=32'd0; tr_valid<=1'b0;
      iret_eflags<=32'd0; xpl_active<=1'b0; int_old_ss<=16'd0; int_old_esp<=32'd0;
      int_old_cs<=16'd0; int_new_cpl<=2'd0; int_new_ss<=16'd0; int_new_esp<=32'd0;
      iret_interpriv<=1'b0; iret_ss<=16'd0; iret_esp<=32'd0;
    end else begin
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
      end else
      unique case (state)
        S_RESET: begin fetch_word<=3'd0; state<=S_PIPE; end

        // -------------------------------------------------------------------
        // S_PF: fill ONE 32-byte icache line (the line covering pf_fill_addr) via
        // 8 word reads, then return to the fast path. A cold line pays this fill
        // penalty once; thereafter the line is resident and re-fetches are free,
        // so a hot loop body converges to its steady-state CPI (the same icache
        // amortisation the p5model uses).
        // -------------------------------------------------------------------
        S_PF: begin
          if (mem_ack) begin
            ic_data[pf_fill_addr[11:5]][pf_fill_way][{pf_word,2'b00}+0]<=mem_rdata[7:0];
            ic_data[pf_fill_addr[11:5]][pf_fill_way][{pf_word,2'b00}+1]<=mem_rdata[15:8];
            ic_data[pf_fill_addr[11:5]][pf_fill_way][{pf_word,2'b00}+2]<=mem_rdata[23:16];
            ic_data[pf_fill_addr[11:5]][pf_fill_way][{pf_word,2'b00}+3]<=mem_rdata[31:24];
            if (pf_word==3'd7) begin
              pf_word<=3'd0;
              // allocate the chosen 2-way victim and mark it MRU (oracle l1_access
              // miss path: s->val[victim]=1; s->tag[victim]=tag; s->lru=victim).
              ic_tag[pf_fill_addr[11:5]][pf_fill_way]<=pf_fill_addr[31:12];
              ic_val[pf_fill_addr[11:5]][pf_fill_way]<=1'b1;
              ic_lru[pf_fill_addr[11:5]]<=pf_fill_way;
              state<=S_PIPE;
            end else pf_word<=pf_word+3'd1;
          end
        end

        // -------------------------------------------------------------------
        // S_PIPE: the dual-issue fast path. Each clock issues 0/1/2 simple
        // instructions through the U (and, when paired, V) pipe, with AGI
        // interlock + BTB/2-bit branch prediction. Non-simple insns or a dry
        // prefetch buffer hand control to the proven multi-cycle FSM / refill.
        // -------------------------------------------------------------------
        S_PIPE: begin
          if (stall_cnt!=7'd0) begin
            // M5: burn a materialised stall clock (D-cache miss / misalign /
            // FP-latency wait). No retirement; cyc = clock-count-at-retire thus
            // grows by exactly the penalty for the instruction that issues once
            // the countdown reaches 0. The stall clock writes nothing, so it
            // cannot create a phantom AGI hazard next clock.
            stall_cnt<=stall_cnt-7'd1;
            agi_wr0<=9'h100; agi_wr1<=9'h100;
          end else if (!pipe_bytes_ok) begin
            // icache miss on the line(s) covering the current insn: fill the
            // missing line (eip's line first, else the straddle line — the line of
            // either the decode-window end or the instruction's last byte). Each
            // fill = 8 word reads = imiss=8 clocks (the oracle penalty), emergent.
            // The 2-way victim is the not-MRU way (ic_lru^1), exactly the oracle's
            // `victim = s->lru ^ 1` (verif/qemu-plugins/p5trace.c:346).
            //
            // M5 finding [med] (I-miss off-by-one): the bus driver asserts the
            // fill's WORD-0 read in THIS detection clock (mem_addr = fill line base
            // when pf_miss is true), so this clock is productive — it captures word
            // 0 here and S_PF fetches words 1..7 (7 clocks). Total = 1 + 7 = 8
            // clocks = imiss exactly, with NO wasted transition clock (the old code
            // burned a non-fetching detection clock before the 8 fill clocks -> 9).
            ic_data[pf_miss_fa[11:5]][~ic_lru[pf_miss_fa[11:5]]][0]<=mem_rdata[7:0];
            ic_data[pf_miss_fa[11:5]][~ic_lru[pf_miss_fa[11:5]]][1]<=mem_rdata[15:8];
            ic_data[pf_miss_fa[11:5]][~ic_lru[pf_miss_fa[11:5]]][2]<=mem_rdata[23:16];
            ic_data[pf_miss_fa[11:5]][~ic_lru[pf_miss_fa[11:5]]][3]<=mem_rdata[31:24];
            pf_fill_addr <= pf_miss_fa;
            pf_fill_way  <= ~ic_lru[pf_miss_fa[11:5]];
            pf_word<=3'd1; state<=S_PF;
          end else if (pending_mem_pen!=7'd0) begin
            // M5: a previous load's D-cache miss/misalign penalty is DEFERRED to
            // the next instruction (p5model g.pending_mem_pen folded into the next
            // insn's pipe_free_at, verif/qemu-plugins/p5trace.c:420). Materialise
            // it as real stall clocks so the next retire's cyc carries the +dmiss
            // delta exactly where the oracle places it. This clock + the stall_cnt
            // countdown together burn `pending_mem_pen` clocks before any issue.
            stall_cnt<=pending_mem_pen-7'd1;
            pending_mem_pen<=7'd0;
            agi_wr0<=9'h100; agi_wr1<=9'h100;
          end else if (u_d.is_fp && u_d.fp_kind==FK_ARITH && fctrl[9:8]!=2'b11) begin
            // M5 finding [low]: an FK_ARITH (D8 reg-form fadd/fsub/fmul/fdiv) under
            // a non-extended precision control word (PC != 11) must NOT silently
            // compute the full extended-precision result (the datapath only
            // implements 64-bit extended). The slow path HALTs loudly in this case
            // (Tier-3 deferral, see f_pc_bad below); the fast path must do the same
            // so cycle-mode FP cannot diverge functionally from QEMU's
            // programmed-precision rounding. Default cw 0x037f has PC=11 (fine), so
            // the gate kernels never trip this; non-default-PC code HALTs.
            state<=S_HALT;
          end else if (u_d.is_fp) begin
            // M5: x87 FP fast path (cycle-mode whitelist). Functional execution
            // reuses the exact M3 helpers; the FP latency/throughput timing is
            // emergent from TWO distinct mechanisms, both mirroring the p5model
            // oracle (verif/qemu-plugins/p5trace.c):
            //   * RESULT LATENCY (fp_ready_cyc): a dependent FP consumer stalls
            //     until the producer's result is ready (issue+lat) -> dependent
            //     fadd chain CPI~3 (lat 3).
            //   * PIPE OCCUPANCY (fp_occ): the in-order pipe is held for `occ`
            //     clocks, so even a FOLLOWING INDEPENDENT op (integer or FP)
            //     cannot issue until the FP op's occupancy expires (oracle
            //     pipe_free_at=issue+occ; fdiv occ 39, fmul occ 2). This is what
            //     makes a single fdiv delay the integer work behind it.
            logic [31:0] dep_ready;
            logic [82:0] fp_arf;
            // RAW on the x87 top-of-stack: a consumer/rmw (fp_role>=2) must wait
            // until the most recent FP producer's result is ready (fp_ready_cyc).
            dep_ready = (u_d.fp_role>=3'd2) ? fp_ready_cyc : 32'd0;
            if (!fp_occ_pending && $signed(dep_ready - core_cyc) > 0) begin
              // stall until core_cyc reaches dep_ready (materialise the latency).
              stall_cnt <= 7'(dep_ready - core_cyc) - 7'd1;
              agi_wr0<=9'h100; agi_wr1<=9'h100;
            end else if (!fp_occ_pending && u_d.fp_occ > 7'd1) begin
              // deps satisfied; begin burning the pipe-occupancy clocks. Record the
              // issue cycle so the result-latency scoreboard is anchored to issue
              // (not to the later retire). THIS clock is the issue clock (occupancy
              // cycle 1) and the eventual commit clock is occupancy cycle `occ`;
              // between them we burn occ-2 stall clocks, so the op retires exactly
              // `occ` clocks after issue (oracle pipe_free_at = issue + occ).
              fp_issue_cyc <= core_cyc;
              fp_occ_pending <= 1'b1;
              stall_cnt <= u_d.fp_occ - 7'd2;   // occ>=2 here; occ==2 => no stall
              agi_wr0<=9'h100; agi_wr1<=9'h100;
            end else begin
              // ---- issue + commit the FP op (retires at issue+occ) -----------
              fp_arf = f_eval(u_d.fp_aluop, fst(3'd0), fst(u_d.fp_sti), fctrl[11:10], errata_en[ERR_FDIV]);
              unique case (u_d.fp_kind)
                FK_FLDC: begin
                  ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
                  fpr[ftop-3'd1]<=fconst(u_d.fp_sti);
                end
                FK_FLDSTI: begin
                  ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
                  fpr[ftop-3'd1]<=fst(u_d.fp_sti);
                end
                FK_ARITH: begin
                  fpr[ftop]<=fp_arf[79:0]; fstat<=f_arith_fstat(fstat, fp_arf);
                end
                FK_FSTP0: begin
                  fptag[ftop]<=1'b1; ftop<=ftop+3'd1;
                end
                FK_FXCH: begin
                  fpr[ftop]<=fst(u_d.fp_sti); fpr[fri(u_d.fp_sti)]<=fst(3'd0);
                end
                default: ;
              endcase
              // scoreboard: a producer/rmw publishes its result at ISSUE+lat. For
              // an occ-burned op the issue cycle was recorded above; for an occ==1
              // op issue==commit clock (core_cyc) — both anchor to the real issue.
              if (u_d.fp_role==3'd1 || u_d.fp_role==3'd3)
                fp_ready_cyc <= (fp_occ_pending ? fp_issue_cyc : core_cyc)
                                + {25'd0, u_d.fp_lat};
              fp_occ_pending <= 1'b0;
              // I-cache LRU: mark this fetched line MRU (2-way LRU, per the oracle
              // per-fetch l1_access). FP ops are 2 bytes (no straddle in practice).
              ic_touch(flin);
              eip<=eip + {28'd0,u_d.len};
              q_pc<=eip; retire_valid<=1'b1; x87_touched_r<=1'b1;
              retire_pipe_valid<=1'b1; retire_pipe<=2'd0; retire_paired<=1'b0;
              agi_wr0<=9'h100; agi_wr1<=9'h100;   // FP writes no GP reg
            end
          end else if (!u_d.simple || sys_mode) begin
            // hand this one instruction to the slow functional FSM. Clear the
            // AGI write-tracking: the slow op runs many cycles, so on return to
            // (M2S.1: a SYSTEM-mode core ALWAYS takes the slow FSM — the fast-path
            //  decoder assumes 32-bit/flat and is unaware of real-mode 16-bit
            //  defaults + segment bases. cycle_mode is 0 in the sys gate, so this
            //  costs nothing there, and user mode is untouched.)
            // S_PIPE the LAST fast-path write is no longer "the immediately
            // preceding clock" and must not trigger a PHANTOM AGI stall (p5model
            // AGI checks reg_wcycle==issue-1, plugin/p5model.c:451).
            agi_wr0<=9'h100; agi_wr1<=9'h100;
            fetch_word<=3'd0; state<=S_FETCH;
          end else if (mispred_bubbles!=3'd0) begin
            // burn a misprediction flush bubble (no retirement this clock).
            mispred_bubbles<=mispred_bubbles-3'd1;
            agi_wr0<=9'h100; agi_wr1<=9'h100;   // bubble writes nothing
          end else if (pipe_agi) begin
            // AGI 1-cycle interlock: stall this clock. The double-charge across
            // the immediately-following clock is prevented STRUCTURALLY by
            // clearing agi_wr0/agi_wr1 here (the stall clock writes nothing), so
            // next clock pipe_agi recomputes to 0 and the insn issues. This
            // charges the stall EVERY time the hazard exists (matching p5model's
            // per-issue reg_wcycle==issue-1 check, plugin/p5model.c:451) rather
            // than only the first time a given PC is seen -> correct for looped
            // AGI sites, where a fixed PC-suppressor would undercount stalls.
            agi_wr0<=9'h100; agi_wr1<=9'h100;   // stall clock writes nothing
          end else begin
            // ---- ISSUE: commit U, and V if paired -------------------------
            logic [8:0]  w0, w1;
            logic        do_v;
            logic [31:0] post_eip;
            logic        u_is_br, redirect, u_taken;
            logic [31:0] redir_tgt;
            do_v   = pipe_pair;
            w0=9'h100; w1=9'h100;

            // ---- I-cache LRU: mark the fetched line(s) MRU (2-way LRU, mirroring
            // the oracle's per-instruction l1_access). U's line, U's straddle line
            // (only when it crosses the boundary), and the paired V's line are the
            // lines actually fetched this clock. Order matches the oracle (U then
            // its straddle then V).
            ic_touch(flin);
            if (({1'b0,flin[4:0]} + {2'b0,u_d.len}) > 6'd32)
              ic_touch(flin + {28'd0,u_d.len} - 32'd1);
            if (do_v) ic_touch(flin + {28'd0,u_d.len});

            // ---- U commit ----
            if (u_d.is_lea) begin
              gpr[u_d.dst]<=gpr[u_d.base];
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
            end else if (u_d.is_load) begin
              gpr[u_d.dst]<=mem_rdata;
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
              // M5: L1 D-cache TIMING. The load data still comes from the BFM
              // (mem_rdata, above); here we run the real 2-way LRU hit/miss SM and
              // DEFER any miss penalty (read-allocate +dmiss) / misalign (+3) to
              // the next instruction, exactly as p5_mem()/p5model does. A line
              // that misses is allocated now (dc_access) so re-references hit.
              dc_access(gpr[u_d.base]);
              begin
                logic [6:0] pen;
                pen = 7'd0;
                if (!dc_hit(gpr[u_d.base]))         pen = pen + P5_DMISS;
                if (gpr[u_d.base][1:0] != 2'b00)    pen = pen + P5_MISALIGN;
                pending_mem_pen <= pen;
              end
            end else if (u_d.is_shift) begin
              gpr[u_d.dst]<=u_sh;
              if (u_d.shimm!=5'd0) begin
                logic [31:0] fl;
                // SHL/SHR/SAL/SAR (shrot 4..7): SF/ZF/PF from result, AF=0,
                // CF & OF per QEMU (OF = MSB(shm1) ^ MSB(result)). Matches the
                // slow path's K_SHIFT block exactly (only this group reaches the
                // fast path; rotates fall back to the slow FSM).
                fl=eflags & 32'hFFFF_F72A;
                fl[0]=u_shcf; fl[2]=parity8(u_sh[7:0]); fl[4]=1'b0;
                fl[6]=(u_sh==32'd0); fl[7]=u_sh[31];
                fl[11]=u_shm1[31]^u_sh[31]; fl[1]=1'b1;
                eflags<=fl;
              end
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
            end else if (u_d.is_branch || u_d.is_nop) begin
              // no register/flag write
            end else begin
              if (u_d.wreg) begin
                gpr[u_d.dst]<=u_alu;
                if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
              end
              if (u_d.wflags) eflags<=u_flags;
            end

            // ---- V commit (paired) ----
            if (do_v) begin
              if (v_d.is_lea) begin
                gpr[v_d.dst]<=gpr[v_d.base];
                if (v_d.dst!=R_ESP) w1={6'd0,v_d.dst};
              end else if (v_d.is_branch || v_d.is_nop) begin
                // V branch: handled via branch logic below
              end else begin
                if (v_d.wreg) begin
                  gpr[v_d.dst]<=v_alu;
                  if (v_d.dst!=R_ESP) w1={6'd0,v_d.dst};
                end
                // a paired V that writes flags overrides U's flags (program
                // order: V is later). Only ALU/inc/dec reach here.
                if (v_d.wflags) eflags<=v_flags;
              end
            end

            // ---- branch resolution (U leads; or V branch when paired) -----
            // Determine the architectural taken decision + predicted target and
            // whether we mispredicted -> flush bubbles. The branch can be U
            // (unpaired) or the V member of a pair.
            u_is_br  = u_d.is_branch;
            u_taken  = 1'b0; redirect=1'b0; redir_tgt=32'd0;
            post_eip = eip + {28'd0,u_d.len} + (do_v ? {28'd0,v_d.len} : 32'd0);

            if (u_is_br) begin
              // U is the (sole) branch this clock.
              u_taken = u_d.br_cond ? u_d.br_taken : 1'b1;
              redir_tgt = u_taken ? u_target : (eip + {28'd0,u_d.len});
              if (u_taken != u_pred_taken) begin
                mispred_bubbles <= 3'd3;     // U-pipe mispredict penalty
                redirect=1'b1;
              end else if (u_taken) redirect=1'b1;
              btb_update_taken(eip, u_taken);
            end else if (do_v && v_d.is_branch) begin
              // V member is a simple branch (e.g. a jcc paired into V). Use the
              // flags FORWARDED from U (cmp/dec/test + jcc pairing case).
              logic v_taken; logic [31:0] vpc;
              vpc = eip + {28'd0,u_d.len};
              v_taken = v_br_taken_eff;
              redir_tgt = v_taken ? v_target : (vpc + {28'd0,v_d.len});
              if (v_taken != v_pred_taken) begin
                // Mispredict penalty matches the oracle resolve_pending_branch
                // (verif/qemu-plugins/p5trace.c:402-403): an UNCONDITIONAL taken
                // jmp/call mispredict is P5_MISPREDICT_UNCOND=3 REGARDLESS of pipe
                // (the `!pend_cond` case is checked first); only a CONDITIONAL Jcc
                // in the V pipe pays P5_MISPREDICT_V=4. The old code charged 4 for
                // a V jmp too (now V-pairable per finding [med]) -> +1 over oracle.
                mispred_bubbles <= v_d.br_cond ? 3'd4 : 3'd3;
                redirect=1'b1;
              end else if (v_taken) redirect=1'b1;
              btb_update_taken(vpc, v_taken);
            end

            eip <= redirect ? redir_tgt : post_eip;
            agi_wr0<=w0; agi_wr1<=w1;

            // ---- retire records (cyc/pipe/paired emerge from the cadence) --
            q_pc <= eip;                       // primary (U) retire pc
            retire_valid <= 1'b1;
            retire_pipe_valid <= 1'b1;
            retire_pipe <= 2'd0;        // U
            retire_paired <= 1'b0;
            if (do_v) begin
              // GUARD: dual-issue (V retire) is CYCLE-MODE ONLY. retire2_state is
              // hardwired to the primary (U) `snap` and is NOT a valid post-commit
              // snapshot for the V instruction, so a paired V must never be emitted
              // in a state-checked (func) run. pipe_pair already ANDs cycle_mode;
              // this assertion locks that invariant so a future change that lets
              // pairing leak into func mode trips loudly instead of silently
              // comparing the wrong architectural state for the V member.
              // synopsys translate_off
              if (!cycle_mode) begin
                $error("core: paired V retire (do_v) in func mode (cycle_mode=0): retire2_state is U's snap, not the V insn's post-commit state");
              end
              // synopsys translate_on
              q_pc2 <= eip + {28'd0,u_d.len};   // V retire pc
              retire2_valid <= 1'b1;
              retire2_pipe  <= 2'd1;    // V
              retire2_paired<= 1'b1;
            end
            // After a redirect the next S_PIPE clock re-checks icache presence
            // (pipe_bytes_ok) and fills the target line via S_PF if cold.
          end
        end

        S_FETCH: begin
          if (mem_ack) begin
            ibuf[{fetch_word,2'b00}+0]<=mem_rdata[7:0];
            ibuf[{fetch_word,2'b00}+1]<=mem_rdata[15:8];
            ibuf[{fetch_word,2'b00}+2]<=mem_rdata[23:16];
            ibuf[{fetch_word,2'b00}+3]<=mem_rdata[31:24];
            if (fetch_word==3'(IWORDS-1)) begin fetch_word<=3'd0; state<=S_DECODE; end
            else fetch_word<=fetch_word+3'd1;
          end
        end

        S_DECODE: begin
          q_len<=d_len; q_is_branch<=d_is_branch; q_branch_taken<=d_branch_taken;
          q_rel<=d_rel; q_alu_op<=d_alu_op; q_writes_reg<=d_writes_reg;
          q_writes_flags<=d_writes_flags; q_mem_read<=d_mem_read; q_mem_write<=d_mem_write;
          q_mem_dst<=d_mem_dst; q_dst_reg<=d_dst_reg; q_src_reg<=d_src_reg; q_imm<=d_imm;
          q_use_imm<=d_use_imm; q_is_push<=d_is_push; q_is_pop<=d_is_pop; q_is_lea<=d_is_lea;
          q_is_mov<=d_is_mov; q_ea<=d_ea; q_pc<=eip; q_w<=d_w; q_dst_high8<=d_dst_high8;
          q_src_high8<=d_src_high8; q_kind<=d_kind; q_shrot<=d_shrot; q_shift_cl<=d_shift_cl;
          q_shift_one<=d_shift_one; q_shift_imm<=d_shift_imm; q_shrd<=d_shrd; q_md<=d_md;
          q_imul_3op<=d_imul_3op; q_imul_imm<=d_imul_imm; q_ext_signed<=d_ext_signed;
          q_ext_srcw<=d_ext_srcw; q_cc<=d_cc; q_bit_imm<=d_bit_imm; q_bit_op<=d_bit_op;
          q_conv_cdq<=d_conv_cdq; q_sm<=d_sm; q_st<=d_st; q_rep<=(pfx_rep==2'd3);
          q_repne<=(pfx_rep==2'd2); q_str_loadsi<=d_str_loadsi; q_str_storedi<=d_str_storedi;
          q_str_scandi<=d_str_scandi; q_ct<=d_ct; q_ret_imm<=d_ret_imm;
          q_cld<=d_cld; q_std<=d_std; step<=4'd0;
          q_clc<=d_clc; q_stc<=d_stc; q_cmc<=d_cmc; q_cnt16<=d_cnt16;
          q_cli<=d_cli; q_sti<=d_sti;
          // latch x87 decode
          q_fxop<=d_fxop; q_is_x87<=d_is_x87; q_f_mem_read<=d_f_mem_read;
          q_f_mem_write<=d_f_mem_write; q_f_mbytes<=d_f_mbytes; q_f_pop<=d_f_pop;
          q_f_pop2<=d_f_pop2; q_f_sti<=d_f_sti; q_f_aluop<=d_f_aluop; q_f_const<=d_f_const;
          f_step<=4'd0;
          // M2S.1 system decode latch.
          q_sysop<=d_sysop; q_sys_sreg<=d_sys_sreg; q_sys_creg<=d_sys_creg;
          q_seg<=d_seg; q_ljmp_off<=d_ljmp_off; q_ljmp_sel<=d_ljmp_sel;
          seg_step<=1'b0;
          // M2S.3 INT/IRET/UD2 are dispatched directly from the d_* decode below
          // (they begin their micro-sequence in S_DECODE), so no q_* latch is
          // needed: the delivery state is captured in int_* / iret_* instead.

          if (d_halt || d_unknown) begin
            // M5 finding [low]: in CYCLE mode the oracle emits a retire record for
            // the terminating `int 0x80` (it is a retired instruction to the TCG
            // plugin), so the RTL must too — otherwise the cycle trace is one
            // record short of the golden and compare.py reports a LENGTH MISMATCH
            // (harmless under the current gate, which ignores compare's exit code,
            // but it would fail a tightened gate that honored it). Emit ONE retire
            // for a genuine HALT syscall (d_halt) and THEN stop. d_unknown (an
            // out-of-scope opcode) stays a LOUD no-retire HALT — never a record, so
            // an unsupported opcode can never masquerade as a clean run. Func mode
            // keeps the M0/QEMU-gdbstub convention (no post-state row for the exit
            // syscall), so this extra retire is cycle-mode only and cannot perturb
            // the functional gates.
            if (cycle_mode && d_halt && !d_unknown) begin
              q_pc<=eip; retire_valid<=1'b1;
              retire_pipe_valid<=1'b1; retire_pipe<=2'd0; retire_paired<=1'b0;
            end
            // M6 Erratum 81 (F00F): the invalid LOCK CMPXCHG8B reg-dst form. With
            // errata enabled AND the LOCK prefix present, reproduce the documented
            // HANG (the bus stays locked so the #UD handler never starts) instead
            // of the clean loud HALT. The non-locked invalid form, and the valid
            // memory form (mod!=11, never d_f00f), still take the clean HALT path.
            if (d_f00f && errata_en[ERR_F00F] && pfx_lock)
              state<=S_F00F_HANG;
            else
              state<=S_HALT;
          end
          else if (d_is_x87) begin
            if (d_f_mem_read) state<=S_FLOAD;       // read mem operand first
            else state<=S_FEXEC;                    // reg/const/control op
          end
          // ---- M2S.3 IDT delivery: software INT n / INT3 / INTO / UD2 --------
          // These are TRAPS except UD2 (#UD, a FAULT). A TRAP pushes the EIP of
          // the NEXT instruction (so IRET resumes after the INT); UD2 (#UD) is a
          // FAULT and pushes the FAULTING EIP (this instruction). INTO only
          // delivers when OF is set — otherwise it is a no-op that just advances.
          // None of these carry an error code (#UD has none either).
          else if (d_int || d_ud2) begin
            if (d_int && d_int_cond_of && !eflags[11]) begin
              state<=S_EXEC;            // INTO with OF=0: no-op, advance EIP
            end else begin
              int_vec     <= d_ud2 ? 8'd6 : d_int_vec;
              // FAULT (#UD) pushes the faulting EIP; a TRAP (INT/INT3/INTO)
              // pushes the NEXT EIP. In S_DECODE q_pc/q_len are not yet latched,
              // so derive next-EIP from the live eip + decoded length.
              int_ret_eip <= d_ud2 ? eip : (eip + {28'd0, d_len});
              int_src_pc  <= eip;
              int_has_err <= 1'b0;      // INT/INT3/INTO/#UD: no error code
              int_err     <= 32'd0;
              int_step    <= 3'd0;
              // SOFTWARE INT n/INT3/INTO are subject to the gate DPL>=CPL check
              // (IA-32 6.12.1.2); #UD (d_ud2) is a HARDWARE fault that bypasses it.
              int_sw      <= d_int && !d_ud2;
              state       <= S_INT_GATE;
            end
          end
          else if (d_iret) begin
            int_step <= 3'd0; int_src_pc <= eip; state <= S_IRET;
          end
          // ---- M2S.1 system instructions ------------------------------------
          else if (d_sysop != SYS_NONE) begin
            unique case (d_sysop)
              SYS_LGDT, SYS_LIDT: state<=S_LGDT;    // read 6-byte pseudo-desc
              SYS_MOVSREG_TO: begin
                // load a segment register. In REAL mode (or a null/PM-but-here
                // we keep it simple) compute the hidden base directly; in
                // PROTECTED mode read the 8-byte descriptor from the GDT first.
                if (real_mode) state<=S_EXEC;       // base = sel<<4, no fetch
                else state<=S_SEGLD;                // PM: fetch descriptor
              end
              SYS_LJMP: begin
                // far jump. REAL mode: base=sel<<4, jump now. PM: load CS from
                // the GDT descriptor (S_LJMP fetches it) then switch.
                if (real_mode) state<=S_EXEC;
                else state<=S_LJMP;
              end
              SYS_LTR: begin
                // LTR — read the GDT TSS descriptor (S_LTR fetches it, loads the
                // TR hidden base/limit + sets the descriptor busy bit).
                seg_step<=1'b0; state<=S_LTR;
              end
              default: state<=S_EXEC;  // MOV CRn to/from, MOV/STR sreg: no fetch
            endcase
          end
          else if (d_kind==K_STR) begin
            // REP with ECX==0: degenerate single no-op record (advance EIP).
            if ((pfx_rep!=2'd0) && (gpr[R_ECX]==32'd0)) state<=S_EXEC; // handled as no-op
            else if (d_mem_read) state<=S_LOAD;   // movs/lods/scas/cmps load first
            else state<=S_EXEC;                    // stos stores directly
          end
          else if (d_mem_read || d_is_pop ||
                   (d_kind==K_STKMISC && (d_sm==SM_LEAVE || d_sm==SM_POPF)))
            state<=S_LOAD;
          else state<=S_EXEC;
        end

        S_LOAD: begin
          if (mem_ack) begin
            mem_load_data<=mem_rdata;
            // M5 finding [med] (D-cache state consistency): a SLOW-PATH data load
            // (displacement/SIB load, RMW source, string/stack load) must mutate
            // the D-cache timing model exactly like the oracle's p5_mem (which runs
            // l1_access for EVERY memory op, not just register-indirect loads). Do
            // the 2-way LRU access here and DEFER a read-miss/misalign penalty to
            // the next instruction (read-allocate), so a line warmed by a slow-path
            // access is later seen RESIDENT by a fast-path load (and vice-versa).
            // Gated on cycle_mode (func mode does no cycle accounting).
            if (cycle_mode) begin
              logic [31:0] la; logic [6:0] pen;
              la = slow_dmem_addr; pen = 7'd0;
              if (!dc_hit(la))           pen = pen + P5_DMISS;
              if (la[1:0] != 2'b00)      pen = pen + P5_MISALIGN;
              dc_access(la);
              pending_mem_pen <= pen;
            end
            if (q_kind==K_STR && q_st==ST_CMPS) state<=S_LOAD2;
            else state<=S_EXEC;
          end
        end
        S_LOAD2: begin
          if (mem_ack) begin
            mem_load_data2<=mem_rdata; state<=S_EXEC;
            // CMPS second operand [EDI] is also a data load -> D-cache access.
            if (cycle_mode) begin
              logic [6:0] pen; pen=7'd0;
              if (!dc_hit(gpr[R_EDI]))      pen = pen + P5_DMISS;
              if (gpr[R_EDI][1:0]!=2'b00)   pen = pen + P5_MISALIGN;
              dc_access(gpr[R_EDI]);
              pending_mem_pen <= pen;
            end
          end
        end

        // -------------------------------------------------------------------
        // S_FLOAD: read the x87 memory operand (m16/m32 = 1 word, m64 = 2,
        // m80 = 3) into f_mem80, LSB-first. Bus addresses q_ea + 4*f_step.
        // -------------------------------------------------------------------
        S_FLOAD: begin
          if (mem_ack) begin
            unique case (f_step)
              4'd0: f_mem80[31:0]  <= mem_rdata;
              4'd1: f_mem80[63:32] <= mem_rdata;
              default: f_mem80[79:64] <= mem_rdata[15:0];
            endcase
            // total words needed: m16/m32->1, m64->2, m80->3
            if ((q_f_mbytes<=4'd4) ||
                (q_f_mbytes==4'd8 && f_step==4'd1) ||
                (q_f_mbytes==4'd10 && f_step==4'd2)) begin
              f_step<=4'd0; state<=S_FEXEC;
            end else f_step<=f_step+4'd1;
          end
        end

        // -------------------------------------------------------------------
        S_EXEC: begin
          logic do_store, do_retire;
          logic [31:0] new_eip;
          logic flags_we;
          logic [31:0] flags_val;
          do_store=1'b0; do_retire=1'b1; new_eip=next_eip; flags_we=q_writes_flags; flags_val=flags_out;

          if (q_cld) begin eflags<=eflags & ~32'h0000_0400; flags_we=1'b0; end
          else if (q_std) begin eflags<=eflags | 32'h0000_0400; flags_we=1'b0; end
          else if (q_clc) begin eflags<=eflags & ~32'h0000_0001; flags_we=1'b0; end // CF<-0
          else if (q_stc) begin eflags<=eflags | 32'h0000_0001;  flags_we=1'b0; end // CF<-1
          else if (q_cmc) begin eflags<=eflags ^ 32'h0000_0001;  flags_we=1'b0; end // CF<-~CF
          else if (q_cli) begin eflags<=eflags & ~32'h0000_0200; flags_we=1'b0; end // IF<-0
          else if (q_sti) begin eflags<=eflags | 32'h0000_0200;  flags_we=1'b0; end // IF<-1
          // ---- M2S.1 system ops with no memory operand --------------------
          else if (q_sysop==SYS_MOVCR_TO) begin
            // MOV CRn, r32. M2S.1 made CR0.PE active (real->protected); M2S.2 makes
            // CR0.PG (paging enable), CR3 (PDBR) and CR4.PSE active. Writing CR0.PE
            // is the real->protected transition; writing CR0.PG turns paging on
            // (its own retire record, cr0 0x6...->0xe...). A CR3 load (new page-
            // directory base) flushes the TLBs (IA-32 §4.10: MOV CR3 invalidates
            // all non-global TLB entries) — for the gate this happens with PG still
            // 0 so the TLBs are already empty, but the flush keeps it correct.
            flags_we=1'b0;
            unique case (q_sys_creg)
              3'd0: creg0<=gpr[q_src_reg];
              3'd2: creg2<=gpr[q_src_reg];
              3'd3: begin
                creg3<=gpr[q_src_reg];
                for (int t=0;t<TLB_ENTRIES;t++) begin
                  itlb_val[t]<=1'b0; dtlb_val[t]<=1'b0;
                end
              end
              default: creg4<=gpr[q_src_reg];
            endcase
          end
          else if (q_sysop==SYS_MOVCR_FROM) begin
            // MOV r32, CRn.
            flags_we=1'b0;
            unique case (q_sys_creg)
              3'd0: gpr[q_dst_reg]<=creg0;
              3'd2: gpr[q_dst_reg]<=creg2;
              3'd3: gpr[q_dst_reg]<=creg3;
              default: gpr[q_dst_reg]<=creg4;
            endcase
          end
          else if (q_sysop==SYS_MOVSREG_FROM) begin
            // MOV r/m16, Sreg -> write the selector value (zero-extended) to reg.
            flags_we=1'b0;
            gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], {16'd0, seg_sel[q_sys_sreg]}, 3'd2, 1'b0);
          end
          else if (q_sysop==SYS_STR) begin
            // STR r/m16 -> write the current TR selector (zero-extended) to reg.
            flags_we=1'b0;
            gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], {16'd0, tr_sel}, 3'd2, 1'b0);
          end
          else if (q_sysop==SYS_MOVSREG_TO) begin
            // REAL-MODE MOV Sreg, r16: selector = value; hidden base = sel<<4.
            // Real mode does no descriptor / protection checks (no GDT consulted);
            // the hidden attr stays the present R/W data default.
            flags_we=1'b0;
            seg_sel [q_sys_sreg] <= gpr[q_src_reg][15:0];
            seg_base[q_sys_sreg] <= {12'd0, gpr[q_src_reg][15:0], 4'd0};
            seg_limit[q_sys_sreg]<= 32'h0000_FFFF;
            seg_attr [q_sys_sreg]<= 8'h93;
          end
          else if (q_sysop==SYS_LJMP) begin
            // REAL-MODE far jump: CS.sel = sel, CS.base = sel<<4, EIP = off.
            flags_we=1'b0;
            seg_sel [SG_CS] <= q_ljmp_sel;
            seg_base[SG_CS] <= {12'd0, q_ljmp_sel, 4'd0};
            seg_attr[SG_CS] <= 8'h9B;
            new_eip = q_ljmp_off;
          end
          else begin
            unique case (q_kind)
              K_ALU: begin
                if (q_is_lea) gpr[q_dst_reg]<=q_ea;
                else if (q_is_pop && q_mem_write) begin
                  // POP m: stack value (mem_load_data) -> memory dest; ESP += w.
                  do_store=1'b1; do_retire=1'b0;
                end else if (q_is_pop) begin
                  gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], wmask(mem_load_data,q_w), q_w, 1'b0);
                  if (q_dst_reg!=R_ESP) gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                end else if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else if (q_writes_reg) gpr[q_dst_reg]<=reg_merge(dst_cur, alu_out, q_w, q_dst_high8);
              end

              K_SHIFT: begin
                // count masked to 0 -> NO flag change, NO value change (QEMU).
                if (sh_cnt==6'd0) begin
                  flags_we=1'b0;
                  if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                end else begin
                  if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                  else gpr[q_dst_reg]<=reg_merge(dst_cur, sh_out, q_w, q_dst_high8);
                  begin
                    logic [31:0] fl; logic ofb;
                    fl=eflags;
                    if (q_shrot inside {3'd4,3'd5,3'd6,3'd7}) begin
                      // SHL/SHR/SAR: SF/ZF/PF from result, AF=0, CF & OF per QEMU
                      // (CC_DST=result, CC_SRC=shm1): OF = MSB(shm1) ^ MSB(result).
                      fl=eflags & 32'hFFFF_F72A;
                      fl[0]=sh_cfout; fl[2]=parity8(sh_out[7:0]); fl[4]=1'b0;
                      fl[6]=(wmask(sh_out,q_w)==32'd0); fl[7]=sbit(sh_out,q_w);
                      fl[11]=sbit(sh_shm1,q_w) ^ sbit(sh_out,q_w);
                      fl[1]=1'b1;
                    end else begin
                      // ROL/ROR/RCL/RCR: only CF and OF change.
                      unique case (q_shrot)
                        3'd0: ofb = sbit(sh_out,q_w) ^ sh_out[0];               // ROL: MSB^LSB(res)
                        3'd1: ofb = sbit(sh_out,q_w) ^ sbit2(sh_out,q_w);       // ROR: MSB^(MSB-1)(res)
                        default: ofb = sbit(sh_val,q_w) ^ sbit(sh_out,q_w);     // RCL/RCR: MSB(src)^MSB(res)
                      endcase
                      fl[0]=sh_cfout; fl[11]=ofb; fl[1]=1'b1;
                    end
                    eflags<=fl;
                  end
                  flags_we=1'b0;
                end
              end

              K_SHLDRD: begin
                logic [5:0] cnt; logic [31:0] r, shm1;
                cnt = q_shift_cl ? {1'b0,gpr[R_ECX][4:0]} : {1'b0,q_shift_imm};
                if (cnt==6'd0) flags_we=1'b0;
                else begin
                  r = shld_result(q_shrd, dst_cur, reg_read(q_src_reg,q_w,1'b0), cnt, q_w);
                  // shm1 = dst shifted by (count-1) (same direction) = QEMU CC_SRC.
                  shm1 = q_shrd ? (wmask(dst_cur,q_w) >> (cnt-6'd1))
                                : wmask(wmask(dst_cur,q_w) << (cnt-6'd1), q_w);
                  gpr[q_dst_reg]<=reg_merge(dst_cur, r, q_w, 1'b0);
                  begin logic [31:0] fl;
                    fl=eflags & 32'hFFFF_F72A;
                    fl[0]=shld_cf(q_shrd, dst_cur, cnt, q_w); fl[2]=parity8(r[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(r,q_w)==32'd0); fl[7]=sbit(r,q_w);
                    fl[11]=sbit(shm1,q_w)^sbit(r,q_w); fl[1]=1'b1;
                    eflags<=fl;
                  end
                  flags_we=1'b0;
                end
              end

              K_MULDIV: begin
                logic [31:0] srcv;
                srcv = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,q_src_high8);
                unique case (q_md)
                  3'd4: begin // MUL (unsigned)
                    logic [63:0] p; logic [31:0] lo; logic ovf; logic [31:0] fl;
                    if (q_w==3'd1)      p={48'd0, ({8'd0,gpr[R_EAX][7:0]}*{8'd0,srcv[7:0]})};
                    else if (q_w==3'd2) p={32'd0, ({16'd0,gpr[R_EAX][15:0]}*{16'd0,srcv[15:0]})};
                    else                p={32'd0,gpr[R_EAX]}*{32'd0,srcv};
                    if (q_w==3'd1) begin lo={24'd0,p[7:0]};  ovf=(p[15:8]!=8'd0);  gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; end
                    else if (q_w==3'd2) begin lo={16'd0,p[15:0]}; ovf=(p[31:16]!=16'd0);
                      gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; gpr[R_EDX]<={gpr[R_EDX][31:16],p[31:16]}; end
                    else begin lo=p[31:0]; ovf=(p[63:32]!=32'd0); gpr[R_EAX]<=p[31:0]; gpr[R_EDX]<=p[63:32]; end
                    // QEMU compute_all_mul: ZF/SF/PF from low result, AF=0, CF=OF=ovf
                    fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                    fl[0]=ovf; fl[11]=ovf; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                    eflags<=fl; flags_we=1'b0;
                  end
                  3'd5: begin // IMUL one-operand (signed)
                    logic signed [63:0] p; logic [31:0] lo; logic ovf; logic [31:0] fl;
                    if (q_w==3'd1)      p=$signed({{8{srcv[7]}},srcv[7:0]}) * $signed({{8{gpr[R_EAX][7]}},gpr[R_EAX][7:0]});
                    else if (q_w==3'd2) p=$signed({{16{srcv[15]}},srcv[15:0]}) * $signed({{16{gpr[R_EAX][15]}},gpr[R_EAX][15:0]});
                    else                p=$signed(srcv) * $signed(gpr[R_EAX]);
                    if (q_w==3'd1) begin lo={24'd0,p[7:0]};  ovf=($signed(p)!=$signed({{56{p[7]}},p[7:0]}));   gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; end
                    else if (q_w==3'd2) begin lo={16'd0,p[15:0]}; ovf=($signed(p)!=$signed({{48{p[15]}},p[15:0]}));
                      gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; gpr[R_EDX]<={gpr[R_EDX][31:16],p[31:16]}; end
                    else begin lo=p[31:0]; ovf=($signed(p)!=$signed({{32{p[31]}},p[31:0]})); gpr[R_EAX]<=p[31:0]; gpr[R_EDX]<=p[63:32]; end
                    fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                    fl[0]=ovf; fl[11]=ovf; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                    eflags<=fl; flags_we=1'b0;
                  end
                  3'd6: begin // DIV
                    if (q_w==3'd1) begin
                      logic [15:0] num; logic [15:0] qq, rr;
                      num=gpr[R_EAX][15:0]; qq=num/{8'd0,srcv[7:0]}; rr=num%{8'd0,srcv[7:0]};
                      gpr[R_EAX]<={gpr[R_EAX][31:16], rr[7:0], qq[7:0]};
                    end else if (q_w==3'd2) begin
                      logic [31:0] num,qq,rr;
                      num={gpr[R_EDX][15:0],gpr[R_EAX][15:0]}; qq=num/{16'd0,srcv[15:0]}; rr=num%{16'd0,srcv[15:0]};
                      gpr[R_EAX]<={gpr[R_EAX][31:16], qq[15:0]};
                      gpr[R_EDX]<={gpr[R_EDX][31:16], rr[15:0]};
                    end else begin
                      logic [63:0] num,qq,rr;
                      num={gpr[R_EDX],gpr[R_EAX]}; qq=num/{32'd0,srcv}; rr=num%{32'd0,srcv};
                      gpr[R_EAX]<=qq[31:0]; gpr[R_EDX]<=rr[31:0];
                    end
                    flags_we=1'b0;
                  end
                  default: begin // IDIV /7
                    if (q_w==3'd1) begin
                      logic signed [15:0] num,den,qq,rr;
                      num=$signed(gpr[R_EAX][15:0]); den=$signed({{8{srcv[7]}},srcv[7:0]});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<={gpr[R_EAX][31:16], rr[7:0], qq[7:0]};
                    end else if (q_w==3'd2) begin
                      logic signed [31:0] num,den,qq,rr;
                      num=$signed({gpr[R_EDX][15:0],gpr[R_EAX][15:0]}); den=$signed({{16{srcv[15]}},srcv[15:0]});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<={gpr[R_EAX][31:16], qq[15:0]};
                      gpr[R_EDX]<={gpr[R_EDX][31:16], rr[15:0]};
                    end else begin
                      logic signed [63:0] num,den,qq,rr;
                      num=$signed({gpr[R_EDX],gpr[R_EAX]}); den=$signed({{32{srcv[31]}},srcv});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<=qq[31:0]; gpr[R_EDX]<=rr[31:0];
                    end
                    flags_we=1'b0;
                  end
                endcase
              end

              K_IMUL2: begin
                logic [31:0] s1,s2,lo; logic ov; logic [31:0] fl;
                s1 = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,1'b0);
                s2 = q_imul_3op ? q_imul_imm : reg_read(q_dst_reg,q_w,1'b0);
                if (q_w==3'd2) begin logic signed [31:0] pp;
                  pp=$signed({{16{s1[15]}},s1[15:0]})*$signed({{16{s2[15]}},s2[15:0]});
                  lo={16'd0,pp[15:0]};
                  gpr[q_dst_reg]<=reg_merge(dst_cur, {16'd0,pp[15:0]}, q_w, 1'b0);
                  ov=(pp!=$signed({{16{pp[15]}},pp[15:0]}));
                end else begin logic signed [63:0] pp; pp=$signed(s1)*$signed(s2);
                  lo=pp[31:0];
                  gpr[q_dst_reg]<=reg_merge(dst_cur, pp[31:0], q_w, 1'b0);
                  ov=(pp!=$signed({{32{pp[31]}},pp[31:0]}));
                end
                // QEMU CC_OP_MUL: ZF/SF/PF from low result, AF=0, CF=OF=ov.
                fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                fl[0]=ov; fl[11]=ov; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                eflags<=fl;
                flags_we=1'b0;
              end

              K_EXT: begin
                logic [31:0] s,r;
                s = q_mem_read ? mem_load_data : reg_read(q_src_reg, q_ext_srcw, q_src_high8);
                if (q_ext_srcw==3'd1) r = q_ext_signed ? {{24{s[7]}},s[7:0]} : {24'd0,s[7:0]};
                else                  r = q_ext_signed ? {{16{s[15]}},s[15:0]} : {16'd0,s[15:0]};
                // Destination width follows the operand-size: a 0x66-prefixed
                // MOVZX/MOVSX (66 0F B6/B7/BE/BF) writes a 16-bit register and
                // must PRESERVE [31:16]; the unprefixed form writes the full 32.
                gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], r, q_w, 1'b0);
              end

              K_SETCC: begin
                if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], {31'd0,cond_true(q_cc,eflags)}, 3'd1, q_dst_high8);
                flags_we=1'b0;
              end

              K_BITTEST: begin
                logic [4:0] idx; logic bv; logic [31:0] cur,res;
                // Register-direct / immediate bit index is taken modulo the
                // operand size: mod 16 for a 0x66-prefixed (16-bit) operand,
                // mod 32 otherwise. (Memory-operand bit-string forms, which use
                // the full index to address a different byte, are not decoded
                // here — they HALT — so masking the index is correct for all
                // forms reaching this block.)
                cur=wmask(dst_cur,q_w);
                idx = q_bit_imm ? q_imm[4:0] : reg_read(q_src_reg,3'd4,1'b0)[4:0];
                if (q_w==3'd2) idx = {1'b0, idx[3:0]};   // mod 16
                bv = cur[idx];
                unique case (q_bit_op)
                  3'd5: res=cur | (32'd1<<idx);
                  3'd6: res=cur & ~(32'd1<<idx);
                  3'd7: res=cur ^ (32'd1<<idx);
                  default: res=cur;
                endcase
                // Modify forms (BTS/BTR/BTC) write the destination at operand
                // width, preserving [31:16] for the 16-bit form.
                if (q_writes_reg) gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], res, q_w, 1'b0);
                begin logic [31:0] fl; fl=eflags; fl[0]=bv; fl[1]=1'b1; eflags<=fl; end
                flags_we=1'b0;
              end

              K_BITSCAN: begin
                logic [31:0] s, idx; logic zero; int hi;
                // Operand-size aware: a 0x66-prefixed BSF/BSR (66 0F BC/BD)
                // operates on the low 16 bits, computes ZF from [15:0], and
                // writes a 16-bit destination index preserving [31:16].
                s = wmask(q_mem_read ? mem_load_data : reg_read(q_src_reg,q_w,1'b0), q_w);
                hi = (q_w==3'd2) ? 15 : 31;
                zero=(s==32'd0); idx=32'd0;
                if (!q_shrd) begin for (int i=hi;i>=0;i--) if (s[i]) idx=i[31:0]; end // BSF lowest
                else         begin for (int i=0;i<=hi;i++) if (s[i]) idx=i[31:0]; end // BSR highest
                if (!zero) gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], idx, q_w, 1'b0);  // dest unchanged on src==0 (QEMU)
                // QEMU sets CC_OP_LOGIC with CC_DST = the SOURCE operand:
                //   ZF=(src==0) [defined]; SF=MSB(src); PF=parity(src); CF=OF=AF=0.
                begin logic [31:0] fl; fl=eflags & 32'hFFFF_F72A;
                  fl[0]=1'b0; fl[2]=parity8(s[7:0]); fl[4]=1'b0;
                  fl[6]=zero; fl[7]=sbit(s,q_w); fl[11]=1'b0; fl[1]=1'b1; eflags<=fl; end
                flags_we=1'b0;
              end

              K_XCHG: begin
                if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else begin
                  logic [31:0] a,b;
                  a=reg_read(q_dst_reg,q_w,q_dst_high8); b=reg_read(q_src_reg,q_w,q_src_high8);
                  gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], b, q_w, q_dst_high8);
                  gpr[q_src_reg]<=reg_merge(gpr[q_src_reg], a, q_w, q_src_high8);
                end
                flags_we=1'b0;
              end

              K_BSWAP: begin logic [31:0] v; v=gpr[q_dst_reg];
                gpr[q_dst_reg]<={v[7:0],v[15:8],v[23:16],v[31:24]}; end

              K_CONV: begin
                if (!q_conv_cdq) begin
                  if (q_w==3'd2) gpr[R_EAX]<={gpr[R_EAX][31:16], {8{gpr[R_EAX][7]}}, gpr[R_EAX][7:0]};
                  else           gpr[R_EAX]<={{16{gpr[R_EAX][15]}}, gpr[R_EAX][15:0]};
                end else begin
                  if (q_w==3'd2) gpr[R_EDX]<={gpr[R_EDX][31:16], {16{gpr[R_EAX][15]}}};
                  else           gpr[R_EDX]<={32{gpr[R_EAX][31]}};
                end
              end

              K_STKMISC: begin
                unique case (q_sm)
                  SM_LAHF: gpr[R_EAX]<={gpr[R_EAX][31:16], eflags[7:0], gpr[R_EAX][7:0]};
                  SM_SAHF: begin logic [31:0] fl; fl=eflags;
                    fl[7]=gpr[R_EAX][15]; fl[6]=gpr[R_EAX][14]; fl[4]=gpr[R_EAX][12];
                    fl[2]=gpr[R_EAX][10]; fl[0]=gpr[R_EAX][8]; fl[1]=1'b1; eflags<=fl; end
                  SM_PUSHF: begin do_store=1'b1; do_retire=1'b0; end
                  SM_POPF: begin
                    // EFLAGS <- [ESP], USER-MODE mask: status flags + DF/TF/AC/
                    // ID/NT writable; IF/IOPL/VM/RF preserved (QEMU CPL=3 popf).
                    // writable = CF|PF|AF|ZF|SF|TF|DF|OF|NT|AC|ID = 0x244DD5.
                    eflags<=((mem_load_data & 32'h0024_4DD5) |
                             (eflags & ~32'h0024_4DD5)) | 32'h0000_0002;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                  end
                  // LEAVE: ESP<-EBP (full, stack-addr width), then pop (E)BP.
                  // A 0x66 LEAVE pops a 16-bit BP (preserve EBP[31:16]) and the
                  // stack slot is 2 bytes wide, so ESP = old EBP + 2.
                  SM_LEAVE: begin
                    gpr[R_EBP]<=reg_merge(gpr[R_EBP], wmask(mem_load_data,q_w), q_w, 1'b0);
                    gpr[R_ESP]<=gpr[R_EBP]+{28'd0,q_w};
                  end
                  SM_PUSHA, SM_POPA: begin do_retire=1'b0; state<=S_USEQ; step<=4'd0; end
                  default: ;
                endcase
                flags_we=1'b0;
              end

              K_STR: begin
                // one element; with REP iterate via S_USEQ keeping pc fixed.
                logic [31:0] cx;
                logic        rep_active, last_iter, cmp_term, store_needed;
                cx = gpr[R_ECX];
                rep_active = (q_rep || q_repne);
                // ECX==0 degenerate REP: no element, just advance EIP, one record.
                if (rep_active && cx==32'd0) begin
                  // no memory effect; retire as a no-op (handled by do_retire below)
                  do_retire=1'b1; flags_we=1'b0; new_eip=next_eip;
                end else begin
                  // execute one element this cycle
                  store_needed = q_str_storedi; // MOVS/STOS write [EDI]
                  // update pointers / flags / regs for this element:
                  if (q_str_loadsi)  gpr[R_ESI]<=gpr[R_ESI]+str_step;
                  if (q_str_storedi) gpr[R_EDI]<=gpr[R_EDI]+str_step;
                  if (q_str_scandi)  gpr[R_EDI]<=gpr[R_EDI]+str_step;
                  if (q_st==ST_LODS) gpr[R_EAX]<=reg_merge(gpr[R_EAX], wmask(mem_load_data,q_w), q_w, 1'b0);
                  if (q_str_scandi) begin eflags<=str_flags; end
                  flags_we=1'b0;

                  if (rep_active) begin
                    cx = cx - 32'd1;
                    gpr[R_ECX]<=cx;
                    // termination: ECX reaches 0, or (REPE/REPNE) ZF condition.
                    cmp_term = 1'b0;
                    if (q_str_scandi) begin
                      if (q_rep)   cmp_term = (str_flags[6]==1'b0); // REPE: stop when ZF=0
                      if (q_repne) cmp_term = (str_flags[6]==1'b1); // REPNE: stop when ZF=1
                    end
                    last_iter = (cx==32'd0) || cmp_term;
                    // Each REP iteration is its OWN retire record at the same PC.
                    // We retire here and, if not last, re-enter at the same PC.
                    if (last_iter) new_eip = next_eip;
                    else           new_eip = q_pc;   // stay on the REP instruction
                  end else begin
                    new_eip = next_eip;
                  end

                  if (store_needed) begin do_store=1'b1; do_retire=1'b0; end
                  else do_retire=1'b1;

                  // latch pre-increment [EDI] + data for the store stage (EDI is
                  // being incremented this cycle via NBA, so S_STORE must not
                  // re-read gpr[EDI]).
                  str_store_addr <= gpr[R_EDI];
                  str_store_data <= str_wdata;
                  // remember the eip we want after this element commit
                  str_next_eip <= new_eip;
                end
              end

              K_CTRL: begin
                unique case (q_ct)
                  CT_CALLREL, CT_CALLIND: begin do_store=1'b1; do_retire=1'b0; end
                  CT_JMPIND: new_eip = call_target;
                  // Near RET: pop the return IP at operand width. A 0x66 RET
                  // pops a 16-bit IP (EIP truncated to 16 bits) and ESP+=2.
                  CT_RETN: begin
                    new_eip = (q_w==3'd2) ? {16'd0,mem_load_data[15:0]} : mem_load_data;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                  end
                  CT_RETN_IMM: begin
                    new_eip = (q_w==3'd2) ? {16'd0,mem_load_data[15:0]} : mem_load_data;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w}+{16'd0,q_ret_imm};
                  end
                  CT_LOOP, CT_LOOPE, CT_LOOPNE: begin
                    // 0x67 address-size: the count register is CX (low 16):
                    // decrement preserves ECX[31:16] and the taken test is CX!=0.
                    logic [31:0] cx; logic take; logic zero_after;
                    if (q_cnt16) begin
                      cx = {gpr[R_ECX][31:16], (gpr[R_ECX][15:0]-16'd1)};
                      zero_after = (cx[15:0]==16'd0);
                    end else begin
                      cx = gpr[R_ECX]-32'd1;
                      zero_after = (cx==32'd0);
                    end
                    gpr[R_ECX]<=cx;
                    take=~zero_after;
                    if (q_ct==CT_LOOPE)  take=take & eflags[6];
                    if (q_ct==CT_LOOPNE) take=take & ~eflags[6];
                    new_eip = take ? (next_eip+q_rel) : next_eip;
                    flags_we=1'b0;
                  end
                  CT_JECXZ: begin
                    logic cx_zero;
                    cx_zero = q_cnt16 ? (gpr[R_ECX][15:0]==16'd0) : (gpr[R_ECX]==32'd0);
                    new_eip=cx_zero?(next_eip+q_rel):next_eip; flags_we=1'b0;
                  end
                  default: ;
                endcase
              end
            endcase
          end

          // commit (non-store, non-microseq path)
          if (do_retire) begin
            if (flags_we) eflags<=flags_val;
            if (q_is_branch && q_branch_taken) eip<=next_eip+q_rel;
            else if (q_kind==K_STR) eip<=new_eip;  // string single (non-store) / ECX==0
            else eip<=new_eip;
            retire_valid<=1'b1;
            state<=S_PIPE;   // re-enter fast path
          end else if (do_store) begin
            state<=S_STORE;
          end
        end

        // -------------------------------------------------------------------
        S_STORE: begin
          if (mem_ack) begin
            // M5 finding [med]: a STORE mutates the D-cache (read-allocate write-back
            // allocates/updates LRU) but adds NO miss penalty (oracle p5_mem:
            // `if (!hit && !store) pending += dmiss` — stores skip the penalty). A
            // misaligned store still costs +3. Run the LRU SM so a line warmed by a
            // store is later seen RESIDENT by a load (the divergent-state bug).
            if (cycle_mode) begin
              logic [31:0] sa;
              sa = (q_kind==K_STR) ? str_store_addr : st_addr;
              dc_access(sa);
              if (sa[1:0] != 2'b00) pending_mem_pen <= pending_mem_pen + P5_MISALIGN;
            end
            unique case (q_kind)
              K_CTRL: begin // CALL: push done, set EIP (width-aware ESP adjust)
                gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w}; eip<=call_target;
                retire_valid<=1'b1; state<=S_PIPE;
              end
              K_XCHG: begin // XCHG r/m,r mem: reg <- old mem
                gpr[q_src_reg]<=reg_merge(gpr[q_src_reg], wmask(mem_load_data,q_w), q_w, q_src_high8);
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end
              K_STKMISC: begin // PUSHF
                gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w}; eip<=next_eip;
                retire_valid<=1'b1; state<=S_PIPE;
              end
              K_STR: begin // MOVS/STOS element stored
                eip<=str_next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end
              default: begin
                if (q_is_push) gpr[R_ESP]<=gpr[R_ESP]-{28'd0,q_w};
                if (q_is_pop)  gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};  // POP m
                if (q_writes_flags && q_kind==K_ALU) eflags<=flags_out;
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end
            endcase
          end
        end

        // -------------------------------------------------------------------
        // S_USEQ: PUSHA / POPA micro-sequence (8 word transfers).
        S_USEQ: begin
          if (mem_ack) begin
            if (q_sm==SM_PUSHA) begin
              // push order: EAX,ECX,EDX,EBX,ESP(orig),EBP,ESI,EDI
              if (step==4'd7) begin
                gpr[R_ESP]<=pusha_esp - (32'd4*8);
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end else step<=step+4'd1;
            end else begin // POPA: pop EDI,ESI,EBP,(skip ESP),EBX,EDX,ECX,EAX
              unique case (step)
                4'd0: gpr[R_EDI]<=mem_rdata;
                4'd1: gpr[R_ESI]<=mem_rdata;
                4'd2: gpr[R_EBP]<=mem_rdata;
                4'd3: ; // skip ESP slot
                4'd4: gpr[R_EBX]<=mem_rdata;
                4'd5: gpr[R_EDX]<=mem_rdata;
                4'd6: gpr[R_ECX]<=mem_rdata;
                default: gpr[R_EAX]<=mem_rdata;
              endcase
              if (step==4'd7) begin
                gpr[R_ESP]<=gpr[R_ESP]+(32'd4*8);
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end else step<=step+4'd1;
            end
          end
        end

        // -------------------------------------------------------------------
        // M2S.1 — S_LGDT: read the 6-byte LGDT/LIDT pseudo-descriptor (limit[2] +
        // base[4]) from memory at q_ea via two word reads, then load GDTR/IDTR.
        // beat 0: word @q_ea   = { base[15:0], limit[15:0] }
        // beat 1: word @q_ea+4 = { ........., base[31:16] }
        // -------------------------------------------------------------------
        S_LGDT: begin
          if (mem_ack) begin
            if (!seg_step) begin
              gdt_lo <= mem_rdata;     // limit[15:0] | base[15:0]
              seg_step <= 1'b1;
            end else begin
              // base[31:16] is the low half of the second word.
              logic [31:0] nb; logic [15:0] nl;
              nl = gdt_lo[15:0];
              nb = {mem_rdata[15:0], gdt_lo[31:16]};
              if (q_sysop==SYS_LGDT) begin gdt_base<=nb; gdt_limit<=nl; end
              else begin idt_base<=nb; idt_limit<=nl; end
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
            end
          end
        end

        // -------------------------------------------------------------------
        // M2S.1 — S_SEGLD: PROTECTED-mode MOV Sreg, r16. Read the 8-byte GDT
        // descriptor at gdt_base + (sel & ~7) via two word reads, decode the
        // hidden base/limit/attr, and load the segment. The protection DECISION
        // (present/type/DPL + null-SS/CS rules, CPL=cpl_r, RPL=sel[1:0]) is
        // genuinely COMPUTED here via seg_load_fault(); fault *delivery* through
        // the IDT is M2S.3, so a raised decision can only HALT loudly (it never
        // silently mis-loads). The pseg corpus loads only clean descriptors, so
        // the decision is always "no fault" and this never halts — but a wrong/
        // absent/mis-typed descriptor WOULD now be caught here (spec §3).
        // -------------------------------------------------------------------
        S_SEGLD: begin
          if (mem_ack) begin
            logic [15:0] msel;
            logic        mnull;
            msel  = gpr[q_src_reg][15:0];
            mnull = (msel[15:3] == 13'd0);
            // M2S.3 — selector index past the GDT limit -> #GP(13) carrying the
            // selector as the error code (the descriptor read was out of bounds;
            // we discard it). A NULL selector (idx 0) skips the limit check (a
            // null load into DS/ES/FS/GS is legal). Checked on beat 0 so we
            // deliver before consuming the (garbage) descriptor.
            if (!seg_step && !mnull &&
                ({16'd0, msel[15:3], 3'd0} + 32'd7 > {16'd0, gdt_limit})) begin
              start_fault(8'd13, 1'b1, {16'd0, msel}, q_pc);
              seg_step<=1'b0;
            end else if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc;
              logic [7:0]  attr;
              logic        is_ss;
              desc  = {mem_rdata, gdt_lo};
              attr  = desc_attr(desc);
              is_ss = (q_sys_sreg == 3'(SG_SS));
              // PROTECTION DECISION (M2S.1) -> now DELIVERED through the IDT (M2S.3).
              if (seg_load_fault(1'b0, is_ss, msel, attr, cpl_r)) begin
                // #NP/#SS/#GP — error code = selector (idx<<3 | TI | EXT=0).
                start_fault(seg_fault_vec(1'b0, is_ss, msel, attr), 1'b1,
                            {16'd0, msel[15:3], 3'd0}, q_pc);
                seg_step<=1'b0;
              end else begin
                seg_sel  [q_sys_sreg] <= msel;
                seg_base [q_sys_sreg] <= desc_base(desc);
                seg_limit[q_sys_sreg] <= desc_limit(desc);
                seg_attr [q_sys_sreg] <= attr;
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
              end
            end
          end
        end

        // -------------------------------------------------------------------
        // M2S.1 — S_LJMP: PROTECTED-mode far JMP. Read the CS descriptor from the
        // GDT, load CS.sel/base/limit/attr, derive CPL=CS.RPL, and set EIP to the
        // jump offset. This is the second half of the real->protected transition
        // (the CR0.PE write retired separately): its own retire record, switching
        // to 32-bit PM. The CS protection DECISION (present/code-type/null) is
        // COMPUTED via seg_load_fault(); delivery is M2S.3 (a raised decision
        // HALTs). The pseg far jump targets a present 32-bit code seg => no fault.
        // -------------------------------------------------------------------
        S_LJMP: begin
          if (mem_ack) begin
            if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc;
              logic [7:0]  attr;
              desc = {mem_rdata, gdt_lo};
              attr = desc_attr(desc);
              // M2S.4 — a far JMP whose target descriptor is a SYSTEM descriptor
              // (S=0) is a HARDWARE TASK SWITCH (target = available TSS type 0x9 /
              // busy TSS 0xB) or a task-gate jump (type 0x5). The full task switch
              // (save outgoing state to the current TSS, load the incoming TSS
              // state, toggle busy/NT/back-link, reload CR3/LDTR) is the gnarliest
              // M2S.4 piece and is DEFERRED — HALT cleanly here (a loud, honest
              // "not implemented") rather than mis-delivering a spurious #GP. The
              // ptask stretch corpus stops exactly here (its RTL diff is NOT gated;
              // the golden self-diff + step-5d validation cover the oracle side).
              if (!desc_s(attr)) begin
                state<=S_HALT; seg_step<=1'b0;
              end else if (seg_load_fault(1'b1, 1'b0, q_ljmp_sel, attr, cpl_r)) begin
                // #GP/#NP on a far-jump CS load -> DELIVER (error code = selector).
                start_fault(seg_fault_vec(1'b1, 1'b0, q_ljmp_sel, attr), 1'b1,
                            {16'd0, q_ljmp_sel[15:3], 3'd0}, q_pc);
                seg_step<=1'b0;
              end else begin
                seg_sel  [SG_CS] <= q_ljmp_sel;
                seg_base [SG_CS] <= desc_base(desc);
                seg_limit[SG_CS] <= desc_limit(desc);
                seg_attr [SG_CS] <= attr;
                cpl_r    <= q_ljmp_sel[1:0];  // CPL = CS.RPL after a far jump
                cs_d <= desc[54];   // D/B bit: 1 => 32-bit default operand/addr size
                eip<=q_ljmp_off; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
              end
            end
          end
        end

        // ===================================================================
        // M2S.3 — IDT DELIVERY micro-sequence (gated sys_mode). Reached from a
        // software INT/INT3/INTO/UD2 (S_DECODE) or a hardware fault DECISION
        // (S_SEGLD/S_LJMP #GP/#NP/#SS, S_WALK #PF — via start_fault). Reads the
        // gate, reads the gate's CS descriptor, pushes the exception frame, then
        // loads CS:EIP and retires ONCE (q_pc = the faulting/INT instruction's
        // PC, post-state = the pushed frame + new CS:EIP + gated IF/TF).
        // SAME-PRIVILEGE only: the frame is pushed on the current SS:ESP (cross-
        // privilege stack switch via the TSS is M2S.4).
        //
        // GATE PROTECTION CHECKS DEFERRED (M2S.4 / negative tests): this path does
        // NOT check the gate's Present bit (an absent gate -> #NP(v*8+2)), the gate
        // DPL for a software INT n (IA-32 6.12.1.2 requires gate.DPL >= CPL else
        // #GP(v*8+2); HW faults/INT3/INTO bypass this), or the target CS descriptor
        // via seg_load_fault (a bad/absent CS -> #GP/#NP). The CPL0 corpus uses
        // all-present DPL0 gates and a present 32-bit code CS (0x08), so none can
        // fire; a fault DURING delivery escalates to #DF, which (with cross-priv)
        // is M2S.4. The gate is loaded/CS-descriptor read unconditionally here.
        // ===================================================================
        // S_INT_GATE: read IDT[vec] (8 bytes @ idt_base + vec*8, 2 word reads).
        //   word0 = {selector[15:0], offset[15:0]}
        //   word1 = {offset[31:16], attr[7:0], 8'b0}  (attr at bits[15:8])
        // attr[3:0]: 0xE = 32-bit interrupt gate (clears IF), 0xF = trap gate.
        S_INT_GATE: begin
          if (mem_ack) begin
            if (int_step == 3'd0) begin
              int_lo <= mem_rdata; int_step <= 3'd1;
            end else begin
              logic [7:0] gattr;
              gattr        = mem_rdata[15:8];
              int_gate_off <= {mem_rdata[31:16], int_lo[15:0]};
              int_gate_sel <= int_lo[31:16];
              int_gate_trap<= gattr[0];   // 0xF trap -> leave IF; 0xE int -> clear IF
              int_step     <= 3'd0;
              // M2S.4 GATE PROTECTION (deferred from M2S.3):
              //   (1) gate not Present -> #NP(vec*8 + IDT bit). The error code for
              //       an IDT-sourced fault is (vec<<3)|2 (the IDT/EXT bits).
              //   (2) SOFTWARE INT n/INT3/INTO with gate.DPL < CPL -> #GP(vec*8+2)
              //       (IA-32 6.12.1.2; HW faults bypass this — int_sw==0).
              // A fault HERE is a nested delivery fault; we re-enter S_INT_GATE for
              // the new vector. (A second nesting would escalate toward #DF; the
              // corpus never triggers it, so the single re-vector is sufficient and
              // honest — full #DF chaining is a documented follow-on.)
              if (!gattr[7]) begin
                start_fault(8'd11, 1'b1, {21'd0, int_vec, 3'b010}, int_src_pc);
              end else if (int_sw && (gattr[6:5] < cpl_r)) begin
                start_fault(8'd13, 1'b1, {21'd0, int_vec, 3'b010}, int_src_pc);
              end else begin
                state      <= S_INT_CS;
              end
            end
          end
        end

        // S_INT_CS: read the gate's CS descriptor (8 bytes @ gdt_base + sel&~7).
        // Load the hidden CS base/limit/attr (like a far-jump CS load). The new
        // CPL = the target CS.DPL (a conforming code seg keeps CPL; a non-
        // conforming code seg sets CPL = DPL). M2S.4:
        //   - TARGET CS PROTECTION: present (else #NP), is a code segment, and
        //     DPL <= CPL (a more-privileged or equal handler) -> else #GP.
        //   - CROSS-PRIV: when the target CS.DPL < CPL the handler is MORE
        //     privileged: capture old SS:ESP, set the target CPL, and route to
        //     S_INT_TSS to load SS:ESP from TSS.ssN:espN before the push. SAME-
        //     PRIV (DPL == CPL): push on the current stack as in M2S.3.
        S_INT_CS: begin
          if (mem_ack) begin
            if (int_step == 3'd0) begin
              int_lo <= mem_rdata; int_step <= 3'd1;
            end else begin
              logic [63:0] desc;
              logic [7:0]  cattr;
              logic [1:0]  tgt_dpl;
              logic        cs_bad;
              desc    = {mem_rdata, int_lo};
              cattr   = desc_attr(desc);
              tgt_dpl = desc_dpl(cattr);
              // target CS must be present, a code segment, DPL <= CPL.
              cs_bad  = !desc_present(cattr) || !desc_s(cattr) ||
                        !seg_is_code(cattr) || (tgt_dpl > cpl_r);
              if (cs_bad) begin
                // bad target CS -> #NP(sel) if not present, else #GP(sel). Error
                // code = the gate's code selector with the IDT/EXT bits.
                int_step <= 3'd0;
                start_fault(desc_present(cattr) ? 8'd13 : 8'd11, 1'b1,
                            {16'd0, int_gate_sel[15:3], 3'b010}, int_src_pc);
              end else begin
                seg_sel  [SG_CS] <= int_gate_sel;
                seg_base [SG_CS] <= desc_base(desc);
                seg_limit[SG_CS] <= desc_limit(desc);
                seg_attr [SG_CS] <= cattr;
                cpl_r            <= tgt_dpl;     // CPL = target CS.DPL
                cs_d             <= desc[54];
                int_step         <= 3'd0;
                if (tgt_dpl < cpl_r) begin
                  // CROSS-PRIV: freeze the interrupted task's CS:SS:ESP for the
                  // frame (seg_sel[] here still hold the OLD values), record the
                  // target CPL, and read TSS.ssN:espN.
                  xpl_active   <= 1'b1;
                  int_old_cs   <= seg_sel[SG_CS];
                  int_old_ss   <= seg_sel[SG_SS];
                  int_old_esp  <= gpr[R_ESP];
                  int_new_cpl  <= tgt_dpl;
                  state        <= S_INT_TSS;
                end else begin
                  xpl_active   <= 1'b0;          // SAME-PRIV: push on current stack
                  state        <= S_INT_PUSH;
                end
              end
            end
          end
        end

        // S_INT_PUSH: push the exception frame (32-bit gate), one word per beat,
        // at descending stack addresses (so the handler sees, low->high:
        // [errcode], EIP, CS, EFLAGS). Beat 0 EFLAGS @ ESP-4, 1 CS @ ESP-8,
        // 2 EIP @ ESP-12, 3 errcode @ ESP-16 (only when int_has_err). On the
        // final beat: ESP -= frame size, load EIP <- gate offset, clear IF/TF on
        // an interrupt gate (trap gate leaves them), and RETIRE the delivery.
        S_INT_PUSH: begin
          if (mem_ack) begin
            logic last;
            // last push beat: SAME-PRIV = 2 (EIP) / 3 (errcode); CROSS-PRIV = 4
            // (EIP) / 5 (errcode), since the larger frame adds old SS + old ESP.
            if (xpl_active)
              last = int_has_err ? (int_step == 3'd5) : (int_step == 3'd4);
            else
              last = int_has_err ? (int_step == 3'd3) : (int_step == 3'd2);
            if (last) begin
              logic [31:0] fsz;
              if (xpl_active) begin
                // CROSS-PRIV: the new (CPL0) SS:base were already loaded in
                // S_INT_SS; ESP now drops to the top of the pushed frame on the
                // TSS stack. fsz = 20 (5 words) or 24 (6 words w/ errcode).
                fsz = int_has_err ? 32'd24 : 32'd20;
                gpr[R_ESP] <= int_new_esp - fsz;
                // CPL already lowered when S_INT_CS loaded the target CS (RPL = the
                // gate selector's RPL = 0); xpl_active is cleared below.
              end else begin
                fsz = int_has_err ? 32'd16 : 32'd12;
                gpr[R_ESP] <= gpr[R_ESP] - fsz;
              end
              xpl_active <= 1'b0;
              eip        <= int_gate_off;
              // IA-32 6.12.1: on ANY interrupt/trap-gate entry the CPU clears TF
              // (bit8), NT (bit14), RF (bit16) and VM (bit17). An INTERRUPT gate
              // additionally clears IF (bit9); a TRAP gate leaves IF. The pushed
              // EFLAGS (beat 0) is the PRE-clear value, so this only masks the live
              // eflags after the frame is on the stack. NT/RF/VM are 0 throughout
              // the corpus (eflags = 0x202), so masking them is a no-op for the gate
              // but makes the entry IA-32-correct for any future TF/NT/V8086 test.
              //   common mask = TF|NT|RF|VM = 0x0003_4100; +IF (0x200) for int gate.
              if (!int_gate_trap)
                eflags <= eflags & ~32'h0003_4300;   // clear IF+TF+NT+RF+VM (int gate)
              else
                eflags <= eflags & ~32'h0003_4100;   // clear TF+NT+RF+VM (trap gate)
              q_pc          <= int_src_pc;   // stamp the delivering instruction's PC
              retire_valid  <= 1'b1;
              int_step      <= 3'd0;
              state         <= S_PIPE;
            end else begin
              int_step <= int_step + 3'd1;
            end
          end
        end

        // S_IRET: pop EIP, CS, EFLAGS. Beat 0 EIP @ ESP, 1 CS @ ESP+4,
        // 2 EFLAGS @ ESP+8. M2S.4 INTER-PRIV IRET: once the popped CS is known
        // (beat 1), if CS.RPL > the current CPL the return is to a LESS-privileged
        // level — the frame additionally carries ESP @ ESP+12 and SS @ ESP+16, so
        // we keep popping (beats 3,4) and switch to the outer stack. SAME-PRIV
        // (CS.RPL == CPL): stop at beat 2, ESP += 12, reload CS, retire.
        S_IRET: begin
          if (mem_ack) begin
            unique case (int_step)
              3'd0: begin iret_eip   <= mem_rdata;        int_step <= 3'd1; end
              3'd1: begin
                iret_cs    <= mem_rdata[15:0];
                // inter-priv iff the returned-to CS is less privileged than now.
                iret_interpriv <= (mem_rdata[1:0] > cpl_r);
                int_step <= 3'd2;
              end
              3'd2: begin
                // EFLAGS popped. Hold it; the actual eflags/eip/ESP commit happens
                // on the final beat so an inter-priv pop can still read ESP/SS.
                iret_eflags <= mem_rdata;
                if (iret_interpriv) int_step <= 3'd3;   // keep popping ESP, SS
                else begin
                  // SAME-PRIV: commit now (ESP += 12), reload CS, retire via _RET.
                  gpr[R_ESP]   <= gpr[R_ESP] + 32'd12;
                  eip          <= iret_eip;
                  eflags       <= mem_rdata;
                  int_gate_sel <= iret_cs;
                  int_step     <= 3'd0;
                  state        <= S_INT_CS_RET;
                end
              end
              3'd3: begin iret_esp <= mem_rdata;         int_step <= 3'd4; end
              default: begin
                // beat 4: SS popped. Commit the inter-priv return: EIP, EFLAGS, and
                // the OUTER ESP/SS. seg_base[SG_SS] is still the inner base while we
                // reload the CS (S_INT_CS_RET), then S_IRET_SS loads the outer SS
                // descriptor. ESP <- popped outer ESP (the inner-frame consumption
                // is irrelevant; we leave the inner stack entirely).
                iret_ss      <= mem_rdata[15:0];
                eip          <= iret_eip;
                eflags       <= iret_eflags;
                gpr[R_ESP]   <= iret_esp;
                int_gate_sel <= iret_cs;
                int_step     <= 3'd0;
                state        <= S_INT_CS_RET;
              end
            endcase
          end
        end

        // S_INT_CS_RET: reload the CS descriptor named by the IRET-popped CS, set
        // the selector + CPL. SAME-PRIV: RETIRE the IRET (q_pc = the IRET insn).
        // INTER-PRIV (iret_interpriv): the CPL just dropped to CS.RPL; chain to
        // S_IRET_SS to reload the OUTER SS descriptor (and null any data segment
        // not accessible at the new, lower privilege) before retiring.
        S_INT_CS_RET: begin
          if (mem_ack) begin
            if (int_step == 3'd0) begin
              int_lo <= mem_rdata; int_step <= 3'd1;
            end else begin
              logic [63:0] desc;
              desc = {mem_rdata, int_lo};
              seg_sel  [SG_CS] <= int_gate_sel;
              seg_base [SG_CS] <= desc_base(desc);
              seg_limit[SG_CS] <= desc_limit(desc);
              seg_attr [SG_CS] <= desc_attr(desc);
              cpl_r            <= int_gate_sel[1:0];
              cs_d             <= desc[54];
              int_step         <= 3'd0;
              if (iret_interpriv) begin
                state          <= S_IRET_SS;   // reload outer SS, then retire
              end else begin
                q_pc           <= int_src_pc;
                retire_valid   <= 1'b1;
                state          <= S_PIPE;
              end
            end
          end
        end

        // S_IRET_SS (M2S.4): inter-priv IRET tail. Reload the OUTER stack segment
        // from the popped SS selector (its hidden base/limit/attr), then NULL any
        // of DS/ES/FS/GS whose DPL is more privileged than the new CPL (IA-32
        // 6.12.3: on a privilege-lowering return, segment registers loaded with a
        // selector that is now inaccessible are zeroed to prevent a less-privileged
        // task from using a more-privileged data segment). Retire the IRET.
        // DONE-PARTIAL (documented follow-on): the outer SS is reloaded from the
        // popped selector WITHOUT re-validating that SS.RPL == popped CS.RPL and
        // SS.DPL == popped CS.RPL (IA-32 requires both on an inter-priv return,
        // else #GP(SS-selector)). The pcpl corpus uses matching RPL=3 selectors
        // (CS=0x1B, SS=0x23), so this never trips and there is no oracle for the
        // #GP path; deferred with the other negative-path SS checks above.
        S_IRET_SS: begin
          if (mem_ack) begin
            if (int_step == 3'd0) begin
              int_lo <= mem_rdata; int_step <= 3'd1;
            end else begin
              logic [63:0] desc;
              desc = {mem_rdata, int_lo};
              seg_sel  [SG_SS] <= iret_ss;
              seg_base [SG_SS] <= desc_base(desc);
              seg_limit[SG_SS] <= desc_limit(desc);
              seg_attr [SG_SS] <= desc_attr(desc);
              // null a data segment whose DPL < new CPL (would be inaccessible).
              for (int s = 0; s < NUM_SEG; s++) begin
                if ((s == int'(SG_DS) || s == int'(SG_ES) ||
                     s == int'(SG_FS) || s == int'(SG_GS)) &&
                    (desc_dpl(seg_attr[s]) < iret_cs[1:0])) begin
                  seg_sel  [s] <= 16'd0;
                  seg_base [s] <= 32'd0;
                  seg_limit[s] <= 32'd0;
                  seg_attr [s] <= 8'd0;
                end
              end
              iret_interpriv   <= 1'b0;
              int_step         <= 3'd0;
              q_pc             <= int_src_pc;
              retire_valid     <= 1'b1;
              state            <= S_PIPE;
            end
          end
        end

        // S_LTR (M2S.4): LTR r16 — read the GDT TSS descriptor named by the
        // selector in gpr[q_src_reg], load the TR hidden cache (base/limit/sel),
        // and retire. IA-32 also sets the descriptor's busy bit (type 9 -> B) in
        // the GDT; that writeback is a memory-only side effect the corpus never
        // reads back (STR returns the SELECTOR, captured below), so it is omitted
        // here — a documented simplification (no architectural-register effect).
        S_LTR: begin
          if (mem_ack) begin
            if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc;
              desc      = {mem_rdata, gdt_lo};
              tr_sel   <= gpr[q_src_reg][15:0];
              tr_base  <= desc_base(desc);
              tr_limit <= desc_limit(desc);
              tr_valid <= 1'b1;
              seg_step <= 1'b0;
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
            end
          end
        end

        // S_INT_TSS (M2S.4 cross-priv): read TSS.ssN:espN (N = int_new_cpl). The
        // 32-bit TSS stores ESPn then SSn contiguously at 0x04 + 8*N; beat 0 reads
        // ESPn, beat 1 reads SSn. Then read the new SS descriptor (S_INT_SS).
        S_INT_TSS: begin
          if (mem_ack) begin
            if (int_step == 3'd0) begin
              int_new_esp <= mem_rdata; int_step <= 3'd1;
            end else begin
              int_new_ss  <= mem_rdata[15:0];
              int_step    <= 3'd0;
              state       <= S_INT_SS;
            end
          end
        end

        // S_INT_SS (M2S.4 cross-priv): read + load the new SS descriptor named by
        // TSS.ssN, then push the larger frame (S_INT_PUSH). The new SS base feeds
        // the descending push (flat 0 in the pcpl corpus).
        // DONE-PARTIAL (documented follow-on): the new SS is loaded UNCONDITIONALLY.
        // IA-32 6.12.1.2 validates the loaded SS — SS.DPL == target CPL, SS.RPL ==
        // target CPL, a WRITABLE data segment, and Present — raising #TS(ssN)/#GP
        // otherwise (and S_INT_TSS would first bound the ssN:espN read against the
        // TSS limit + require tr_valid, raising #TS). The pcpl corpus uses a
        // well-formed SS0 (0x10, DPL0, present, writable, within the 104-byte TSS),
        // so none of these negative paths is exercised and there is NO oracle to
        // differentially validate the #TS/#GP delivery. Wiring an unvalidated fault
        // here would be unverified dead logic; deferred until a bad-SS / truncated-
        // TSS corpus test exists (see the tr_valid/tr_limit lint-sink note).
        S_INT_SS: begin
          if (mem_ack) begin
            if (int_step == 3'd0) begin
              int_lo <= mem_rdata; int_step <= 3'd1;
            end else begin
              logic [63:0] desc;
              desc = {mem_rdata, int_lo};
              seg_sel  [SG_SS] <= int_new_ss;
              seg_base [SG_SS] <= desc_base(desc);
              seg_limit[SG_SS] <= desc_limit(desc);
              seg_attr [SG_SS] <= desc_attr(desc);
              int_step         <= 3'd0;
              state            <= S_INT_PUSH;
            end
          end
        end

        // -------------------------------------------------------------------
        // S_FEXEC: x87 execute + commit. Updates fpr/ftop/fstat/fptag, sets
        // x87_touched_r, and either retires (advance EIP) or hands a memory
        // store to S_FSTORE. All arithmetic is bit-exact vs QEMU softfloat for
        // the corpus's normal operands (fpu_x87_pkg).
        // -------------------------------------------------------------------
        S_FEXEC: begin
          logic f_do_store, f_do_retire;
          logic [79:0] opnd_f;    // memory operand as floatx80 (read forms)
          logic [79:0] arg_b;     // right arithmetic operand (mem or st(i))
          logic [80:0] ar;        // {inexact, result}
          logic [82:0] arf;       // {ie, ze, inexact, result} from f_eval
          logic [2:0]  codes;
          logic [3:0]  xc;
          logic [79:0] st0v, stiv, resv;
          logic        inexact, cmp_ie;
          logic [1:0]  f_rc;      // rounding control (fctrl[11:10])
          logic        f_pc_bad;  // arithmetic requested under non-64-bit PC
          logic        f_is_arith;
          f_do_store=1'b0; f_do_retire=1'b1; inexact=1'b0; cmp_ie=1'b0;
          opnd_f = q_f_mem_read ? f_mem_as_float(f_mem80, q_f_mbytes) : 80'd0;
          st0v = fst(3'd0);
          stiv = fst(q_f_sti);
          f_rc = fctrl[11:10];

          // Precision control (PC = fctrl[9:8]) other than 11 (64-bit extended)
          // is a Tier-3 deferral: the datapath only implements full extended
          // precision, so rather than silently mis-rounding we HALT loudly on an
          // arithmetic op requested under PC != 11. (Data movement / compares /
          // constants are precision-independent and proceed normally.)
          f_is_arith = (q_fxop==FX_AR_ST0_STI) || (q_fxop==FX_AR_STI_ST0) ||
                       (q_fxop==FX_AR_M32)     || (q_fxop==FX_AR_M64)     ||
                       (q_fxop==FX_AR_I16)     || (q_fxop==FX_AR_I32)     ||
                       (q_fxop==FX_FSQRT);
          f_pc_bad = f_is_arith && (fctrl[9:8] != 2'b11);
          if (f_pc_bad) begin
            state<=S_HALT;
          end else
          unique case (q_fxop)
            // ---- loads (push) ----
            FX_FLD_M32, FX_FLD_M64, FX_FLD_M80: begin
              ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
              fpr[ftop-3'd1]<= (q_fxop==FX_FLD_M80) ? f_mem80 : opnd_f;
            end
            FX_FILD_M16, FX_FILD_M32, FX_FILD_M64: begin
              ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
              fpr[ftop-3'd1]<= f_mem_as_int(f_mem80, q_f_mbytes);
            end
            FX_FLDCONST: begin
              ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
              fpr[ftop-3'd1]<= fconst(q_f_const);
            end
            FX_FLD_STI: begin
              // push a copy of ST(i). Note: i is evaluated on the CURRENT TOP,
              // before the push (QEMU pushes then ST0=old ST(i)).
              ftop<=ftop-3'd1; fptag[ftop-3'd1]<=1'b0;
              fpr[ftop-3'd1]<= stiv;
            end
            // ---- register moves / stack mgmt ----
            FX_FST_STI: begin
              fpr[fri(q_f_sti)] <= st0v; fptag[fri(q_f_sti)]<=1'b0;
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            FX_FXCH: begin
              fpr[ftop]          <= stiv;
              fpr[fri(q_f_sti)]  <= st0v;
            end
            FX_FFREE: begin fptag[fri(q_f_sti)]<=1'b1; end
            FX_FINCSTP: begin ftop<=ftop+3'd1; fstat<=fstat & ~16'h4700; end
            FX_FDECSTP: begin ftop<=ftop-3'd1; fstat<=fstat & ~16'h4700; end
            FX_FNOP: begin /* no state change */ end
            FX_FWAIT: begin /* no unmasked exception in corpus */ end
            FX_FNINIT: begin
              ftop<=3'd0; fctrl<=16'h037f; fstat<=16'h0000; fptag<=8'hFF;
            end
            FX_FNCLEX: begin fstat<=fstat & 16'h7f00; end
            FX_FLDCW:  begin fctrl<=f_mem80[15:0]; end
            // ---- sign / abs on ST0 ----
            FX_FABS: begin fpr[ftop]<= {1'b0, st0v[78:0]}; end
            FX_FCHS: begin fpr[ftop]<= {~st0v[79], st0v[78:0]}; end
            // ---- compares ----
            // FCOM/FCOMP/FCOMPP/FTST/FICOM are SIGNALING (#IA on any NaN);
            // FUCOM/FUCOMP/FUCOMPP are QUIET (#IA only on a signaling NaN).
            FX_FCOM_STI, FX_FCOM_M32, FX_FCOM_M64: begin
              arg_b = (q_fxop==FX_FCOM_STI) ? stiv : opnd_f;
              codes = fcom_codes(st0v, arg_b);
              cmp_ie = fcom_ie(st0v, arg_b, 1'b1);     // signaling
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            FX_FUCOM_STI: begin
              codes = fcom_codes(st0v, stiv);
              cmp_ie = fcom_ie(st0v, stiv, 1'b0);      // quiet
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            FX_FCOMPP: begin
              codes = fcom_codes(st0v, fst(3'd1));
              cmp_ie = fcom_ie(st0v, fst(3'd1), 1'b1); // FCOMPP signaling
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              fptag[ftop]<=1'b1; fptag[ftop+3'd1]<=1'b1; ftop<=ftop+3'd2;
            end
            FX_FUCOMPP: begin
              codes = fcom_codes(st0v, fst(3'd1));
              cmp_ie = fcom_ie(st0v, fst(3'd1), 1'b0); // FUCOMPP quiet
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              fptag[ftop]<=1'b1; fptag[ftop+3'd1]<=1'b1; ftop<=ftop+3'd2;
            end
            FX_FTST: begin
              codes = fcom_codes(st0v, 80'd0);   // compare ST0 vs +0.0
              cmp_ie = fcom_ie(st0v, 80'd0, 1'b1);     // signaling
              fstat <= apply_cmp(fstat, codes, cmp_ie);
            end
            FX_FXAM: begin
              xc = fxam_codes(st0v, fptag[ftop]);
              fstat <= (fstat & ~16'h4700) |
                       ({1'd0,xc[3]}<<14) | ({5'd0,xc[2]}<<10) |
                       ({6'd0,xc[1]}<<9)  | ({7'd0,xc[0]}<<8);
            end
            FX_FICOM_M16, FX_FICOM_M32: begin
              arg_b = f_mem_as_int(f_mem80, q_f_mbytes);
              codes = fcom_codes(st0v, arg_b);
              cmp_ie = fcom_ie(st0v, arg_b, 1'b1);     // FICOM signaling
              fstat <= apply_cmp(fstat, codes, cmp_ie);
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            // ---- arithmetic ----
            // Each form selects (left,right) operands and calls f_eval, which
            // returns {ie, ze, inexact, result}. f_eval handles QEMU's explicit
            // special cases bit-exactly: x/0 -> signed Inf + ZE, 0/0 -> real-
            // indefinite QNaN + IE; otherwise the normal-operand datapath.
            FX_AR_ST0_STI: begin
              arf = f_eval(q_f_aluop, st0v, stiv, f_rc, errata_en[ERR_FDIV]);
              fpr[ftop]<=arf[79:0]; fstat<=f_arith_fstat(fstat, arf);
            end
            FX_AR_STI_ST0: begin
              // ST(i) op= ST0 : a=ST(i), b=ST0; sub/subr/div/divr direction per
              // QEMU helper_f{op}_STN_ST0 (which use ST(i) and ST0 in that order).
              arf = f_eval(q_f_aluop, stiv, st0v, f_rc, errata_en[ERR_FDIV]);
              fpr[fri(q_f_sti)]<=arf[79:0]; fstat<=f_arith_fstat(fstat, arf);
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
            end
            FX_AR_M32, FX_AR_M64: begin
              arf = f_eval(q_f_aluop, st0v, opnd_f, f_rc, errata_en[ERR_FDIV]);
              fpr[ftop]<=arf[79:0]; fstat<=f_arith_fstat(fstat, arf);
            end
            FX_AR_I16, FX_AR_I32: begin
              arf = f_eval(q_f_aluop, st0v, f_mem_as_int(f_mem80, q_f_mbytes), f_rc, errata_en[ERR_FDIV]);
              fpr[ftop]<=arf[79:0]; fstat<=f_arith_fstat(fstat, arf);
            end
            FX_FSQRT: begin
              // QEMU helper_fsqrt: if ST0 has its sign bit set (floatx80_is_neg),
              // clear the condition codes (0x4700) and set C2 (0x400) FIRST; then
              // floatx80_sqrt runs -> sqrt(-0)=-0 (no #IA); sqrt(negative finite)
              // = real-indefinite QNaN + #IA (IE). Positive operands take the
              // normal datapath (PE on inexact).
              if (st0v[79]) begin               // sign set: -finite / -0 / -NaN
                if (fx_is_neg(st0v) && !fx_is_nan(st0v)) begin
                  // negative non-zero (and not NaN): QNaN + IE, plus C2.
                  fpr[ftop]<= 80'hFFFFC000000000000000;
                  fstat <= (fstat & ~16'h4700) | 16'h0400 | 16'h0001;  // C2 + IE
                end else begin
                  // -0 (or -NaN): sqrt returns the operand; C2 set, no IE here.
                  ar = fx_sqrt(st0v, f_rc);
                  fpr[ftop]<=ar[79:0];
                  fstat <= (fstat & ~16'h4700) | 16'h0400;             // C2 only
                end
              end else begin
                ar = fx_sqrt(st0v, f_rc); inexact=ar[80];
                fpr[ftop]<=ar[79:0];
                if (inexact) fstat<=fstat | 16'h0020;
              end
            end
            // ---- memory stores: defer to S_FSTORE ----
            // The store VALUE and its exception flags depend only on ST0/fctrl
            // (stable across the store beats), so latch PE/IE (sticky) here at
            // dispatch. FST m80 / FNSTCW / FNSTSW m16 are exact (flags stay 0).
            FX_FST_M32, FX_FST_M64, FX_FST_M80,
            FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
            FX_FNSTCW, FX_FNSTSW_M: begin
              f_do_store=1'b1; f_do_retire=1'b0;
              if (fstore_ie)      fstat <= fstat | 16'h0001;   // IE (out-of-range FIST)
              else if (fstore_pe) fstat <= fstat | 16'h0020;   // PE (inexact store)
            end
            // ---- FNSTSW AX (writes AX, no memory) ----
            FX_FNSTSW_AX: begin
              gpr[R_EAX] <= {gpr[R_EAX][31:16],
                             (fstat & ~16'h3800) | ({13'd0,ftop}<<11)};
            end
            default: ;
          endcase

          // f_pc_bad already routed to S_HALT above (no retire); only commit the
          // EIP/retire when we actually executed the op.
          if (!f_pc_bad) begin
            if (f_do_retire) begin
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
            end else begin
              state<=S_FSTORE; f_step<=4'd0;
            end
          end
        end

        // -------------------------------------------------------------------
        // S_FSTORE: write the x87 store operand to memory over 1..3 bus beats,
        // then (for FSTP/FISTP) pop, advance EIP and retire. Memory contents are
        // not gate-compared, but stores are implemented faithfully.
        // -------------------------------------------------------------------
        S_FSTORE: begin
          if (mem_ack) begin
            // words needed: m16/cw/sw->1, m32->1, m64->2, m80->3
            if ((q_f_mbytes<=4'd4) ||
                (q_f_mbytes==4'd8 && f_step==4'd1) ||
                (q_f_mbytes==4'd10 && f_step==4'd2)) begin
              // last beat: apply pop and retire
              if (q_f_pop) begin fptag[ftop]<=1'b1; ftop<=ftop+3'd1; end
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE; f_step<=4'd0;
            end else f_step<=f_step+4'd1;
          end
        end

        // -------------------------------------------------------------------
        // M2S.2 — S_WALK: the 2-level page-table walk for a TLB miss.
        //   step 0: read PDE @ (CR3&~0xFFF)+lin[31:22]*4
        //   step 1: (4 KiB only) write PDE back with A(bit5) set, if it was clear
        //   step 2: read PTE @ (PDE&~0xFFF)+lin[21:12]*4
        //   step 3: write PTE back with A (and D on a write) set, if clear
        // On a 4 MiB page (CR4.PSE & PDE.PS) the PDE is the leaf: step 0 -> the
        // PDE-A/D writeback (reusing step 1's bus arm, then fill). A missing
        // Present bit is a #PF DECISION (CR2 + error code); delivery is M2S.3 so
        // it HALTs here (the gate tests are clean + never fault). The TLB stores
        // the effective {US,RW,P} = AND of the PDE and PTE permission bits.
        // -------------------------------------------------------------------
        S_WALK: begin
          if (mem_ack) begin
            unique case (walk_step)
              // -------- step 0: PDE read --------
              3'd0: begin
                logic [31:0] pde; logic is_big;
                pde    = mem_rdata;
                walk_pde <= pde;
                is_big = cr4_pse && pde[7];
                if (!pde[0]) begin
                  // PDE not present -> #PF (vector 14). M2S.3: DELIVER through the
                  // IDT. Set CR2 (the faulting linear addr) + the error code
                  // {US,RW,P} (P=0 here, RW from the access, US from the real CPL),
                  // then vector. #PF is a FAULT -> push the FAULTING EIP (q_pc) so
                  // IRET restarts the access after the handler maps the page.
                  creg2  <= walk_lin;
                  pf_errcode <= {cpl_r == 2'd3, walk_is_write, 1'b0};
                  walk_pf <= 1'b1;
                  start_fault(8'd14, 1'b1,
                              {29'd0, cpl_r == 2'd3, walk_is_write, 1'b0}, q_pc);
                end else if (is_big) begin
                  // 4 MiB large page: PDE is the leaf. Write A/D back if needed,
                  // else fill the TLB directly (reuse step-1's PDE writeback arm).
                  if (!pde[5] || (walk_is_write && !pde[6])) begin
                    walk_step <= 3'd1;   // writes PDE with A(+D for big-page write)
                  end else begin
                    tlb_fill_big(walk_for_d, walk_lin, pde);
                    state <= walk_ret_state;
                  end
                end else begin
                  // 4 KiB page: need the PTE. First set A on the PDE if clear.
                  walk_pte_addr <= {pde[31:12], walk_lin[21:12], 2'b00};
                  if (!pde[5]) walk_step <= 3'd1;   // write PDE.A then read PTE
                  else         walk_step <= 3'd2;   // PDE.A already set: read PTE
                end
              end
              // -------- step 1: PDE writeback (A, +D for a 4 MiB write) --------
              3'd1: begin
                logic is_big;
                is_big = cr4_pse && walk_pde[7];
                // reflect the just-written bits into the latched PDE.
                walk_pde <= walk_pde | 32'h0000_0020
                            | ((is_big && walk_is_write) ? 32'h0000_0040 : 32'd0);
                if (is_big) begin
                  tlb_fill_big(walk_for_d, walk_lin,
                               walk_pde | 32'h0000_0020 |
                               (walk_is_write ? 32'h0000_0040 : 32'd0));
                  state <= walk_ret_state;
                end else begin
                  walk_step <= 3'd2;   // now read the PTE
                end
              end
              // -------- step 2: PTE read --------
              3'd2: begin
                logic [31:0] pte;
                pte = mem_rdata;
                walk_pte <= pte;
                if (!pte[0]) begin
                  // PTE not present -> #PF (vector 14): DELIVER. CR2 + error code
                  // {US,RW,P=0}; push the FAULTING EIP (q_pc) so IRET restarts the
                  // access once the handler maps the page (the pfault demand-page).
                  creg2  <= walk_lin;
                  pf_errcode <= {cpl_r == 2'd3, walk_is_write, 1'b0};
                  walk_pf <= 1'b1;
                  start_fault(8'd14, 1'b1,
                              {29'd0, cpl_r == 2'd3, walk_is_write, 1'b0}, q_pc);
                end else if (!pte[5] || (walk_is_write && !pte[6])) begin
                  walk_step <= 3'd3;   // set A (+D on write) in the PTE
                end else begin
                  tlb_fill_4k(walk_for_d, walk_lin, walk_pde, pte, walk_is_write);
                  state <= walk_ret_state;
                end
              end
              // -------- step 3: PTE writeback (A + D) then fill --------
              default: begin
                logic [31:0] pte_new;
                pte_new = walk_pte | 32'h0000_0020
                          | (walk_is_write ? 32'h0000_0040 : 32'd0);
                tlb_fill_4k(walk_for_d, walk_lin, walk_pde, pte_new, walk_is_write);
                state <= walk_ret_state;
              end
            endcase
          end
        end

        S_HALT: state<=S_HALT;

        // M6 Erratum 81 (F00F): the locked CMPXCHG8B-with-register-destination
        // form never starts the #UD handler because the bus stays locked — the
        // processor HANGS. We model that as a parked state that NEVER retires and
        // keeps cpu_hung asserted (documented "system hang"). Unlike S_HALT this
        // is reached ONLY with errata_en[ERR_F00F] set; the clean core decodes
        // 0F C7 /reg as an unknown opcode and HALTs loudly (no retire) instead.
        S_F00F_HANG: begin hung_r<=1'b1; state<=S_F00F_HANG; end

        default: state<=S_HALT;
      endcase
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
    s0 = fpr[ftop];               // ST0
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
      // M6 Erratum 20: FIST[P] m16int/m32int (NOT m64) miss the overflow on
      // the documented positive operands in nearest/up rounding -> store ZERO,
      // no IE. fx_to_int_errata reproduces that when errata_en[ERR_FIST] is set;
      // otherwise it is identical to fx_to_int_ex (clean core unchanged).
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
  // Direct-mapped TLB index from a linear address (lin[15:12]).
  function automatic logic [3:0] tlb_idx(input logic [31:0] lin);
    tlb_idx = lin[15:12];
  endfunction
  // I-TLB lookup: hit iff valid + vpn matches.
  function automatic logic itlb_hit(input logic [31:0] lin);
    logic [3:0] ix; begin
      ix = tlb_idx(lin);
      itlb_hit = itlb_val[ix] && (itlb_vpn[ix] == lin[31:12]);
    end
  endfunction
  // I-TLB physical address: 4 MiB page uses lin[21:0] offset, else 4 KiB lin[11:0].
  function automatic logic [31:0] itlb_phys(input logic [31:0] lin);
    logic [3:0] ix; begin
      ix = tlb_idx(lin);
      itlb_phys = itlb_big[ix] ? {itlb_pfn[ix][19:10], lin[21:0]}
                               : {itlb_pfn[ix],          lin[11:0]};
    end
  endfunction
  function automatic logic dtlb_hit(input logic [31:0] lin);
    logic [3:0] ix; begin
      ix = tlb_idx(lin);
      dtlb_hit = dtlb_val[ix] && (dtlb_vpn[ix] == lin[31:12]);
    end
  endfunction
  function automatic logic [31:0] dtlb_phys(input logic [31:0] lin);
    logic [3:0] ix; begin
      ix = tlb_idx(lin);
      dtlb_phys = dtlb_big[ix] ? {dtlb_pfn[ix][19:10], lin[21:0]}
                               : {dtlb_pfn[ix],          lin[11:0]};
    end
  endfunction

  // Translate a linear address for the CURRENT bus access. `is_d`=1 selects the
  // D-TLB (data), else the I-TLB (fetch). Returns the physical address on a hit;
  // on a miss (or paging off) returns the linear address (the FSM never USES a
  // miss result — it diverts to S_WALK first). `miss` is set when paging_on AND
  // the relevant TLB misses.
  function automatic logic [31:0] mem_xlate(input logic [31:0] lin, input logic is_d);
    begin
      if (!paging_on)                 mem_xlate = lin;
      else if (is_d  &&  dtlb_hit(lin)) mem_xlate = dtlb_phys(lin);
      else if (!is_d &&  itlb_hit(lin)) mem_xlate = itlb_phys(lin);
      else                              mem_xlate = lin;   // miss: value unused
    end
  endfunction

  // Fill a TLB entry for a completed walk. The effective permission is the AND of
  // the PDE's and PTE's {P, RW, US} (bits 0/1/2): a page is writable only if BOTH
  // levels are writable, user only if BOTH are user — IA-32 §4.x. is_d selects
  // the D-TLB (data), else the I-TLB (fetch). is_w (data writes) records that the
  // page is already Dirty so a later write does not redundantly re-walk to set D.
  task automatic tlb_fill_4k(input logic is_d, input logic [31:0] lin,
                             input logic [31:0] pde, input logic [31:0] pte,
                             input logic is_w);
    logic [3:0] ix; logic [2:0] perm;
    begin
      ix   = lin[15:12];
      // effective {US, RW, P} = AND of the two levels.
      perm = {pde[2]&pte[2], pde[1]&pte[1], pde[0]&pte[0]};
      if (is_d) begin
        dtlb_val[ix]   <= 1'b1;          dtlb_vpn[ix]   <= lin[31:12];
        dtlb_pfn[ix]   <= pte[31:12];    dtlb_perm[ix]  <= perm;
        dtlb_big[ix]   <= 1'b0;          dtlb_dirty[ix] <= is_w;
      end else begin
        itlb_val[ix]   <= 1'b1;          itlb_vpn[ix]   <= lin[31:12];
        itlb_pfn[ix]   <= pte[31:12];    itlb_perm[ix]  <= perm;
        itlb_big[ix]   <= 1'b0;
      end
    end
  endtask
  // 4 MiB large page: the PDE is the leaf; frame = pde[31:22] (4 MiB aligned), the
  // pfn stored is pde[31:12] with the low 10 bits forced 0 so itlb_phys/dtlb_phys
  // overlay lin[21:0] for the offset. Permission is the PDE's own {US,RW,P}.
  task automatic tlb_fill_big(input logic is_d, input logic [31:0] lin,
                              input logic [31:0] pde);
    logic [3:0] ix; logic [2:0] perm; logic [19:0] pfn;
    begin
      ix   = lin[15:12];
      perm = {pde[2], pde[1], pde[0]};
      pfn  = {pde[31:22], 10'd0};
      if (is_d) begin
        dtlb_val[ix]   <= 1'b1;          dtlb_vpn[ix]   <= lin[31:12];
        dtlb_pfn[ix]   <= pfn;           dtlb_perm[ix]  <= perm;
        dtlb_big[ix]   <= 1'b1;          dtlb_dirty[ix] <= pde[6];
      end else begin
        itlb_val[ix]   <= 1'b1;          itlb_vpn[ix]   <= lin[31:12];
        itlb_pfn[ix]   <= pfn;           itlb_perm[ix]  <= perm;
        itlb_big[ix]   <= 1'b1;
      end
    end
  endtask

  // M2S.3 — begin IDT delivery of a HARDWARE fault (#GP/#NP/#SS/#PF/#UD raised
  // from a fault DECISION that prior stages only computed). A fault always
  // pushes the FAULTING instruction's EIP (restartable); `vec`, `has_err`, and
  // `err` carry the IA-32 error-code rules. `src_pc` is the q_pc to stamp on the
  // single delivery retire record. The micro-sequence then reads IDT[vec], the
  // gate's CS descriptor, pushes the frame, and loads CS:EIP. Only invoked when
  // sys_mode (faults can only arise from the system-mode states).
  task automatic start_fault(input logic [7:0] vec, input logic has_err,
                             input logic [31:0] err, input logic [31:0] fault_pc);
    begin
      int_vec     <= vec;
      int_ret_eip <= fault_pc;     // FAULT: push the faulting EIP (restart)
      int_src_pc  <= fault_pc;
      int_has_err <= has_err;
      int_err     <= err;
      int_step    <= 3'd0;
      int_sw      <= 1'b0;        // HW fault: bypass the gate DPL>=CPL check
      state       <= S_INT_GATE;
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
          cur_lin = (q_st==ST_SCAS) ? dbase+gpr[R_EDI] : dbase+gpr[R_ESI];
        else                                           cur_lin = dbase+q_ea;
      end
      S_LOAD2: cur_lin = dbase_edi+gpr[R_EDI];
      S_FLOAD: cur_lin = dbase+q_ea + {26'd0, f_step, 2'b00};
      S_FSTORE: begin cur_lin = dbase+q_ea + {26'd0, f_step, 2'b00}; cur_is_w = 1'b1; end
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
    xlate_miss = paging_on && translatable &&
                 (cur_is_d
                    ? (!dtlb_hit(cur_lin) ||
                       (cur_is_w && !dtlb_dirty[tlb_idx(cur_lin)]))
                    : !itlb_hit(cur_lin));
  end

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
    p   = dtlb_perm[tlb_idx(cur_lin)];   // {US, RW, P}
    usr = (cpl_r == 2'd3);
    wp  = creg0[16];
    perm_fault = 1'b0;
    if (paging_on && cur_is_d && dtlb_hit(cur_lin)) begin
      // user access to a supervisor page
      if (usr && !p[2]) perm_fault = 1'b1;
      // write to a read-only page (user writer always; supervisor only if WP)
      if (cur_is_w && !p[1] && (usr || wp)) perm_fault = 1'b1;
    end
  end

  // ===========================================================================
  // Bus request generation (single combinational driver). Each arm computes the
  // LINEAR address into mem_addr; the post-stage below translates it.
  // ===========================================================================
  always_comb begin
    mem_req=1'b0; mem_we=1'b0; mem_addr=32'd0; mem_wdata=32'd0; mem_wstrb=4'd0;
    unique case (state)
      S_FETCH: begin mem_req=1'b1; mem_addr=flin+{27'd0,fetch_word,2'b00}; end
      S_PF:    begin mem_req=1'b1; mem_addr={pf_fill_addr[31:5],5'd0}+{27'd0,pf_word,2'b00}; end
      S_PIPE:  begin
        // a register-base load issued this clock reads [base] combinationally.
        // M2S.1: add the DS base (0 in user mode / flat PM).
        if (pipe_load_req) begin mem_req=1'b1; mem_addr=seg_base[SG_DS]+gpr[pipe_load_base]; end
        // I-cache miss detected this clock: fetch the fill line's WORD 0 NOW so the
        // detection clock is productive (finding [med] I-miss off-by-one). S_PF then
        // fetches words 1..7. mem_req for the load and the fill are mutually
        // exclusive: pf_miss => !pipe_bytes_ok => pipe_load_req is false.
        else if (pf_miss) begin mem_req=1'b1; mem_addr={pf_miss_fa[31:5],5'd0}; end
      end
      S_LOAD: begin
        mem_req=1'b1;
        if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
            (q_kind==K_STKMISC && q_sm==SM_POPF))
          mem_addr=dbase+gpr[R_ESP];
        else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)
          mem_addr=dbase+gpr[R_EBP];     // LEAVE reads [EBP] (the saved frame ptr)
        else if (q_kind==K_STR) begin
          // load order: movs/lods/cmps -> [ESI]; scas -> [EDI]
          if (q_st==ST_SCAS) mem_addr=dbase+gpr[R_EDI];
          else               mem_addr=dbase+gpr[R_ESI];
        end else mem_addr=dbase+q_ea;
      end
      S_LOAD2: begin mem_req=1'b1; mem_addr=dbase_edi+gpr[R_EDI]; end
      // M2S.1 — LGDT/LIDT 6-byte read + PM descriptor fetches.
      S_LGDT: begin mem_req=1'b1; mem_addr=dbase+q_ea+{29'd0,seg_step,2'b00}; end
      S_SEGLD: begin mem_req=1'b1;
        mem_addr=gdt_base+{16'd0,gpr[q_src_reg][15:3],3'd0}+{29'd0,seg_step,2'b00};
      end
      S_LJMP: begin mem_req=1'b1;
        mem_addr=gdt_base+{16'd0,q_ljmp_sel[15:3],3'd0}+{29'd0,seg_step,2'b00};
      end
      S_FLOAD: begin
        mem_req=1'b1; mem_addr=dbase+q_ea + {26'd0, f_step, 2'b00};   // base + q_ea + 4*f_step
      end
      S_FSTORE: begin
        mem_req=1'b1; mem_we=1'b1;
        mem_addr = dbase+q_ea + {26'd0, f_step, 2'b00};
        // the m80 third beat writes only 2 bytes; all others write a full word.
        if (q_f_mbytes==4'd10 && f_step==4'd2) mem_wstrb=4'b0011;
        else if (q_f_mbytes==4'd2)             mem_wstrb=4'b0011;   // m16 (cw/sw/int16)
        else                                   mem_wstrb=4'b1111;
        unique case (f_step)
          4'd0: mem_wdata = fstore_val[31:0];
          4'd1: mem_wdata = fstore_val[63:32];
          default: mem_wdata = {16'd0, fstore_val[79:64]};
        endcase
      end
      S_STORE: begin
        mem_req=1'b1; mem_we=1'b1;
        if (q_kind==K_STR) begin
          // string store [EDI] uses ES.
          mem_wstrb=strb_of(q_w); mem_addr=dbase_edi+str_store_addr; mem_wdata=str_store_data;
        end else begin
          mem_wstrb=st_strb; mem_addr=dbase+st_addr; mem_wdata=st_data;
        end
      end
      S_USEQ: begin
        mem_req=1'b1;
        if (q_sm==SM_PUSHA) begin
          mem_we=1'b1; mem_wstrb=4'b1111;
          mem_addr=dbase+pusha_esp - (32'd4*({28'd0,step}+32'd1));
          unique case (step)
            4'd0: mem_wdata=gpr[R_EAX];
            4'd1: mem_wdata=gpr[R_ECX];
            4'd2: mem_wdata=gpr[R_EDX];
            4'd3: mem_wdata=gpr[R_EBX];
            4'd4: mem_wdata=pusha_esp;     // original ESP
            4'd5: mem_wdata=gpr[R_EBP];
            4'd6: mem_wdata=gpr[R_ESI];
            default: mem_wdata=gpr[R_EDI];
          endcase
        end else begin // POPA: read ascending from ESP
          mem_we=1'b0; mem_addr=dbase+gpr[R_ESP] + (32'd4*{28'd0,step});
        end
      end
      // M2S.2 — the page-walk reads/writes the page tables in PHYSICAL memory.
      // walk_step: 0=read PDE, 1=write PDE (A bit), 2=read PTE, 3=write PTE (A/D).
      S_WALK: begin
        mem_req=1'b1;
        unique case (walk_step)
          3'd0: mem_addr = walk_pde_addr;                        // read PDE
          3'd1: begin mem_we=1'b1; mem_wstrb=4'b1111;            // write PDE (set A)
                      mem_addr = walk_pde_addr; mem_wdata = walk_pde | 32'h0000_0020; end
          3'd2: mem_addr = walk_pte_addr;                        // read PTE
          default: begin mem_we=1'b1; mem_wstrb=4'b1111;         // write PTE (set A/D)
                      mem_addr = walk_pte_addr;
                      mem_wdata = walk_pte | 32'h0000_0020
                                  | (walk_is_write ? 32'h0000_0040 : 32'd0); end
        endcase
      end
      // M2S.3 — IDT delivery: gate read, CS-descriptor read, frame pushes, IRET
      // pops, and the CS-descriptor reload. These are LINEAR addresses (the IDT/
      // GDT are at known linear bases; the stack uses SS.base+ESP) and ARE paged
      // when paging_on (the post-stage below translates them).
      S_INT_GATE: begin mem_req=1'b1;            // IDT[vec] @ idt_base + vec*8
        mem_addr = idt_base + {21'd0, int_vec, 3'd0} + {29'd0, int_step[0], 2'b00};
      end
      S_INT_CS: begin mem_req=1'b1;              // GDT[gate_sel] descriptor
        mem_addr = gdt_base + {16'd0, int_gate_sel[15:3], 3'd0}
                   + {29'd0, int_step[0], 2'b00};
      end
      S_INT_PUSH: begin mem_req=1'b1; mem_we=1'b1; mem_wstrb=4'b1111;
        if (xpl_active) begin
          // M2S.4 CROSS-PRIV: push the LARGER 5-word (or 6-word w/ errcode) frame
          // descending from the NEW stack (TSS.espN). seg_base[SG_SS] is already
          // the new (CPL0) SS base after S_INT_SS. Beats, low->high stored value:
          //   0 old SS @ esp-4, 1 old ESP @ esp-8, 2 EFLAGS @ esp-12,
          //   3 CS @ esp-16, 4 EIP @ esp-20, 5 errcode @ esp-24.
          mem_addr = seg_base[SG_SS] + int_new_esp
                     - ({28'd0, int_step} * 32'd4) - 32'd4;
          unique case (int_step)
            3'd0:    mem_wdata = {16'd0, int_old_ss};
            3'd1:    mem_wdata = int_old_esp;
            3'd2:    mem_wdata = eflags;
            3'd3:    mem_wdata = {16'd0, int_old_cs};   // interrupted task's CS
            3'd4:    mem_wdata = int_ret_eip;
            default: mem_wdata = int_err;
          endcase
        end else begin
          // SAME-PRIV: beat 0 EFLAGS @ ESP-4, 1 CS @ ESP-8, 2 EIP @ ESP-12,
          // 3 errcode @ ESP-16. The push uses the SS base (flat 0 here).
          mem_addr = seg_base[SG_SS] + gpr[R_ESP]
                     - ({28'd0, int_step} * 32'd4) - 32'd4;
          unique case (int_step)
            3'd0:    mem_wdata = eflags;
            3'd1:    mem_wdata = {16'd0, seg_sel[SG_CS]};
            3'd2:    mem_wdata = int_ret_eip;
            default: mem_wdata = int_err;
          endcase
        end
      end
      S_IRET, S_IRET_SS: begin mem_req=1'b1;     // pop EIP/CS/EFLAGS[+ESP/SS] asc
        mem_addr = seg_base[SG_SS] + gpr[R_ESP] + ({28'd0, int_step} * 32'd4);
      end
      S_INT_CS_RET: begin mem_req=1'b1;          // reload returned-to CS descriptor
        mem_addr = gdt_base + {16'd0, int_gate_sel[15:3], 3'd0}
                   + {29'd0, int_step[0], 2'b00};
      end
      // M2S.4 — TR/TSS reads (run with paging OFF, like the other descriptor
      // reads; NOT re-translated by the post-stage below).
      S_LTR: begin mem_req=1'b1;                 // GDT TSS descriptor @ gdt_base
        mem_addr = gdt_base + {16'd0, gpr[q_src_reg][15:3], 3'd0}
                   + {29'd0, seg_step, 2'b00};
      end
      S_INT_TSS: begin mem_req=1'b1;             // TSS.ssN:espN (ESPn then SSn)
        mem_addr = tr_base + tss_stk_off + {29'd0, int_step[0], 2'b00};
      end
      S_INT_SS: begin mem_req=1'b1;              // new SS descriptor @ gdt_base
        mem_addr = gdt_base + {16'd0, int_new_ss[15:3], 3'd0}
                   + {29'd0, int_step[0], 2'b00};
      end
      default: ;
    endcase
    // ---- paging post-translation: linear -> physical for the data/fetch states.
    // The descriptor / TSS-structure reads (S_LGDT/S_SEGLD/S_LJMP and M2S.4
    // S_LTR + the GDT read S_INT_SS + the TSS read S_INT_TSS) and the walk itself
    // (S_WALK) address PHYSICAL memory directly and are NOT re-translated. Per
    // IA-32 the GDT and TSS are linear structures, but the M2S.1/.2 identity-map
    // simplification reads them physically — S_INT_TSS is excluded consistently
    // with the sibling GDT read S_INT_SS (both feed the same cross-priv delivery).
    if (paging_on && state != S_WALK &&
        state != S_LGDT && state != S_SEGLD && state != S_LJMP &&
        state != S_LTR && state != S_INT_SS && state != S_INT_TSS) begin
      // CRITICAL (Phase-3 [high] fix): on a TLB MISS this clock the FSM diverts to
      // S_WALK (the clocked block, gated on the same `xlate_miss`), so the bus this
      // clock belongs to the PAGE WALK, not to this state's access. But `state` is
      // still the access state combinationally, so without this guard the driver
      // would assert mem_req (and, on a WRITE state, mem_we) with mem_addr =
      // mem_xlate(linear) — which on a MISS returns the UNTRANSLATED LINEAR address
      // (see mem_xlate). The single-beat memmodel would then commit a spurious
      // write to the linear==physical alias before the walk fills the TLB. SQUASH
      // the access entirely on a miss: the walk owns the bus, and the access is
      // re-driven (now TLB-resident, correct physical) when the FSM resumes.
      if (xlate_miss) begin
        mem_req=1'b0; mem_we=1'b0; mem_addr=32'd0; mem_wdata=32'd0; mem_wstrb=4'd0;
      end else if (mem_req) begin
        mem_addr = mem_xlate(mem_addr, cur_is_d);
      end
    end
  end

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
                   //   itlb_perm   : the fetch-side effective {US,RW,P} (home for a
                   //                 future fetch-permission / NX check).
                   // Sunk so the clean -Wall lint stays quiet.
                   perm_fault, walk_pf, &pf_errcode,
                   itlb_perm[0][0],
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
                   tr_valid, tr_limit[0]};
  // verilator lint_on UNUSED

endmodule : core
