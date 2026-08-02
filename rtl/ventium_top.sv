`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

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
`ifdef VEN_PS_PROXY
    input  logic        syscall_resp_valid,  // F4 PS-bridge: int-0x80 response ready
`endif
    // M14: syscall args exposed for the TB free-run emulator (inert otherwise).
    output logic [31:0] syscall_arg_eax,
    output logic [31:0] syscall_arg_ebx,
    output logic [31:0] syscall_arg_ecx,
    output logic [31:0] syscall_arg_edx,
    output logic [31:0] syscall_arg_esi,
    output logic [31:0] syscall_arg_edi,
    output logic [31:0] syscall_arg_ebp,
`ifdef VEN_FPTRAP
    // F4 FP-op PS-trap: FPATAN exposes ST0/ST1; the TB/PS computes atan2 and answers.
    output logic        fptrap_active,
    output logic [3:0]  fptrap_op,
    output logic [79:0] fptrap_st0,
    output logic [79:0] fptrap_st1,
    input  logic        fptrap_resp_valid,
    input  logic [79:0] fptrap_result,
`endif

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
`ifdef VEN_L1_AXI
    // P1-1 bus_mode=2 (l1axi_en): route the core's mem port through ventium_l1_axi
    // (ven_l1d + ven_axi_master) to an AXI4 master that the TB's behavioral DDR
    // slave (or the PS S_AXI_HPC0) services. ALL of this is behind +VEN_L1_AXI so
    // the default build is byte-identical (no extra ports, no mode-2 leg).
    ,
    input  logic        l1axi_en,           // 1 = mode 2 (L1+AXI); 0 = modes 0/1
    input  logic        flush_all,           // #35 pulse to invalidate the L1 (cosim coherency)
    input  logic        golden_l1,           // golden/L1-useless diagnostic mode (flush after each access)
    output logic [3:0]  m_axi_awid,
    output logic [39:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awlock,
    output logic [3:0]  m_axi_awcache,
    output logic [2:0]  m_axi_awprot,
    output logic [3:0]  m_axi_awqos,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [3:0]  m_axi_bid,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic [3:0]  m_axi_arid,
    output logic [39:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arlock,
    output logic [3:0]  m_axi_arcache,
    output logic [2:0]  m_axi_arprot,
    output logic [3:0]  m_axi_arqos,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [3:0]  m_axi_rid,
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    output logic        bus_err,         // #34 fatal AXI fault (PS observes -> reset)
    // clean-shutdown quiesce: R_CTRL.SHUTDOWN stops new AXI txns + drains in-flight;
    // the PS polls m_idle (R_STATUS.AXI_IDLE) before xmutil unloadapp so the PL→PS AXI
    // master is protocol-clean (no outstanding burst) when the overlay is torn down.
    input  logic        shutdown,
    output logic        m_idle
`ifdef VEN_KV260_SOC
    ,
    output logic [63:0] retire_count,     // F2: live retire counter for PS observability
    // F3: PS-driven external-interrupt injection seam (ven_soc_axil R_INTR).
    // soc_en (MODE.SOCEN, default 0 -> the whole divert is dead and the KV260 build
    // behaves exactly as F2) ungates the core's external-interrupt path; intr is the
    // 8259-INT-analogue LEVEL, inta_vector the PS-staged vector the core latches on
    // its inta strobe, inta the 1-clock INTA pulse back to the slave (clears the
    // R_INTR assert + sets its seen bit). NMI has no PS source and stays tied off.
    input  logic        soc_en,
    input  logic        intr,
    input  logic [7:0]  inta_vector,
    output logic        inta
`ifdef VEN_RTL_IRQ
    ,
    // VEN_RTL_IRQ: the 8254 PIT + 8259 PIC move from the PS C models into the PL
    // (instantiated below), so IRQ0's cadence is cycle-deterministic. The PIT owns
    // IR0; the other ISA device IRQ levels (IDE IR14, kbd IR1, RTC IR8, ...) still
    // live in the PS, so the PS publishes them here (ven_soc_axil R_IRQ_IN). Bit 0 is
    // ignored (overwritten by the RTL pit_out0). Only meaningful when VEN_RTL_IRQ is
    // built AND soc_en=1; harmless (tie 0) otherwise.
    input  logic [15:0] dev_irq_ps,
    // VEN_RTL_IRQ_FIXED: the runtime half-period (cyc/2 - 1) for the dense fixed-cycle
    // IR0 square wave below. Driven by ven_soc_axil R_FIXED_IRQ0_HALF; reset there is
    // 1999 (== VEN_FIXED_IRQ0_CYC/2-1 for the default 4000), so an un-written register
    // reproduces today's cadence. Swept on-board via devmem (no FPGA rebuild). Only the
    // VEN_RTL_IRQ_FIXED block reads it; otherwise unused (harmless).
    input  logic [31:0] fixed_irq0_half
`endif
`endif
`endif
`ifdef VEN_DBG_CORE
    ,
    // ---- Debug bundle (VEN_DBG_CORE): committed state + FSM/fault/mode taps.
    // Consumed by tb_main directly (sim post-mortem) and by ven_soc_dbg in the
    // KV260 wrapper (PC ring / freeze latch / perf counters). Pure observers.
    output logic        dbg_retire_valid,  // 1-clock per retired instruction
    output logic [31:0] dbg_eip,           // committed EIP of last retired insn
    output logic [15:0] dbg_cs,            // committed CS selector
    output logic [31:0] dbg_esp,           // committed ESP
    output logic [31:0] dbg_eflags,        // committed EFLAGS
    output logic [5:0]  dbg_state,         // core FSM micro-state (state_e)
    output logic [7:0]  dbg_int_vec,       // last delivered exception/IRQ vector
    output logic [31:0] dbg_fault_pc,      // source EIP of that exception/IRQ
    output logic [31:0] dbg_cr0,           // live CR0 (PE/PG = mode)
    output logic [15:0] dbg_fctrl,         // live x87 control word (PC=[9:8])
    output logic [5:0]  dbg_fxop,          // x87 sub-op currently in flight
    output logic [63:0] dbg_ibuf,          // fetch-window bytes at committed EIP (PM-wedge disasm)
    output logic [63:0] dbg_seg,           // [31:0]=GDTR base, [32]=CS.D (PM-wedge descriptor probe)
    output logic [63:0] dbg_de_num,        // divide-#DE tap: faulting dividend (EDX:EAX)
    output logic [63:0] dbg_de_info,       //   {divisor[31:0], eip[15:0], w[2:0], decnt[12:0]}
    input  logic [15:0] dbg_hook_cfg,      // patchable opcode-capture hook config (PS-armed)
    output logic [7:0]  dbg_hook_seq,      // capture counter (PS rings on change)
    output logic [31:0] dbg_hook_eip,
    output logic [63:0] dbg_hook_opa,
    output logic [31:0] dbg_hook_opb,
    output logic [31:0] dbg_hook_meta,
    // DOS-Quake divergence tap: the EIP of the LAST cs=0x2b (>=0x3000) instruction
    // RETIRED — captures fast-path AND slow-path retires (the prior S_DECODE hook
    // missed fast-path insns). At the #DE this holds the wild-jump origin.
    // PS-PROGRAMMABLE retire comparator (no respin to retarget): the PS writes the
    // match terms (cmp_cfg = {eip_care,cs_care,en, match_cs[15:0]}, cmp_range =
    // {eip_hi[15:0], eip_lo[15:0]}) and reads back the last + previous matching
    // retired EIP and a {seq,cs} info word. Captures fast-path AND slow-path retires.
    input  logic [31:0] dbg_cmp_cfg,
    input  logic [31:0] dbg_cmp_range,
    output logic [31:0] dbg_div_eip,     // last matching retired EIP
    output logic [31:0] dbg_div_eip70,   // previous matching retired EIP (1-deep history)
    output logic [31:0] dbg_div_info,    // {seq[15:0], matched cs[15:0]}
    output logic        dbg_cmp_freeze,  // 1-clk pulse on comparator freeze -> freezes the PC ring
    // F4 read-beat trace: each accepted AXI read beat {DDR addr, data} from the
    // L1/AXI master (l1axi_en builds) -> ven_soc_dbg ring (corrupted-fill forensics).
    output logic        dbg_rd_valid,
    output logic [31:0] dbg_rd_addr,
    output logic [31:0] dbg_rd_data,
    // single-step / breakpoint control (pass-through to the core)
    input  logic        dbg_halt_req,
    input  logic        dbg_step,
    input  logic        dbg_bp_en,
    input  logic [31:0] dbg_bp_addr,
    input  logic        dbg_bp_clr,
    output logic        dbg_halted
`endif
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
  logic core_mem_lock;   // REVIEW1_Aug2 C-10
  logic [31:0] core_mem_addr, core_mem_wdata;
  logic [31:0] core_mem_lin;   // task #51: pre-translate linear addr for the SMC snoop
  logic [3:0]  core_mem_wstrb;
  logic [31:0] core_mem_rdata;
  logic        core_mem_ack;

  // M8.1: the core's INTERRUPT-ACKNOWLEDGE strobe output is the M8 ventium_soc's
  // (it drives the 8259). ventium_top (the verification top) ties off the
  // external-interrupt path (soc_en=0), so this output is always 0 and unused
  // here — sink it so -Wall stays clean. In the KV260 SoC build the path is REAL
  // (the F3 PS-injection seam drives it), so the sink only exists otherwise.
`ifndef VEN_KV260_SOC
  logic        soc_inta_unused;
`endif

`ifdef VEN_RTL_IRQ
  // ===========================================================================
  // VEN_RTL_IRQ: the 8254 PIT + 8259 PIC, moved from the PS C models into the PL
  // so the IRQ0 cadence is cycle-deterministic. Mirrors rtl/soc/ventium_soc.sv
  // (the all-RTL SoC) exactly. All of this is behind `ifdef VEN_RTL_IRQ; the
  // default KV260 build (no +define) keeps the PS-PIC R_INTR path byte-identical.
  // ---------------------------------------------------------------------------
  // Intercepted core io seam: the core binds io_* to these cio_* nets; the PIT/PIC
  // are decoded off them and the PS-facing io_* ports carry the non-PIT/PIC remainder.
  logic        cio_req, cio_we;
  logic [15:0] cio_addr;
  logic [2:0]  cio_size;
  logic [31:0] cio_wdata, cio_rdata;
  logic        cio_ack;
  // INTR/INTA handshake to the RTL PIC + its read data + device-IRQ assembly.
  logic        pic_int_out;       // u_pic.int_out -> core.intr
  logic        core_inta_w;       // core.inta     -> u_pic.inta (and the top inta port)
  logic [7:0]  pic_inta_vector;   // u_pic.inta_vector -> core.inta_vector
  logic [7:0]  pic_rdata, pit_rdata;
  logic        pit_out0;          // PIT ch0 OUT -> PIC IR0
  logic [15:0] pic_irq_in;
  // cs decode off the core's io request (same ports as ventium_soc.sv).
  logic        cs_pic, cs_pit;
  always_comb begin
    cs_pic = cio_req && (cio_addr == 16'h0020 || cio_addr == 16'h0021 ||
                         cio_addr == 16'h00A0 || cio_addr == 16'h00A1 ||
                         cio_addr == 16'h04D0 || cio_addr == 16'h04D1);
    cs_pit = cio_req && (cio_addr == 16'h0040 || cio_addr == 16'h0041 ||
                         cio_addr == 16'h0042 || cio_addr == 16'h0043);
  end

  // ---------------------------------------------------------------------------
  // WNS FIX (routed bitstream): the in-PL PIT/PIC are placed FAR from the core,
  // so the combinational path GPR -> core-IO-write-logic -> cio_wdata ->
  // u_pit.wdata -> latched_count was the critical path (33.8ns @40MHz). Break it
  // with a PIPELINE REGISTER: the PIT/PIC-bound request payload (we/addr/wdata
  // and the per-device chip-select) is REGISTERED into pp_* flops before reaching
  // ven_pit/ven_pic, the device rdata is captured back into a flop, and cio_ack
  // for PIT/PIC is delayed by the added latency. The core holds io_req asserted
  // until io_ack (S_IO waits), so the payload is stable across the added cycles —
  // a textbook wait-for-ack stall. PIT/PIC I/O is rare (outb/inb), so the extra
  // latency is functionally invisible; only the fmax improves. The device cs is
  // pulsed for EXACTLY ONE cycle (pp_cs_* set in IDLE, cleared in RUN) so the
  // PIT/PIC clocked write- and read-side-effects fire once per transaction, just
  // as the un-pipelined same-cycle ack did. The INTR/INTA path (pic_int_out /
  // core_inta_w / irq_in / inta_vector) is NOT part of the IO bus and stays direct.
  // 3-state stall: IDLE -> RUN (1-cyc device cs, capture rdata) -> ACK (raise
  // cio_ack) -> IDLE. Latency = 2 core clocks per PIT/PIC access.
  localparam logic [1:0] PP_IDLE = 2'd0, PP_RUN = 2'd1, PP_ACK = 2'd2;
  logic [1:0]  pp_state;
  logic        pp_we;            // registered cio_we for the device
  logic [15:0] pp_addr;          // registered cio_addr for the device
  logic [31:0] pp_wdata;         // registered cio_wdata (the GPR-sourced datum) for the device
  logic        pp_sel_pit, pp_sel_pic;   // which device this in-flight access targets
  logic        pp_cs_pit, pp_cs_pic;     // 1-cycle registered chip-select -> u_pit/u_pic.cs
  logic [7:0]  pp_rdata;         // captured device read data (presented at ack)
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pp_state   <= PP_IDLE;
      pp_we      <= 1'b0;
      pp_addr    <= 16'd0;
      pp_wdata   <= 32'd0;
      pp_sel_pit <= 1'b0;
      pp_sel_pic <= 1'b0;
      pp_cs_pit  <= 1'b0;
      pp_cs_pic  <= 1'b0;
      pp_rdata   <= 8'd0;
    end else begin
      unique case (pp_state)
        PP_IDLE: begin
          pp_cs_pit <= 1'b0;
          pp_cs_pic <= 1'b0;
          // Latch a FRESH PIT/PIC request (held stable by the core until ack) and
          // launch the registered chip-select for the next (RUN) cycle.
          if (cs_pit || cs_pic) begin
            pp_we      <= cio_we;
            pp_addr    <= cio_addr;
            pp_wdata   <= cio_wdata;
            pp_sel_pit <= cs_pit;
            pp_sel_pic <= cs_pic;
            pp_cs_pit  <= cs_pit;   // one-cycle pulse: asserted in RUN, cleared below
            pp_cs_pic  <= cs_pic;
            pp_state   <= PP_RUN;
          end
        end
        PP_RUN: begin
          // The device sees pp_cs_* this cycle: a write commits on this edge; the
          // combinational rdata (off the registered pp_addr) is valid now -> capture.
          pp_rdata  <= pp_sel_pit ? pit_rdata : pic_rdata;
          pp_cs_pit <= 1'b0;        // drop cs -> the write/read side-effect fires ONCE
          pp_cs_pic <= 1'b0;
          pp_state  <= PP_ACK;
        end
        PP_ACK: begin
          // cio_ack asserts combinationally this cycle (see below); the core samples
          // pp_rdata and advances out of S_IO. Return to IDLE.
          pp_state <= PP_IDLE;
        end
        default: pp_state <= PP_IDLE;
      endcase
    end
  end
  // device-IRQ assembly: the PS publishes the non-timer ISA IRQ levels via
  // dev_irq_ps (R_IRQ_IN); IR0 is the timer.
`ifdef VEN_RTL_IRQ_FIXED
  // VEN_RTL_IRQ_FIXED: drive IR0 from a DENSE fixed-cycle square wave (period
  // VEN_FIXED_IRQ0_CYC core-clocks, default 4000 = the proven-clean dense cadence)
  // instead of the guest-programmed RTL PIT. ROOT CAUSE: the sparse real-rate PIT
  // never fires DURING CWSDPMI's int-0x31 reflector to preempt it, so int-0x31 wins
  // the shared dispatch -> the 0x60 task resumes at cs=0x2b (CPL3) -> the DOS-Quake
  // #DE. A dense IRQ0 preempts the reflector (-> the timer's cs=0x18 CPL0 dispatch
  // -> clean). A count-honoring PIT can't reach this density (count=0x10000 => >=64k
  // cyc/IRQ0 even at TICK_DIV=1). The guest time-of-day runs fast, but a timedemo
  // (renders every frame regardless) is unaffected. PIT register reads stay correct
  // (the RTL PIT is still wired); only IR0's edge source changes.
  // VEN_FIXED_IRQ0_CYC is now only the RESET DEFAULT (mirrored by ven_soc_axil's
  // R_FIXED_IRQ0_HALF reset = VEN_FIXED_IRQ0_CYC/2 - 1 = 1999 for the default 4000).
  // The LIVE threshold is the runtime register fixed_irq0_half, swept via devmem.
  `ifndef VEN_FIXED_IRQ0_CYC
    `define VEN_FIXED_IRQ0_CYC 4000
  `endif
  // Effective threshold: the runtime register, with 0 as a "use the compile-time
  // default" sentinel. The board drives a reset of 1999 (== 4000/2-1) via ven_soc_axil,
  // so it never reads 0 there; the bare-ventium_top sim leaves the port undriven (=0),
  // which falls back to the SAME 1999 => the default sim reproduces today's 4000-cycle
  // IR0 with no testbench change. A half-period of 0 is degenerate anyway (it would
  // toggle every cycle), so 0 is a safe sentinel — the densest sweep value of interest
  // is 128. Swept (any non-zero) on-board via devmem with no FPGA rebuild.
  logic [31:0] fxirq_half_eff;
  assign fxirq_half_eff = (fixed_irq0_half == 32'd0)
                        ? ($unsigned(`VEN_FIXED_IRQ0_CYC)/2 - 1)
                        : fixed_irq0_half;
  logic [31:0] fxirq_cnt;
  logic        fxirq_lvl;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fxirq_cnt <= '0; fxirq_lvl <= 1'b0;
    end else if (fxirq_cnt >= fxirq_half_eff) begin
      fxirq_cnt <= '0; fxirq_lvl <= ~fxirq_lvl;   // half-period toggle => square wave
    end else begin
      fxirq_cnt <= fxirq_cnt + 1'b1;
    end
  end
`endif
  always_comb begin
    pic_irq_in    = dev_irq_ps;
`ifdef VEN_RTL_IRQ_FIXED
    pic_irq_in[0] = fxirq_lvl;     // dense fixed-cycle IRQ0 (preempts the reflector)
`else
    pic_irq_in[0] = pit_out0;      // RTL PIT (honors the guest-programmed count)
`endif
  end
  // io seam interception: PIT/PIC accesses are now PIPELINED (the pp_* stall above
  // breaks the long GPR->device path); their read data comes from the captured
  // pp_rdata flop and their ack is delayed to PP_ACK. Every other port still goes to
  // the PS (waits on io_ack). The PS-facing io_req is gated so the PS never sees a
  // PIT/PIC access; io_we/addr/size/wdata pass through unchanged.
  assign cio_rdata = (cs_pit || cs_pic) ? {24'd0, pp_rdata}   // captured device read data
                   : io_rdata;                                // PS-returned data
  assign cio_ack   = (cs_pit || cs_pic) ? (pp_state == PP_ACK) : io_ack;
  assign io_req    = cio_req && !(cs_pit || cs_pic);
  assign io_we     = cio_we;
  assign io_addr   = cio_addr;
  assign io_size   = cio_size;
  assign io_wdata  = cio_wdata;
`endif

  // The A20 CONTROL LATCH lives in the core (see core.sv `a20_r`), because the core
  // is the only place that observes every I/O write in every configuration: the
  // port-0x92 OUT is serviced by the PS in one build, by a co-sim DPI hook in another,
  // and by in-PL devices in a third, and the top-level io_ack handshake is not visible
  // at a clock edge here in all of them. This input is the PLATFORM OVERRIDE: a real
  // chipset can force A20 low by driving it 0, and the core ANDs the two. Tied high
  // here, which is the normal "A20 enabled unless software says otherwise" state.
  logic a20_gate_r;
  assign a20_gate_r = 1'b1;

  core u_core (
      .clk          (clk),
      .rst_n        (rst_n),
      .a20_gate     (a20_gate_r),        // REVIEW2 M-03
      // REVIEW1_Aug2 M-07: the port-0x92 fast-reset request. Left unconnected
      // here -- this checkout has no reset controller to drive -- but it is now
      // a real output a platform can wire, and the core stops on its own so the
      // request cannot be silently ignored the way bit 0 was.
      .fast_reset_req (),
      .init_eip     (init_eip),
      .init_esp     (init_esp),
      .boot_mode    (boot_mode),
      .cycle_mode   (cycle_mode),
`ifdef VEN_L1_AXI
      .real_bus     (l1axi_en),
      .bus_err      (l1_bus_err),
      // Phase D.6: northbridge → icache snoop (DMA-loaded code coherence).
      .smm_active_o   (core_smm_active),   // REVIEW2 H-24
      .ic_snoop_valid (ic_snoop_v),
      .ic_snoop_addr  (ic_snoop_a),
      .ic_snoop_valid1(ic_snoop_v1),
      .ic_snoop_addr1 (ic_snoop_a1),   // H-09
      .ic_snoop_valid2(ic_snoop_v2),
      .ic_snoop_addr2 (ic_snoop_a2),
      .ic_flush_all   (flush_all),        // H-12: global I-cache invalidate
`endif
      .errata_en    (errata_en),
      .cpu_hung     (cpu_hung),
      .proxy_en           (proxy_en),
      .syscall_active     (syscall_active),
      .syscall_n          (syscall_n),
      .syscall_resume_eip (syscall_resume_eip),
      .syscall_eax        (syscall_eax),
      .syscall_apply_gs   (syscall_apply_gs),
      .syscall_gs_base    (syscall_gs_base),
`ifdef VEN_PS_PROXY
      .syscall_resp_valid (syscall_resp_valid),
`endif
`ifdef VEN_FPTRAP
      .fptrap_active      (fptrap_active),
      .fptrap_op          (fptrap_op),
      .fptrap_st0         (fptrap_st0),
      .fptrap_st1         (fptrap_st1),
      .fptrap_resp_valid  (fptrap_resp_valid),
      .fptrap_result      (fptrap_result),
`endif
      .syscall_arg_eax    (syscall_arg_eax),
      .syscall_arg_ebx    (syscall_arg_ebx),
      .syscall_arg_ecx    (syscall_arg_ecx),
      .syscall_arg_edx    (syscall_arg_edx),
      .syscall_arg_esi    (syscall_arg_esi),
      .syscall_arg_edi    (syscall_arg_edi),
      .syscall_arg_ebp    (syscall_arg_ebp),
      .cosim_en     (cosim_en),
`ifdef VEN_RTL_IRQ
      // VEN_RTL_IRQ: the core's io_* bus is INTERCEPTED below (the PIT/PIC live in
      // the PL, not the PS), so it binds to internal cio_* nets. The PS-facing io_*
      // OUTPUT ports are driven from cio_* MINUS the PIT/PIC port range (so the PS
      // never sees 0x40-0x43 / 0x20-0x21 / 0xA0-0xA1 / 0x4D0-0x4D1 I/O).
      .io_req       (cio_req),
      .io_we        (cio_we),
      .io_addr      (cio_addr),
      .io_size      (cio_size),
      .io_wdata     (cio_wdata),
      .io_rdata     (cio_rdata),
      .io_ack       (cio_ack),
`else
      .io_req       (io_req),
      .io_we        (io_we),
      .io_addr      (io_addr),
      .io_size      (io_size),
      .io_wdata     (io_wdata),
      .io_rdata     (io_rdata),
      .io_ack       (io_ack),
`endif
`ifdef VEN_KV260_SOC
      // F3 KV260: the PS injects maskable INTR through ven_soc_axil R_INTR. soc_en
      // comes from MODE bit 6 (default 0 -> this whole path is dead and the F2 KV260
      // behavior is unchanged). inta_valid mirrors the intr level: the staged vector
      // is meaningful exactly while the injection is asserted (the divert latches
      // inta_vector unconditionally anyway, like the always-valid master 8259).
`ifdef VEN_RTL_IRQ
      // VEN_RTL_IRQ: the maskable INTR comes from the RTL 8259 (u_pic) below, not the
      // PS R_INTR seam. soc_en still ungates the divert (the PS sets MODE.SOCEN). The
      // core's inta strobe drives u_pic.inta; inta is ALSO exposed on the top port so
      // the PS still sees the INTA boundary (it intacks its device-IRQ bookkeeping).
      .soc_en       (soc_en),
      .intr         (pic_int_out),
      .nmi          (1'b0),
      .inta         (core_inta_w),
      .inta_vector  (pic_inta_vector),
      .inta_valid   (1'b1),            // the master 8259 always supplies a vector
`else
      .soc_en       (soc_en),
      .intr         (intr),
      .nmi          (1'b0),
      .inta         (inta),
      .inta_vector  (inta_vector),
      .inta_valid   (intr),
`endif
`else
      // M8.1: the external-interrupt path is the M8 ventium_soc's; ventium_top
      // (the verification top) TIES IT OFF so every existing gate stays
      // byte-identical. soc_en=0 makes the whole divert dead; the input pins are
      // 0 and inta is left dangling (driven 0 by the core, never observed here).
      .soc_en       (1'b0),
      .intr         (1'b0),
      .nmi          (1'b0),
      .inta         (soc_inta_unused),
      .inta_vector  (8'd0),
      .inta_valid   (1'b0),
`endif
      .mem_req      (core_mem_req),
      .mem_we       (core_mem_we),
      // REVIEW1_Aug2 C-10: the locked-RMW request, carried to the bus wrapper.
      .mem_lock     (core_mem_lock),
      .mem_addr     (core_mem_addr),
      .mem_lin      (core_mem_lin),
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
`ifdef VEN_DBG_CORE
      ,
      .dbg_state    (dbg_state),
      .dbg_int_vec  (dbg_int_vec),
      .dbg_div_fault(core_div_fault),
      .dbg_fault_cnt(core_fault_cnt),
      .dbg_fault_pc (dbg_fault_pc),
      .dbg_cr0      (dbg_cr0),
      .dbg_fctrl    (dbg_fctrl),
      .dbg_fxop     (dbg_fxop),
      .dbg_ibuf     (dbg_ibuf),
      .dbg_de_num   (dbg_de_num),
      .dbg_de_info  (dbg_de_info),
      .dbg_hook_cfg (dbg_hook_cfg), .dbg_hook_seq(dbg_hook_seq), .dbg_hook_eip(dbg_hook_eip),
      .dbg_hook_opa (dbg_hook_opa), .dbg_hook_opb(dbg_hook_opb), .dbg_hook_meta(dbg_hook_meta),
      .dbg_seg      (dbg_seg),
      .dbg_halt_req (dbg_halt_req),
      .dbg_step     (dbg_step),
      .dbg_bp_en    (dbg_bp_en),
      .dbg_bp_addr  (dbg_bp_addr),
      .dbg_bp_clr   (dbg_bp_clr),
      .dbg_halted   (dbg_halted)
`endif
  );

`ifdef VEN_RTL_IRQ
  // ===========================================================================
  // VEN_RTL_IRQ device instances (copied from rtl/soc/ventium_soc.sv). The PIT's
  // IR0 cadence is now a fixed function of the core clock / TICK_DIV — fully
  // cycle-deterministic — instead of the PS pacing it over R_INTR.
  // ===========================================================================
  // The top-level inta output still carries the INTA boundary so the PS can intack
  // its remaining device-IRQ bookkeeping (IDE/kbd/RTC), even though the RTL PIC now
  // resolves the priority/vector. dev_rst is the PC active-HIGH reset (core is _n).
  assign inta = core_inta_w;
  logic dev_rst_irq;
  assign dev_rst_irq = ~rst_n;

  ven_pic u_pic (
      .clk         (clk),
      .rst         (dev_rst_irq),
      // WNS FIX: the IO-bus request is REGISTERED (pp_* pipeline above) before
      // reaching the device — pp_cs_pic is a 1-cycle pulse, pp_we/pp_addr/pp_wdata
      // are the latched datum. The INTR/INTA pins below are NOT IO-bus and stay direct.
      .cs          (pp_cs_pic),
      .we          (pp_we),
      .addr        (pp_addr),
      .wdata       (pp_wdata[7:0]),      // byte I/O (outb/inb)
      .rdata       (pic_rdata),
      .irq_in      (pic_irq_in),
      .int_out     (pic_int_out),
      .inta        (core_inta_w),
      .inta_vector (pic_inta_vector)
  );

  // ven_pit: the tick is prescaled from clk by VEN_PIT_TICK_DIV (default 1024) so the
  // IRQ0 cadence is far slower than the instruction rate; overridable via +define for
  // a faster sim timer. Identical to the ventium_soc.sv instance.
`ifndef VEN_PIT_TICK_DIV
  `define VEN_PIT_TICK_DIV 1024
`endif
  localparam int unsigned PIT_TICK_DIV = `VEN_PIT_TICK_DIV;
  ven_pit #(.TICK_DIV(PIT_TICK_DIV), .TICK_INC(1)) u_pit (
      .clk    (clk),
      .rst    (dev_rst_irq),
      // WNS FIX: registered IO-bus request (pp_* pipeline above). pp_cs_pit is a
      // 1-cycle pulse so the count/control write commits exactly once; pp_wdata is
      // the latched GPR datum — this flop is what breaks the GPR->latched_count path.
      .cs     (pp_cs_pit),
      .we     (pp_we),
      .addr   (pp_addr),
      .wdata  (pp_wdata[7:0]),
      .rdata  (pit_rdata),
      .out0   (pit_out0)
  );
`endif

`ifdef VEN_DBG_CORE
  // Committed-state half of the debug bundle (tapped from the retire wires the
  // DPI point already uses). Pure observers; valid in the same clock as the
  // retire pulse, then held until the next retire.
  assign dbg_retire_valid = core_retire_valid;
  assign dbg_eip          = core_retire_pc;
  assign dbg_cs           = core_retire_state.cs;
  assign dbg_esp          = core_retire_state.esp;
  assign dbg_eflags       = core_retire_state.eflags;
`endif

  // ---------------------------------------------------------------------------
  // Single DPI retire point (docs/rtl-interface.md §2).  retire_n is the core's
  // own retire counter (starts at 0, +1 per retired instruction).  The core
  // pulses retire_valid for exactly one clock per committed instruction with the
  // post-commit architectural state; we emit one vtm_retire call here.
  // ---------------------------------------------------------------------------
  logic [63:0] retire_n;

`ifdef VEN_DBG_CORE
  // PS-programmable retire comparator: match terms in dbg_cmp_cfg/dbg_cmp_range.
  //   cfg[15:0]=match_cs  cfg[16]=enable  cfg[17]=cs_care  cfg[18]=eip_care
  //   range[15:0]=eip_lo  range[31:16]=eip_hi   (eip compared on [15:0])
  // Latches the last + previous matching retired EIP (fast + slow path) + {seq,cs}.
  //   cfg[19]=freeze mode  cfg[31:24]=skip count (freeze on the Nth match, N=skip)
  // FREEZE-ON-Nth-MATCH: when the match count reaches the skip, latch + stop the
  // comparator AND pulse dbg_cmp_freeze, which freezes the PC ring (ven_soc_dbg)
  // so a subsequent #DE triple-fault -> CPU reset cannot overwrite the trail.
  // Re-arm by toggling enable (cfg[16]) low->high.
  logic [15:0] cmp_seq_q, cmp_cs_q;
  logic        cmp_frozen;
  logic        core_div_fault;   // core's sticky divide-#DE flag (driven by the core instance)
  logic [7:0]  core_fault_cnt;   // count of all exception deliveries (fault-freeze skip)
  wire cmp_hit = core_retire_valid && dbg_cmp_cfg[16]
       && (!dbg_cmp_cfg[17] || dbg_cs == dbg_cmp_cfg[15:0])
       && (!dbg_cmp_cfg[18] || (dbg_eip[15:0] >= dbg_cmp_range[15:0]
                              && dbg_eip[15:0] <= dbg_cmp_range[31:16]));
  wire cmp_do_freeze = dbg_cmp_cfg[19] && cmp_hit && !cmp_frozen
                       && (cmp_seq_q >= dbg_cmp_cfg[31:24]);
  // cfg[20]=freeze-on-#DE: the moment a divide #DE fires (core_div_fault), freeze
  // the PC ring -> capture the trajectory INTO the fault before the reboot/reset.
  // cfg[22]=fault-freeze: freeze on the Nth exception delivery (skip=cfg[31:24]) so the
  // clock freezes at the drift's fault BEFORE the triple-fault rst_n wipes the ring.
  assign dbg_cmp_freeze = cmp_do_freeze || (dbg_cmp_cfg[20] && core_div_fault)
                          || (dbg_cmp_cfg[22] && (core_fault_cnt >= dbg_cmp_cfg[31:24]) && (dbg_cmp_cfg[31:24] != 8'd0));
  assign dbg_div_info   = {cmp_seq_q, cmp_cs_q};
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dbg_div_eip <= 32'd0; dbg_div_eip70 <= 32'd0;
      cmp_seq_q <= 16'd0; cmp_cs_q <= 16'd0; cmp_frozen <= 1'b0;
    end else if (!dbg_cmp_cfg[16]) begin
      cmp_frozen <= 1'b0; cmp_seq_q <= 16'd0;   // disarmed -> re-arm fresh
    end else if (cmp_hit && !cmp_frozen) begin
      dbg_div_eip70 <= dbg_div_eip;   // prev <- last
      dbg_div_eip   <= dbg_eip;       // last <- this match
      cmp_seq_q     <= cmp_seq_q + 16'd1;
      cmp_cs_q      <= dbg_cs;
      if (cmp_do_freeze) cmp_frozen <= 1'b1;
    end
  end
`endif

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

`ifdef VEN_KV260_SOC
  // F2: expose the retire counter so the PS can observe forward progress (the DPI
  // vtm_retire path above is sim-only). Gated to the KV260 SoC build — the cosim /
  // L1AXI builds (no VEN_KV260_SOC) don't get this port, staying byte-identical.
  assign retire_count = retire_n;
`endif

  // ---------------------------------------------------------------------------
  // Block decomposition (PLAN §6) — NO top-level stubs remain. The §6 leaf
  // blocks are all realized inside the core (rtl/core/core.sv): the real leaf
  // MODULES bpred_btb / decode / issue_uv / dcache_timing / icache / tlb /
  // fpu_top are instantiated within core.sv (wired into the datapath, not tied
  // off); and the front-end FETCH, the integer EXECUTE, the GPR file (REGFILE),
  // and the SYSTEM STATE (CRx/seg-hidden/GDTR/IDTR/TR/DR) are SPINE-BOUND — their
  // logic IS the core's pipeline FSM, not a separable unit — so the old empty M0
  // fetch/exec_int/regfile/sys_state placeholder stubs were removed (like the
  // ucode_rom stub before them). regfile is a true dual-issue 2-write-port file;
  // it COULD be lifted to a state-bank module later (the fpu_top pattern) for a
  // clean R2 6-of-6, but the others are inherently FSM-resident.
  // ---------------------------------------------------------------------------

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
      .c_lock   (core_mem_lock),   // REVIEW1_Aug2 C-10
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
`ifdef VEN_L1_AXI
  // ---- bus_mode=2 (l1axi_en): the L1+AXI subsystem ---------------------------
  // ventium_l1_axi sits between the core's mem port and the AXI4 master (the TB
  // behavioral DDR slave / PS S_AXI_HPC0). On l1axi_en the core's responses come
  // from it (l1_c_rdata/l1_c_ack) and the direct mem_* output is held INERT so the
  // TB's same-cycle MemModel does not double-service (all memory goes via m_axi).
  // REMAP_BASE=0 (identity) for the cosim: the MemModel is x86-phys-indexed.
  // On the KV260 the core's x86 physical space must land in the reserved DDR
  // carveout at 0x4000_0000 (the BD's SEG_carveout + the PetaLinux/Ubuntu
  // reserved-memory node) — KV260_SOC_DESIGN.md "REMAP_BASE override". Without
  // it the PL emits raw low addresses on HPC0, outside the declared segment.
`ifdef VEN_KV260_SOC
  localparam logic [39:0] L1AXI_REMAP_BASE = 40'h0_4000_0000;
  // 256 MiB-wrap ADDR_MASK: folds the whole x86 phys space (incl. the top-of-4G BIOS
  // shadow 0xFFFE_0000-0xFFFF_FFFF that SeaBIOS's 32-bit POST runs from) into the
  // 256 MiB carveout — phys 0xFFFE_0000 & 0x0FFF_FFFF = 0x0FFE_0000 -> DDR 0x4FFE_0000.
  // The PS stages a 2nd BIOS copy there (carveout off 0x0FFE_0000). Lets the PROVEN
  // stock SeaBIOS+FreeDOS stack boot on the board without the 4G alias faulting (all
  // FreeDOS accesses are < 256 MiB, so the wrap only affects the BIOS shadow). Cosim/
  // L1AXI-verify builds (no KV260_SOC) keep the full 0xFFFFFFFF mask, unchanged.
  localparam logic [31:0] L1AXI_ADDR_MASK = 32'h0FFF_FFFF;
`else
  localparam logic [39:0] L1AXI_REMAP_BASE = 40'h0;
  localparam logic [31:0] L1AXI_ADDR_MASK  = 32'hFFFF_FFFF;
`endif
  logic [31:0] l1_c_rdata; logic l1_c_ack; logic l1_bus_err;
  logic        core_smm_active;                       // REVIEW2 H-24: core SMM state
  logic        ic_snoop_v; logic [31:0] ic_snoop_a;   // Phase D.6: NB → icache snoop
  logic        ic_snoop_v1; logic [31:0] ic_snoop_a1; // H-09: SMC store, first line
  logic        ic_snoop_v2; logic [31:0] ic_snoop_a2; // H-09: SMC store, second line
  assign bus_err = l1_bus_err;   // #34 expose the fatal AXI fault to the PS
  // REVIEW2 M-04: pass the L1D geometry DOWN. This instantiation used to override
  // nothing, so ventium_l1_axi (and therefore ven_l1d) stayed at its 128-set default
  // even in a +VEN_CACHE_HALF build where the core's own D$ model had shrunk to 64 --
  // the advertised half-cache config did not shrink the cache that holds the data.
  // ventium_pkg::L1D_SETS_DEF is the single definition the core uses for DC_SETS.
  ventium_l1_axi #(.ADDR_W(40), .REMAP_BASE(L1AXI_REMAP_BASE), .ADDR_MASK(L1AXI_ADDR_MASK),
                   .L1_SETS(ventium_pkg::L1D_SETS_DEF)) u_l1axi (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all (flush_all),
      .golden_l1 (golden_l1),
      .shutdown  (shutdown), .m_idle (m_idle),
      .smm_active         (core_smm_active),            // REVIEW2 H-24
      .icache_snoop_valid (ic_snoop_v), .icache_snoop_addr (ic_snoop_a),
      .icache_snoop_valid1(ic_snoop_v1), .icache_snoop_addr1(ic_snoop_a1),   // H-09
      .icache_snoop_valid2(ic_snoop_v2), .icache_snoop_addr2(ic_snoop_a2),
`ifdef VEN_DBG_CORE
      .dbg_rd_valid (dbg_rd_valid), .dbg_rd_addr (dbg_rd_addr), .dbg_rd_data (dbg_rd_data),
`endif
      .core_req  (l1axi_en ? core_mem_req : 1'b0),   // L1 inert in modes 0/1
      .core_we   (core_mem_we),
      .core_addr (core_mem_addr), .core_lin (core_mem_lin),
      .core_wdata(core_mem_wdata),
      .core_wstrb(core_mem_wstrb),
      .core_rdata(l1_c_rdata),
      .core_ack  (l1_c_ack),
      .bus_err   (l1_bus_err),
      .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
      .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos),
      .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata),
      .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
      .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
      .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready), .m_axi_arid(m_axi_arid),
      .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
      .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache),
      .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos), .m_axi_arvalid(m_axi_arvalid),
      .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
      .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
      .m_axi_rready(m_axi_rready)
`ifdef VEN_L1_HONOR_CD
      // live CR0.CD (core_cr0 = continuous `assign retire_cr0 = creg0`, so valid every
      // cycle, not just on retire). CD=1 (BIOS POST memory test) => L1 D$ honors the
      // cache-disable and bypasses (no 8-beat write-allocate fill amplification).
      , .cr0_cd(core_cr0[30])
`endif
  );

  assign mem_req   = l1axi_en ? 1'b0 : (bus_mode ? bus_mem_req   : core_mem_req);
  assign mem_we    = l1axi_en ? 1'b0 : (bus_mode ? bus_mem_we    : core_mem_we);
  assign mem_addr  = l1axi_en ? 32'd0 : (bus_mode ? bus_mem_addr  : core_mem_addr);
  assign mem_wdata = l1axi_en ? 32'd0 : (bus_mode ? bus_mem_wdata : core_mem_wdata);
  assign mem_wstrb = l1axi_en ? 4'd0 : (bus_mode ? bus_mem_wstrb : core_mem_wstrb);

  assign core_mem_rdata = l1axi_en ? l1_c_rdata : (bus_mode ? bus_c_rdata : mem_rdata);
  assign core_mem_ack   = l1axi_en ? l1_c_ack   : (bus_mode ? bus_c_ack   : mem_ack);
`else
  assign mem_req   = bus_mode ? bus_mem_req   : core_mem_req;
  assign mem_we    = bus_mode ? bus_mem_we    : core_mem_we;
  assign mem_addr  = bus_mode ? bus_mem_addr  : core_mem_addr;
  assign mem_wdata = bus_mode ? bus_mem_wdata : core_mem_wdata;
  assign mem_wstrb = bus_mode ? bus_mem_wstrb : core_mem_wstrb;

  assign core_mem_rdata = bus_mode ? bus_c_rdata : mem_rdata;
  assign core_mem_ack   = bus_mode ? bus_c_ack   : mem_ack;
`endif

  // M8.1 lint sink: the tied-off core inta output (soc_en=0 here; in the KV260 SoC
  // build the inta strobe is a REAL output port, so there is nothing to sink).
`ifndef VEN_KV260_SOC
  // verilator lint_off UNUSED
  wire _unused_soc = &{1'b0, soc_inta_unused};
  // verilator lint_on UNUSED
`endif

endmodule : ventium_top
