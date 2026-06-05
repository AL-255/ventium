// ventium_top.sv — Ventium top level (M1 single-issue in-order integer core).
//
// Ventium: a synthesizable SystemVerilog replica of the Intel Pentium (P5/P54C).
// Block decomposition: PLAN.md §6.  M1 milestone (PLAN.md §7,
// docs/m1-core-spec.md): replace the M0 NOP stub with a REAL integer core that
// fetches/decodes/executes IA-32 from memory and is diff-clean vs QEMU.
//
// The live datapath is the integer/pipeline spine in
// rtl/core/core.sv (module `core`, instantiated below as u_core; renamed from
// intcore.sv in the R1 modularization, docs/rtl-refactor-plan.md). It wires the
// extracted decode/issue_uv leaves + ALU/decode packages and runs the pipeline
// FSM + retire. ventium_top owns:
//   * the top port list (docs/rtl-interface.md §1): clk, rst_n, init_eip/
//     init_esp (driven by the TB at reset), and the mem_* bus group (§3);
//   * the single DPI retire point (docs/rtl-interface.md §2): the core raises
//     retire_valid for one clock with the post-commit architectural state, and
//     ventium_top calls vtm_retire(n, pc, ...) here, maintaining the monotonic
//     retire counter n.
//
// The remaining PLAN §6 blocks (bpred/issue/caches/tlb/fpu/biu/sys) are
// still M0-style stubs instantiated for a coherent block map; they land in
// M2..M6.  (There is no microcode-ROM block: the P5 executes x86 directly —
// complex/serializing ops are microcode-SEQUENCED by the slow FSM in core.sv,
// not fetched as P6-style uops from a uop ROM — so the ucode_rom stub was
// removed.)  The integer regfile/fetch/decode/exec are realised inside
// core.sv (a coherent functional FSM); the standalone block stubs
// remain as the future home of the pipelined versions.
//
// ventium_pkg is supplied on the build command line (single compilation unit),
// so no `include is needed — `import ventium_pkg::*` below resolves it.

module ventium_top
  import ventium_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,     // active-low synchronous reset, held ≥1 cycle

    // Reset-time architectural init (docs/m1-core-spec.md "Initial architectural
    // state").  The TB drives these during the reset phase: init_eip = entry,
    // init_esp = --init-esp (default 0x40c348d0).  The core latches them at the
    // reset edge.  Segment selectors + EFLAGS reset value are constants in the
    // core (the M1 corpus never changes them).
    input  logic [31:0] init_eip,
    input  logic [31:0] init_esp,

    // M2S.1: boot-mode select (TB drives 1 in --system mode). 0 = user (the
    // M0-M6 cold reset to init_eip/init_esp, flat); 1 = system (cold reset at
    // CS:EIP=F000:FFF0, real mode). Default 0 keeps make verify unchanged.
    input  logic        boot_mode,

    // M5B-int: bus-mode select (TB drives 1 in --bus-mode). DEFAULT 0 = the core
    // memory port connects DIRECTLY to the top mem_* ports (the existing M0/M1
    // bus-functional path — BYTE-IDENTICAL, the M4/M5-gated path; the gated bus
    // subsystem is completely BYPASSED/inert). 1 = the core memory is routed
    // through the gated pin-level 64-bit P5 bus subsystem (rtl/bus/biu.sv: a
    // FRONT 32b adapter + the biu_p5 FSM + a loopback pin-level responder), whose
    // abstract BACK side (mem2_*) then drives the top mem_* ports (so the TB
    // memmodel still serves the data, unchanged). This proves the core's memory
    // round-trips through the REAL pin protocol (FUNCTIONAL equivalence only;
    // there is NO pin-level cycle oracle — docs/m5b-bus-spec.md §5.3). ADDITIVE:
    // bus_mode=0 keeps every existing gate (incl. the M4/M5 cycle bands) bit-
    // identical, respecting the M5B deferral constraint.
    input  logic        bus_mode,

    // M4: cycle-mode select (TB drives 1 in --cycle mode). Enables dual U/V
    // issue + pipe/paired reporting. 0 = func mode (M1/M2/M3 gates, single issue).
    input  logic        cycle_mode,

    // M6: errata-enable bus (docs/m6-errata-spec.md). DEFAULT 0 = clean core
    // (M0-M5, bit-exact vs QEMU); each set bit reproduces one documented P5
    // silicon defect. The TB drives this from --errata (default 0). cpu_hung
    // reports the F00F hang (Erratum 81).
    input  logic [4:0]  errata_en,
    output logic        cpu_hung,

    // M7.1: Quake user-mode int-0x80 proxy + %gs TLS base (docs/m7-lockstep-spec).
    // DEFAULT 0 = INERT (proxy off; gs flat) so the M0-M6 user gate is
    // byte-identical. The TB drives these in --quake-image / --lockstep mode: it
    // samples syscall_active (a 1-clock pulse when the core proxies an int-0x80,
    // naming the upcoming retire syscall_n), applies the golden kernel memory
    // writes to its bus memory, and drives back the golden ret/resume-eip/gs
    // effects for the core to replay. See rtl/core/core.sv for the contract.
    input  logic        proxy_en,
    output logic        syscall_active,
    output logic [63:0] syscall_n,
    input  logic [31:0] syscall_resume_eip,
    input  logic [31:0] syscall_eax,
    input  logic        syscall_apply_gs,
    input  logic [31:0] syscall_gs_base,

    // M7.3b: Win95 system co-sim port-I/O bus (docs/m7-lockstep-spec.md M7.3).
    // DEFAULT 0 = INERT (the IN/OUT decode HALTs / the `out 0xf4` terminator is
    // preserved, the io_* bus is never driven) so make verify + the sys gates are
    // byte-identical. The TB drives cosim_en in --win95-image mode and services
    // io_* by replaying the golden dev_in read values (the only env injection).
    input  logic        cosim_en,
    output logic        io_req,
    output logic        io_we,
    output logic [15:0] io_addr,
    output logic [2:0]  io_size,
    output logic [31:0] io_wdata,
    input  logic [31:0] io_rdata,
    input  logic        io_ack,

    // M0/M1 bus-functional-model port group (docs/rtl-interface.md §3). Minimal
    // by design; M5 replaces it with the modeled 64-bit P5 bus FSM.
    output logic        mem_req,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ack
);

  // ---------------------------------------------------------------------------
  // The M1 integer core: fetch -> decode -> execute -> mem -> retire, one insn
  // at a time. It owns the bus and raises retire_valid with post-commit state.
  // ---------------------------------------------------------------------------
  logic        core_retire_valid;
  logic [31:0] core_retire_pc;
  arch_state_t core_retire_state;

  // x87 post-commit state (M3); valid when core_retire_valid && core_x87_touched.
  logic        core_x87_touched;
  logic [15:0] core_fctrl, core_fstat, core_ftag;
  logic [79:0] core_st0, core_st1, core_st2, core_st3;
  logic [79:0] core_st4, core_st5, core_st6, core_st7;

  // M4 cycle attribution + paired second retirement.
  logic        core_pipe_valid, core_paired;
  logic [1:0]  core_pipe;
  logic        core_retire2_valid, core_retire2_paired;
  logic [31:0] core_retire2_pc;
  logic [1:0]  core_retire2_pipe;
  arch_state_t core_retire2_state;

  // M2S.1 system retire payload.
  logic        core_retire_sys;
  logic [31:0] core_cr0, core_cr2, core_cr3, core_cr4;

  // M5B-int: the core's own memory port. In bus_mode=0 these connect DIRECTLY to
  // the top mem_* ports (the existing path); in bus_mode=1 the request side goes
  // to the bus subsystem FRONT and the response side comes back from it. The mux
  // is below the core instance. (Declared here so the core can bind to them.)
  logic        core_mem_req, core_mem_we;
  logic [31:0] core_mem_addr, core_mem_wdata;
  logic [3:0]  core_mem_wstrb;
  logic [31:0] core_mem_rdata;
  logic        core_mem_ack;

  core u_core (
      .clk          (clk),
      .rst_n        (rst_n),
      .init_eip     (init_eip),
      .init_esp     (init_esp),
      .boot_mode    (boot_mode),
      .cycle_mode   (cycle_mode),
      .errata_en    (errata_en),
      .cpu_hung     (cpu_hung),
      .proxy_en           (proxy_en),
      .syscall_active     (syscall_active),
      .syscall_n          (syscall_n),
      .syscall_resume_eip (syscall_resume_eip),
      .syscall_eax        (syscall_eax),
      .syscall_apply_gs   (syscall_apply_gs),
      .syscall_gs_base    (syscall_gs_base),
      .cosim_en     (cosim_en),
      .io_req       (io_req),
      .io_we        (io_we),
      .io_addr      (io_addr),
      .io_size      (io_size),
      .io_wdata     (io_wdata),
      .io_rdata     (io_rdata),
      .io_ack       (io_ack),
      .mem_req      (core_mem_req),
      .mem_we       (core_mem_we),
      .mem_addr     (core_mem_addr),
      .mem_wdata    (core_mem_wdata),
      .mem_wstrb    (core_mem_wstrb),
      .mem_rdata    (core_mem_rdata),
      .mem_ack      (core_mem_ack),
      .retire_valid (core_retire_valid),
      .retire_pc    (core_retire_pc),
      .retire_state (core_retire_state),
      .retire_x87_touched (core_x87_touched),
      .retire_fctrl (core_fctrl),
      .retire_fstat (core_fstat),
      .retire_ftag  (core_ftag),
      .retire_st0   (core_st0), .retire_st1 (core_st1),
      .retire_st2   (core_st2), .retire_st3 (core_st3),
      .retire_st4   (core_st4), .retire_st5 (core_st5),
      .retire_st6   (core_st6), .retire_st7 (core_st7),
      .retire_pipe_valid (core_pipe_valid),
      .retire_pipe       (core_pipe),
      .retire_paired     (core_paired),
      .retire2_valid     (core_retire2_valid),
      .retire2_pc        (core_retire2_pc),
      .retire2_state     (core_retire2_state),
      .retire2_pipe      (core_retire2_pipe),
      .retire2_paired    (core_retire2_paired),
      .retire_sys        (core_retire_sys),
      .retire_cr0        (core_cr0),
      .retire_cr2        (core_cr2),
      .retire_cr3        (core_cr3),
      .retire_cr4        (core_cr4)
  );

  // ---------------------------------------------------------------------------
  // Single DPI retire point (docs/rtl-interface.md §2).  retire_n is the core's
  // own retire counter (starts at 0, +1 per retired instruction).  The core
  // pulses retire_valid for exactly one clock per committed instruction with the
  // post-commit architectural state; we emit one vtm_retire call here.
  // ---------------------------------------------------------------------------
  logic [63:0] retire_n;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      retire_n <= 64'd0;
    end else if (core_retire_valid) begin
`ifndef VTM_NO_DPI
      // ---- M2S.1 system hook: stash cr0..cr4 keyed by `n` BEFORE vtm_retire ---
      // Only a system-mode core raises core_retire_sys; the TB (under --system)
      // drains the stash on the matching vtm_retire and emits the sys fields.
      if (core_retire_sys)
        vtm_retire_sys(retire_n, core_cr0, core_cr2, core_cr3, core_cr4);
      // ---- primary (U) retirement -----------------------------------------
      // x87 hook FIRST so the TB stashes the LIVE FP state keyed by `n` before
      // the paired vtm_retire (same `n`) drains+emits the combined record. We
      // call it on EVERY retirement (not just FP ops): in x87-trace mode QEMU
      // reports the live st0..st7/fctrl/fstat on every instruction, so an
      // integer instruction must still carry the current (unchanged) FP state.
      // The TB only emits the x87 fields when its header declares x87:true, so
      // this is harmless for integer programs. (core_x87_touched is retained on
      // the port for future use but no longer gates the call.)
      vtm_retire_x87(
          retire_n,
          {16'd0, core_fctrl}, {16'd0, core_fstat}, {16'd0, core_ftag},
          core_st0[63:0], core_st0[79:64], core_st1[63:0], core_st1[79:64],
          core_st2[63:0], core_st2[79:64], core_st3[63:0], core_st3[79:64],
          core_st4[63:0], core_st4[79:64], core_st5[63:0], core_st5[79:64],
          core_st6[63:0], core_st6[79:64], core_st7[63:0], core_st7[79:64]);
      // cycle attribution (M4): pipe/paired for this retirement. Absent (func
      // mode / slow path) -> pipe defaults to U paired=false in the TB.
      if (core_pipe_valid)
        vtm_retire_cycle(retire_n, {30'd0, core_pipe}, {31'd0, core_paired});
      vtm_retire(
          retire_n,
          core_retire_pc,
          core_retire_state.eflags,
          core_retire_state.eax, core_retire_state.ecx,
          core_retire_state.edx, core_retire_state.ebx,
          core_retire_state.esp, core_retire_state.ebp,
          core_retire_state.esi, core_retire_state.edi,
          core_retire_state.cs,  core_retire_state.ss,
          core_retire_state.ds,  core_retire_state.es,
          core_retire_state.fs,  core_retire_state.gs);

      // ---- second (V) retirement in the SAME clock (paired issue) ----------
      // n increments by one; the V insn shares the TB clock (same cyc) and
      // carries pipe=V paired=true. x87 state is the same snapshot.
      if (core_retire2_valid) begin
        vtm_retire_x87(
            retire_n + 64'd1,
            {16'd0, core_fctrl}, {16'd0, core_fstat}, {16'd0, core_ftag},
            core_st0[63:0], core_st0[79:64], core_st1[63:0], core_st1[79:64],
            core_st2[63:0], core_st2[79:64], core_st3[63:0], core_st3[79:64],
            core_st4[63:0], core_st4[79:64], core_st5[63:0], core_st5[79:64],
            core_st6[63:0], core_st6[79:64], core_st7[63:0], core_st7[79:64]);
        vtm_retire_cycle(retire_n + 64'd1, {30'd0, core_retire2_pipe},
                         {31'd0, core_retire2_paired});
        vtm_retire(
            retire_n + 64'd1,
            core_retire2_pc,
            core_retire2_state.eflags,
            core_retire2_state.eax, core_retire2_state.ecx,
            core_retire2_state.edx, core_retire2_state.ebx,
            core_retire2_state.esp, core_retire2_state.ebp,
            core_retire2_state.esi, core_retire2_state.edi,
            core_retire2_state.cs,  core_retire2_state.ss,
            core_retire2_state.ds,  core_retire2_state.es,
            core_retire2_state.fs,  core_retire2_state.gs);
      end
`endif
      retire_n <= retire_n + (core_retire2_valid ? 64'd2 : 64'd1);
    end
  end

  // ---------------------------------------------------------------------------
  // Block decomposition (PLAN §6). These remain M0-style stubs instantiated for
  // a coherent block map; the pipelined versions land in M2..M6. (The
  // integer datapath lives in core.sv above.) Inputs tied off; outputs left
  // at the stubs' benign defaults.
  // ---------------------------------------------------------------------------

  // §6.1 Front end -----------------------------------------------------------
  fetch       u_fetch   (.clk(clk), .rst_n(rst_n));
  // R2: the branch predictor (bpred_btb: 4-way BTB + 2-bit saturating counter)
  // is now instantiated INSIDE the core (rtl/core/core.sv), wired to the two
  // combinational predict ports + the single synchronous resolve port. The old
  // empty M0 `bpred_btb` placeholder stub here is gone (the module is now real).
  // R1 phase-3: `decode` is now a REAL fast-path decoder leaf (rtl/core/decode.sv),
  // instantiated inside core.sv (u_decode / v_decode). No top-level block-map
  // stub instance — it is wired into the datapath, not tied off.

  // §6.3 Integer execution ----------------------------------------------------
  // R1 phase-3: `issue_uv` is now a REAL pairing-checker leaf
  // (rtl/core/issue_uv.sv), instantiated inside core.sv (u_issue). No
  // top-level block-map stub — it is wired into the datapath, not tied off.
  exec_int    u_exec    (.clk(clk), .rst_n(rst_n));
  regfile     u_regfile (.clk(clk), .rst_n(rst_n));

  // §6.6 x87 FPU ---------------------------------------------------------------
  // R2: `fpu_top` is now the REAL x87 architectural STATE FILE (fpr[8]/ftop/
  // fctrl/fstat/fptag + reset + the st(i) read addressing + a write-port
  // interface), instantiated INSIDE the core as u_fpu_state (rtl/core/core.sv),
  // wired to the two runtime-exclusive FP writer arms (the M5 cycle-mode fast
  // path + the slow S_FEXEC/S_FSTORE FSM). The old empty M0 `fpu_top` placeholder
  // stub here is gone (it was a no-op; the state lives in the core now).

  // §6.1/§6.5 Memory subsystem -------------------------------------------------
  // R2: the L1 D-cache TIMING model (dcache_timing) is now instantiated INSIDE
  // the core (rtl/core/core.sv), wired to the load/store SM. The old empty M0
  // `dcache` placeholder stub here is gone (the module is now dcache_timing).
  // R2: the split I/D TLBs (the `tlb` module) are likewise now instantiated
  // INSIDE the core as u_itlb (IS_D=0) and u_dtlb (IS_D=1), wired to the page-walk
  // FSM + the address-translate path. The old empty M0 `tlb` placeholder stub
  // here is gone (the arrays/lookup/fill/flush live in rtl/mem/tlb.sv now).
  // R2: the L1 I-cache (the `icache` module: arrays + fill + LRU touch + reset) is
  // likewise now instantiated INSIDE the core as u_icache, wired to the fast-path
  // fetch/fill/decode. The old empty M0 `icache` placeholder stub here is gone
  // (the arrays/probes/fill/touch live in rtl/mem/icache.sv now).

  // §6.10 Bus interface unit (M5B-int) -----------------------------------------
  // The gated bus SUBSYSTEM (rtl/bus/biu.sv): a FRONT 32b adapter + the verified
  // pin-level biu_p5 FSM (M5B) + a loopback pin-level responder. The core's
  // memory request enters the FRONT (c_*); the subsystem's abstract BACK side
  // (m2_*) drives an internal memory port (bus_mem_*). It runs UNCONDITIONALLY
  // (cheap, fully self-contained), but it only AFFECTS the core when bus_mode=1
  // — the mux below selects whether the core (and the top mem_* ports) see the
  // direct path or the bus path. In bus_mode=0 its FRONT request is held off
  // (c_req=0), so it is inert.
  logic        bus_mem_req, bus_mem_we;
  logic [31:0] bus_mem_addr, bus_mem_wdata;
  logic [3:0]  bus_mem_wstrb;
  logic [31:0] bus_c_rdata;
  logic        bus_c_ack;

  biu u_biu (
      .clk      (clk),
      .rst_n    (rst_n),
      // FRONT: core 32b request (gated by bus_mode so the subsystem is inert at 0)
      .c_req    (bus_mode ? core_mem_req : 1'b0),
      .c_we     (core_mem_we),
      .c_addr   (core_mem_addr),
      .c_wdata  (core_mem_wdata),
      .c_wstrb  (core_mem_wstrb),
      .c_rdata  (bus_c_rdata),
      .c_ack    (bus_c_ack),
      // BACK: abstract 32b memory -> the top mem_* ports (TB memmodel) in mode 1
      .m2_req   (bus_mem_req),
      .m2_we    (bus_mem_we),
      .m2_addr  (bus_mem_addr),
      .m2_wdata (bus_mem_wdata),
      .m2_wstrb (bus_mem_wstrb),
      .m2_rdata (mem_rdata),
      .m2_ack   (mem_ack)
  );

  // ---- bus_mode mux ----------------------------------------------------------
  // bus_mode=0 (DEFAULT): the top mem_* output ports = the CORE's mem outputs,
  // and the core's mem_rdata/mem_ack = the top mem_* inputs. This is the EXACT
  // existing path — byte-identical, the M4/M5-gated path (the subsystem is
  // bypassed and inert). bus_mode=1: the top mem_* output ports = the bus
  // subsystem's BACK side (m2_* -> the TB memmodel), and the core's mem inputs
  // come from the subsystem FRONT response (c_rdata/c_ack). The core's REQUEST
  // outputs are wired to the FRONT above (gated on bus_mode) — when bus_mode=1
  // the direct mem_* output below is driven by the bus back side instead.
  assign mem_req   = bus_mode ? bus_mem_req   : core_mem_req;
  assign mem_we    = bus_mode ? bus_mem_we    : core_mem_we;
  assign mem_addr  = bus_mode ? bus_mem_addr  : core_mem_addr;
  assign mem_wdata = bus_mode ? bus_mem_wdata : core_mem_wdata;
  assign mem_wstrb = bus_mode ? bus_mem_wstrb : core_mem_wstrb;

  assign core_mem_rdata = bus_mode ? bus_c_rdata : mem_rdata;
  assign core_mem_ack   = bus_mode ? bus_c_ack   : mem_ack;

  // §6.9 System state ----------------------------------------------------------
  sys_state   u_sys     (.clk(clk), .rst_n(rst_n));

endmodule : ventium_top
