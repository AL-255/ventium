// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ven_soc_axil.sv — PS<->PL control + port-I/O bridge AXI4-Lite slave (KV260, F2).
//
// The KV260 SoC is PS-ASSISTED: the PL holds only the core + L1 + the AXI4 master to
// PS-DDR; the PS A53 emulates ALL slow peripherals in software (the cosim's C++ device
// models, moved onto the A53). This slave is the control + I/O seam between them, on
// PS M_AXI_HPM0_FPD. It does THREE jobs:
//   1. CONTROL: the PS holds the core in reset (CORE_RUN=0 at reset), writes the boot
//      config (init_eip/init_esp/boot_mode + mode bits), then releases CORE_RUN to run.
//   2. STATUS:  the PS reads cpu_hung / bus_err and the retire counter.
//   3. PORT-I/O BRIDGE: the core's IN/OUT (io_* bus) is captured here; the core STALLS
//      cleanly in S_IO (`if (io_ack) ...` with no else — core_io.svh:22-41) so the
//      bridge simply HOLDS io_ack=0, raises an interrupt to the PS, and on the PS's ACK
//      pulses io_ack=1 for ONE cycle with the IN data. No core RTL change needed.
//
// Single pl_clk0 domain (== the core/L1/HPC0 clock), so the io_* seam has NO CDC — only
// the level-high irq_out crosses to the GIC. All gated into the KV260 build; the default
// cosim build never instantiates this, so M0-M14 stay byte-identical.
//
// The int-0x80 syscall window (offsets 0x40-0x6C) + its ports are RESERVED here for the
// Quake user-mode path (F4, +VEN_PS_PROXY, the gated S_SYSCALL_WAIT core change); this
// A1 deliverable implements the control + status + retire + IO seam that F2/F3 need.

module ven_soc_axil #(
    parameter int AXIL_AW = 16,                 // 64 KiB aperture
    parameter logic [31:0] IDENT = 32'h5654_4D43 // "VTMC"
) (
    input  logic        clk,                    // pl_clk0
    input  logic        aresetn,                // peripheral_aresetn (active-low)

    // ---- AXI4-Lite slave (PS M_AXI_HPM0_FPD) ----------------------------------
    input  logic [AXIL_AW-1:0] s_axil_awaddr,
    input  logic [2:0]         s_axil_awprot,
    input  logic               s_axil_awvalid,
    output logic               s_axil_awready,
    input  logic [31:0]        s_axil_wdata,
    input  logic [3:0]         s_axil_wstrb,
    input  logic               s_axil_wvalid,
    output logic               s_axil_wready,
    output logic [1:0]         s_axil_bresp,
    output logic               s_axil_bvalid,
    input  logic               s_axil_bready,
    input  logic [AXIL_AW-1:0] s_axil_araddr,
    input  logic [2:0]         s_axil_arprot,
    input  logic               s_axil_arvalid,
    output logic               s_axil_arready,
    output logic [31:0]        s_axil_rdata,
    output logic [1:0]         s_axil_rresp,
    output logic               s_axil_rvalid,
    input  logic               s_axil_rready,

    // ---- control out -> core boot/config (latched by the core at its reset edge) --
    output logic        core_rst_n,             // = aresetn & CORE_RUN (core's reset)
    output logic [31:0] init_eip,
    output logic [31:0] init_esp,
    output logic        boot_mode,
    output logic        cycle_mode,
    output logic        bus_mode,
    output logic        l1axi_en,
    output logic        proxy_en,
    output logic        cosim_en,
    output logic        soc_en,                 // F3: core soc_en (MODE.SOCEN, bit 6)
    output logic [4:0]  errata_en,
    output logic        flush_all,              // W1P pulse from CTRL.FLUSH_ALL_REQ
    output logic        shutdown,               // CTRL.SHUTDOWN level: quiesce the AXI master
                                                // (clean teardown before xmutil unloadapp)

    // ---- status in <- core --------------------------------------------------------
    input  logic        cpu_hung,
    input  logic        bus_err,
    input  logic        axi_idle,               // ven_axi_master drained -> STATUS.AXI_IDLE
    input  logic [63:0] retire_n,

    // ---- port-I/O bridge <-> core io_* bus ----------------------------------------
    input  logic        io_req,
    input  logic        io_we,
    input  logic [15:0] io_addr,
    input  logic [2:0]  io_size,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    output logic        io_ack,

`ifdef VEN_PS_PROXY
    // ---- int-0x80 syscall proxy window (0x40-0x6C) <-> core syscall_* seam --------
    // On a cd80 with proxy_en=1 the core stalls in S_SYSCALL_WAIT; this slave captures
    // {nr, args} on the 1-clock syscall_active, raises sys_pending (+ irq_out), and on
    // the PS's W1P commit pulses syscall_resp_valid for one cycle with eax/gs filled.
    // Mirrors the io_* bridge discipline exactly (single pl_clk0 domain, no CDC).
    input  logic        syscall_active,     // core -> slave: 1-clock doorbell
    input  logic [63:0] syscall_n,          // upcoming retire index (diagnostic)
    input  logic [31:0] syscall_arg_eax,    // nr
    input  logic [31:0] syscall_arg_ebx,    // arg0
    input  logic [31:0] syscall_arg_ecx,    // arg1
    input  logic [31:0] syscall_arg_edx,    // arg2
    input  logic [31:0] syscall_arg_esi,    // arg3
    input  logic [31:0] syscall_arg_edi,    // arg4
    input  logic [31:0] syscall_arg_ebp,    // arg5
    output logic        syscall_resp_valid, // slave -> core: 1-cycle commit strobe
    output logic [31:0] syscall_eax,        // kernel ret -> gpr[0]
    output logic        syscall_apply_gs,   // 1: install a new %gs TLS base
    output logic [31:0] syscall_gs_base,    // the %gs base (set_thread_area)
    output logic [31:0] syscall_resume_eip, // informational on HW (core derives it)
`endif

    // ---- PS -> core interrupt-injection seam (F3, R_INTR) --------------------------
    // The PS-side 8259 C model (sw/ps_periph/ven_pic.c) is the PIC; this seam is its
    // INT/INTA wire pair to the core. The PS writes {assert, vector} -> intr_out is
    // the level on the core's intr pin and intr_vec the staged vector the core
    // latches on its 1-clock inta strobe. The inta strobe auto-clears the assert
    // (the 8259 drops INT at the INTA boundary) and sets a sticky W1C "seen" bit the
    // PS polls (or receives via irq_out) to intack its PIC model + stage the next.
    output logic        intr_out,               // level -> core intr
    output logic [7:0]  intr_vec,               // staged vector -> core inta_vector
    input  logic        inta,                   // 1-clock INTA strobe <- core

    // ---- interrupt to PS (GIC pl_ps_irq0) -----------------------------------------
    output logic        irq_out
`ifdef VEN_DBG_CORE
    ,
    // ---- VEN_DBG_CORE: debug/trace register window (0x80+) <-> ven_soc_dbg ----
    // Control out (PS-written) -> ven_soc_dbg:
    output logic        dbg_clear,         // W1P: zero perf counters + clear freeze/ring
    output logic [31:0] dbg_freeze_thresh, // stall cycles before a freeze snapshot (0=off)
    output logic [4:0]  dbg_trace_idx,     // ring read index: 0=newest retired PC, N back
    // Readback in (from ven_soc_dbg):
    input  logic [31:0] dbg_last_eip,
    input  logic [15:0] dbg_last_cs,
    input  logic [31:0] dbg_last_esp,
    input  logic [31:0] dbg_last_eflags,
    input  logic        dbg_frozen,
    input  logic [31:0] dbg_frozen_eip,
    input  logic [5:0]  dbg_frozen_state,
    input  logic [7:0]  dbg_frozen_vec,
    input  logic [31:0] dbg_trace_pc,
    input  logic [31:0] dbg_trace_aux,
    input  logic [5:0]  dbg_trace_count,
    // live core taps (combinational, stable when the core is frozen):
    input  logic [5:0]  dbg_live_state,
    input  logic [7:0]  dbg_live_vec,
    input  logic [31:0] dbg_live_fault_pc,
    input  logic [31:0] dbg_live_cr0,
    input  logic        dbg_cpu_hung,
    // performance counters:
    input  logic [63:0] dbg_perf_cyc,
    input  logic [63:0] dbg_perf_retired,
    input  logic [31:0] dbg_perf_stall,
    input  logic [31:0] dbg_perf_io,
    input  logic [31:0] dbg_perf_irq,
    // single-step / breakpoint control out -> core (via ventium_top):
    output logic        dbg_halt_req,      // level: park at the next instruction boundary
    output logic        dbg_step,          // W1P: release for exactly one instruction
    output logic        dbg_bp_en,         // enable the PC breakpoint
    output logic [31:0] dbg_bp_addr,       // breakpoint EIP
    output logic        dbg_bp_clr,        // W1P: clear a latched breakpoint (resume)
    input  logic        dbg_halted         // status: core parked at a boundary
`endif
);

  // ---- register offsets (word addresses; low bits of awaddr/araddr) -------------
  localparam logic [7:0] R_CTRL      = 8'h00;
  localparam logic [7:0] R_STATUS    = 8'h04;
  localparam logic [7:0] R_INIT_EIP  = 8'h08;
  localparam logic [7:0] R_INIT_ESP  = 8'h0C;
  localparam logic [7:0] R_MODE      = 8'h10;
  localparam logic [7:0] R_RETIRE_LO = 8'h14;
  localparam logic [7:0] R_RETIRE_HI = 8'h18;
  localparam logic [7:0] R_IO_STATUS = 8'h20;
  localparam logic [7:0] R_IO_ADDR   = 8'h24;
  localparam logic [7:0] R_IO_SIZE   = 8'h28;
  localparam logic [7:0] R_IO_WDATA  = 8'h2C;
  localparam logic [7:0] R_IO_RDATA  = 8'h30;
  localparam logic [7:0] R_IO_CTRL   = 8'h34;  // W1P: [0]ACK [1]IRQ_CLR
  localparam logic [7:0] R_INTR      = 8'h38;  // F3: [7:0]vector [8]assert [9]inta-seen(R/W1C) [16]inta-irq-en
  localparam logic [7:0] R_IRQ_STAT  = 8'h70;  // R/W1C: [0]io [1]inta-seen
  localparam logic [7:0] R_IDENT     = 8'h7C;
`ifdef VEN_PS_PROXY
  // ---- int-0x80 syscall window (0x40-0x6C; 12 words, the RESERVED aperture) ------
  localparam logic [7:0] R_SYS_STATUS = 8'h40;  // RO  [0]sys_pending
  localparam logic [7:0] R_SYS_NR     = 8'h44;  // RO  syscall number (=arg_eax)
  localparam logic [7:0] R_SYS_ARG0   = 8'h48;  // RO  ebx (arg0)
  localparam logic [7:0] R_SYS_ARG1   = 8'h4C;  // RO  ecx (arg1)
  localparam logic [7:0] R_SYS_ARG2   = 8'h50;  // RO  edx (arg2)
  localparam logic [7:0] R_SYS_ARG3   = 8'h54;  // RO  esi (arg3)
  localparam logic [7:0] R_SYS_ARG4   = 8'h58;  // RO  edi (arg4)
  localparam logic [7:0] R_SYS_ARG5   = 8'h5C;  // RO  ebp (arg5)
  localparam logic [7:0] R_SYS_CTRL   = 8'h60;  // W1P [0]RESP_VALID [1]APPLY_GS; RO [0]sys_pending
  localparam logic [7:0] R_SYS_RESUME = 8'h64;  // RW  resume_eip (informational)
  localparam logic [7:0] R_SYS_RET    = 8'h68;  // RW  -> syscall_eax
  localparam logic [7:0] R_SYS_GS     = 8'h6C;  // RW  -> syscall_gs_base
`endif
`ifdef VEN_DBG_CORE
  // ---- VEN_DBG_CORE debug/trace window (0x80..0xD4; clear of the 0x40-0x6C proxy)
  localparam logic [7:0] R_DBG_CAP        = 8'h80;  // RO {magic 0xDB, ver, DEPTH}
  localparam logic [7:0] R_DBG_EIP        = 8'h84;  // RO last-retired EIP
  localparam logic [7:0] R_DBG_CS         = 8'h88;  // RO last-retired CS
  localparam logic [7:0] R_DBG_ESP        = 8'h8C;  // RO last-retired ESP
  localparam logic [7:0] R_DBG_EFLAGS     = 8'h90;  // RO last-retired EFLAGS
  localparam logic [7:0] R_DBG_STATE      = 8'h94;  // RO live {frozen,hung,io,vec,cr0pg/pe,state}
  localparam logic [7:0] R_DBG_FAULT_PC   = 8'h98;  // RO live exception/IRQ source EIP
  localparam logic [7:0] R_DBG_CR0        = 8'h9C;  // RO live CR0
  localparam logic [7:0] R_DBG_FROZEN_EIP = 8'hA0;  // RO snapshot EIP at the freeze
  localparam logic [7:0] R_DBG_FROZEN_ST  = 8'hA4;  // RO {frozen,vec,state} at the freeze
  localparam logic [7:0] R_DBG_TRACE_IDX  = 8'hA8;  // RW [4:0]=N-back idx; RO [13:8]=count
  localparam logic [7:0] R_DBG_TRACE_PC   = 8'hAC;  // RO ring[idx] EIP
  localparam logic [7:0] R_DBG_TRACE_AUX  = 8'hB0;  // RO ring[idx] {state,cs}
  localparam logic [7:0] R_DBG_CTRL       = 8'hB4;  // W1P [0]=clear perf/freeze/ring
  localparam logic [7:0] R_DBG_FREEZE_TH  = 8'hB8;  // RW stall-cycles -> freeze (0=off)
  localparam logic [7:0] R_DBG_PERF_CYCLO = 8'hBC;  // RO cycles[31:0]
  localparam logic [7:0] R_DBG_PERF_CYCHI = 8'hC0;  // RO cycles[63:32]
  localparam logic [7:0] R_DBG_PERF_RETLO = 8'hC4;  // RO retired[31:0]
  localparam logic [7:0] R_DBG_PERF_RETHI = 8'hC8;  // RO retired[63:32]
  localparam logic [7:0] R_DBG_PERF_STALL = 8'hCC;  // RO no-retire cycles
  localparam logic [7:0] R_DBG_PERF_IO    = 8'hD0;  // RO S_IO cycles
  localparam logic [7:0] R_DBG_PERF_IRQ   = 8'hD4;  // RO external IRQs taken
  localparam logic [7:0] R_DBG_BP_ADDR    = 8'hD8;  // RW breakpoint EIP
  localparam logic [7:0] R_DBG_RUNCTL     = 8'hDC;  // RW [0]halt_req [1]W1P step
                                                    //    [2]bp_en [3]W1P bp_clr; RO [8]halted
`endif

  // ---- control / config registers ----------------------------------------------
  logic        core_run;
  logic        irq_en;
  logic [31:0] init_eip_r, init_esp_r;
  logic        boot_mode_r, cycle_mode_r, bus_mode_r, l1axi_en_r, proxy_en_r, cosim_en_r;
  logic        soc_en_r;
  logic [4:0]  errata_en_r;
  logic [31:0] io_rdata_r;       // PS-written IN return value (staged for the ack)
  logic [31:0] hi_snap;          // retire_n[63:32] snapshot, latched on RETIRE_LO read

  // F3 interrupt-injection seam state (R_INTR). All reset to 0, written only via
  // R_INTR / the core's inta strobe, so the seam is INERT unless the PS uses it
  // (and the core ignores intr/intr_vec entirely unless MODE.SOCEN is also set).
  logic [7:0]  intr_vec_r;       // staged vector (core latches it on its inta strobe)
  logic        intr_pend_r;      // assert level on the core's intr pin
  logic        intr_seen_r;      // sticky: the core pulsed inta (R/W1C)
  logic        intr_irq_en_r;    // 1 = intr_seen_r also raises irq_out (GIC notify)

`ifdef VEN_PS_PROXY
  // ---- int-0x80 syscall proxy state ---------------------------------------------
  logic        sys_pending;      // sticky: a syscall is captured + awaiting PS service
  logic        sys_resp_pulse;   // 1-cycle W1P -> syscall_resp_valid
  logic [31:0] sys_eax_r;        // PS-written kernel ret -> syscall_eax
  logic [31:0] sys_gs_r;         // PS-written %gs base -> syscall_gs_base
  logic [31:0] sys_resume_r;     // PS-written resume_eip (informational)
  logic        sys_apply_gs_r;   // PS-written apply-gs flag
  // snapshot of {nr,args,n} latched at the syscall_active edge (stable for the PS).
  logic [31:0] sys_nr_q, sys_a0_q, sys_a1_q, sys_a2_q, sys_a3_q, sys_a4_q, sys_a5_q;
  logic [63:0] sys_n_q;
`endif

`ifdef VEN_DBG_CORE
  logic [4:0]  dbg_trace_idx_r;  // ring read index (N-back), PS-written
  logic [31:0] dbg_freeze_th_r;  // freeze stall threshold, PS-written
  logic [31:0] dbg_bp_addr_r;    // breakpoint EIP, PS-written
  logic        dbg_bp_en_r;      // breakpoint enable
  logic        dbg_halt_req_r;   // single-step/park level
  assign dbg_trace_idx     = dbg_trace_idx_r;
  assign dbg_freeze_thresh = dbg_freeze_th_r;
  assign dbg_bp_addr       = dbg_bp_addr_r;
  assign dbg_bp_en         = dbg_bp_en_r;
  assign dbg_halt_req      = dbg_halt_req_r;
  // dbg_step / dbg_bp_clr are W1P pulses, driven in the write-decode block.
`endif

  assign core_rst_n = aresetn & core_run;
  assign init_eip   = init_eip_r;
  assign init_esp   = init_esp_r;
  assign boot_mode  = boot_mode_r;
  assign cycle_mode = cycle_mode_r;
  assign bus_mode   = bus_mode_r;
  assign l1axi_en   = l1axi_en_r;
  assign proxy_en   = proxy_en_r;
  assign cosim_en   = cosim_en_r;
  assign soc_en     = soc_en_r;
  assign errata_en  = errata_en_r;
  assign intr_out   = intr_pend_r;
  assign intr_vec   = intr_vec_r;

`ifdef VEN_PS_PROXY
  assign syscall_resp_valid = sys_resp_pulse;
  assign syscall_eax        = sys_eax_r;
  assign syscall_apply_gs   = sys_apply_gs_r;
  assign syscall_gs_base    = sys_gs_r;
  assign syscall_resume_eip = sys_resume_r;
  wire   sys_pend_status    = sys_pending;   // R_STATUS[9] mirror
`else
  wire   sys_pend_status    = 1'b0;
`endif

  // ---- port-I/O capture/release FSM ---------------------------------------------
  // IDLE -> (io_req) capture + raise irq, WAIT_PS (io_ack held 0) -> (PS ACK) RELEASE
  // (io_ack=1 one cycle, io_rdata valid) -> DONE (clear pending) -> IDLE.
  typedef enum logic [1:0] { IO_IDLE, IO_WAIT, IO_RELEASE, IO_DONE } iostate_e;
  iostate_e    iost;
  logic        io_pending;       // sticky: a request is captured + awaiting PS service
  logic        io_we_q;
  logic [15:0] io_addr_q;
  logic [2:0]  io_size_q;
  logic [31:0] io_wdata_q;
  logic        io_ack_r;
  logic        ps_ack_pulse;     // 1-cycle, set when the PS writes IO_CTRL.ACK
  logic        irq_clr_pulse;    // 1-cycle, set when the PS writes IO_CTRL.IRQ_CLR or W1C IRQ_STAT
  logic        irq_pending;      // sticky IRQ latch (set on capture, cleared by the PS)

  assign io_ack   = io_ack_r;
  assign io_rdata = io_rdata_r;
  // irq_out: io-bridge pending (F2, unchanged) OR — only when the PS opted in via
  // R_INTR.INTA_IRQ_EN — the inta-seen latch (so the PS daemon can sleep on the GIC
  // and wake to intack its PIC model + stage the next vector).
  assign irq_out  = irq_en & (irq_pending | (intr_irq_en_r & intr_seen_r)
`ifdef VEN_PS_PROXY
                              | sys_pending   // a serviced int-0x80 awaits the PS daemon
`endif
                             );

  // ================= AXI4-Lite write channel =================
  logic [7:0] waddr;             // low byte of awaddr (word-decoded)
  logic       wr_fire;           // a register write commits this cycle
  assign wr_fire = s_axil_awvalid && s_axil_wvalid && s_axil_awready && s_axil_wready;
  assign waddr   = s_axil_awaddr[7:0];

  // accept AW+W together when not holding a B response (single-beat).
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      s_axil_awready <= 1'b0; s_axil_wready <= 1'b0;
      s_axil_bvalid  <= 1'b0; s_axil_bresp  <= 2'b00;
    end else begin
      // one-cycle ready pulse when both valids present and no B outstanding.
      if (s_axil_awvalid && s_axil_wvalid && !s_axil_awready && !(s_axil_bvalid && !s_axil_bready)) begin
        s_axil_awready <= 1'b1; s_axil_wready <= 1'b1;
      end else begin
        s_axil_awready <= 1'b0; s_axil_wready <= 1'b0;
      end
      // raise B on the accepted write; clear when accepted.
      if (wr_fire)                        s_axil_bvalid <= 1'b1;
      else if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
    end
  end

  // ================= AXI4-Lite read channel =================
  logic [7:0] raddr;
  logic       rd_fire;           // a read accepted (araddr captured) this cycle
  assign raddr   = s_axil_araddr[7:0];
  assign rd_fire = s_axil_arvalid && s_axil_arready;
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      s_axil_arready <= 1'b0; s_axil_rvalid <= 1'b0;
      s_axil_rresp   <= 2'b00; s_axil_rdata <= 32'd0;
    end else begin
      // accept a read when AR present and no R outstanding.
      if (s_axil_arvalid && !s_axil_arready && !(s_axil_rvalid && !s_axil_rready))
        s_axil_arready <= 1'b1;
      else
        s_axil_arready <= 1'b0;
      if (rd_fire) begin
        s_axil_rvalid <= 1'b1;
        unique case (raddr)
          R_CTRL:      s_axil_rdata <= {23'd0, irq_en, 4'd0, shutdown /*[3] level*/, 1'b0 /*rst_req W1P*/, 1'b0 /*flush W1P*/, core_run};
          R_STATUS:    s_axil_rdata <= {22'd0, sys_pend_status /*[9]*/, io_pending, 4'd0, axi_idle /*[3]*/, ~aresetn, bus_err, cpu_hung};
          R_INIT_EIP:  s_axil_rdata <= init_eip_r;
          R_INIT_ESP:  s_axil_rdata <= init_esp_r;
          R_MODE:      s_axil_rdata <= {19'd0, errata_en_r, 1'b0, soc_en_r, cosim_en_r, proxy_en_r, l1axi_en_r, bus_mode_r, cycle_mode_r, boot_mode_r};
          R_RETIRE_LO: s_axil_rdata <= retire_n[31:0];   // (HI snapshot handled below)
          R_RETIRE_HI: s_axil_rdata <= hi_snap;
          R_IO_STATUS: s_axil_rdata <= {28'd0, 1'b0 /*is_ins*/, io_pending /*busy*/, io_we_q, io_pending};
          R_IO_ADDR:   s_axil_rdata <= {16'd0, io_addr_q};
          R_IO_SIZE:   s_axil_rdata <= {29'd0, io_size_q};
          R_IO_WDATA:  s_axil_rdata <= io_wdata_q;
          R_IO_RDATA:  s_axil_rdata <= io_rdata_r;
          R_INTR:      s_axil_rdata <= {15'd0, intr_irq_en_r, 6'd0, intr_seen_r, intr_pend_r, intr_vec_r};
          R_IRQ_STAT:  s_axil_rdata <= {30'd0, intr_seen_r, irq_pending};
          R_IDENT:     s_axil_rdata <= IDENT;
`ifdef VEN_PS_PROXY
          R_SYS_STATUS: s_axil_rdata <= {31'd0, sys_pending};
          R_SYS_NR:     s_axil_rdata <= sys_nr_q;
          R_SYS_ARG0:   s_axil_rdata <= sys_a0_q;
          R_SYS_ARG1:   s_axil_rdata <= sys_a1_q;
          R_SYS_ARG2:   s_axil_rdata <= sys_a2_q;
          R_SYS_ARG3:   s_axil_rdata <= sys_a3_q;
          R_SYS_ARG4:   s_axil_rdata <= sys_a4_q;
          R_SYS_ARG5:   s_axil_rdata <= sys_a5_q;
          R_SYS_CTRL:   s_axil_rdata <= {31'd0, sys_pending};
          R_SYS_RESUME: s_axil_rdata <= sys_resume_r;
          R_SYS_RET:    s_axil_rdata <= sys_eax_r;
          R_SYS_GS:     s_axil_rdata <= sys_gs_r;
`endif
`ifdef VEN_DBG_CORE
          R_DBG_CAP:        s_axil_rdata <= {8'hDB, 8'd1, 16'd32};  // magic, ver, ring DEPTH
          R_DBG_EIP:        s_axil_rdata <= dbg_last_eip;
          R_DBG_CS:         s_axil_rdata <= {16'd0, dbg_last_cs};
          R_DBG_ESP:        s_axil_rdata <= dbg_last_esp;
          R_DBG_EFLAGS:     s_axil_rdata <= dbg_last_eflags;
          R_DBG_STATE:      s_axil_rdata <= {13'd0, dbg_frozen, dbg_cpu_hung, io_pending,
                                             dbg_live_vec, dbg_live_cr0[31], dbg_live_cr0[0],
                                             dbg_live_state};
          R_DBG_FAULT_PC:   s_axil_rdata <= dbg_live_fault_pc;
          R_DBG_CR0:        s_axil_rdata <= dbg_live_cr0;
          R_DBG_FROZEN_EIP: s_axil_rdata <= dbg_frozen_eip;
          R_DBG_FROZEN_ST:  s_axil_rdata <= {15'd0, dbg_frozen, dbg_frozen_vec, 2'd0, dbg_frozen_state};
          R_DBG_TRACE_IDX:  s_axil_rdata <= {18'd0, dbg_trace_count, 3'd0, dbg_trace_idx_r};
          R_DBG_TRACE_PC:   s_axil_rdata <= dbg_trace_pc;
          R_DBG_TRACE_AUX:  s_axil_rdata <= dbg_trace_aux;
          R_DBG_FREEZE_TH:  s_axil_rdata <= dbg_freeze_th_r;
          R_DBG_PERF_CYCLO: s_axil_rdata <= dbg_perf_cyc[31:0];
          R_DBG_PERF_CYCHI: s_axil_rdata <= dbg_perf_cyc[63:32];
          R_DBG_PERF_RETLO: s_axil_rdata <= dbg_perf_retired[31:0];
          R_DBG_PERF_RETHI: s_axil_rdata <= dbg_perf_retired[63:32];
          R_DBG_PERF_STALL: s_axil_rdata <= dbg_perf_stall;
          R_DBG_PERF_IO:    s_axil_rdata <= dbg_perf_io;
          R_DBG_PERF_IRQ:   s_axil_rdata <= dbg_perf_irq;
          R_DBG_BP_ADDR:    s_axil_rdata <= dbg_bp_addr_r;
          R_DBG_RUNCTL:     s_axil_rdata <= {23'd0, dbg_halted, 5'd0, dbg_bp_en_r, 1'b0, dbg_halt_req_r};
`endif
          default:     s_axil_rdata <= 32'h0;
        endcase
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end
  // snapshot retire_n[63:32] when RETIRE_LO is read (torn-read-free 64-bit reads).
  always_ff @(posedge clk)
    if (!aresetn) hi_snap <= 32'd0;
    else if (rd_fire && raddr == R_RETIRE_LO) hi_snap <= retire_n[63:32];

  // ================= register write decode =================
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      core_run <= 1'b0;          // PS holds the core in reset until it releases CORE_RUN
      irq_en <= 1'b0;
      init_eip_r <= 32'd0; init_esp_r <= 32'd0;
      boot_mode_r <= 1'b0; cycle_mode_r <= 1'b0; bus_mode_r <= 1'b0;
      l1axi_en_r <= 1'b0; proxy_en_r <= 1'b0; cosim_en_r <= 1'b0; errata_en_r <= 5'd0;
      soc_en_r <= 1'b0;
      intr_vec_r <= 8'd0; intr_pend_r <= 1'b0; intr_seen_r <= 1'b0; intr_irq_en_r <= 1'b0;
      io_rdata_r <= 32'd0;
      flush_all <= 1'b0; ps_ack_pulse <= 1'b0; irq_clr_pulse <= 1'b0;
      shutdown  <= 1'b0;
`ifdef VEN_PS_PROXY
      sys_eax_r <= 32'd0; sys_gs_r <= 32'd0; sys_resume_r <= 32'd0;
      sys_apply_gs_r <= 1'b0; sys_resp_pulse <= 1'b0;
`endif
`ifdef VEN_DBG_CORE
      dbg_trace_idx_r <= 5'd0; dbg_freeze_th_r <= 32'd0; dbg_clear <= 1'b0;
      dbg_bp_addr_r <= 32'd0; dbg_bp_en_r <= 1'b0; dbg_halt_req_r <= 1'b0;
      dbg_step <= 1'b0; dbg_bp_clr <= 1'b0;
`endif
    end else begin
      flush_all     <= 1'b0;     // W1P: default low, pulse one cycle on the write
      ps_ack_pulse  <= 1'b0;
      irq_clr_pulse <= 1'b0;
`ifdef VEN_PS_PROXY
      sys_resp_pulse <= 1'b0;    // W1P
`endif
`ifdef VEN_DBG_CORE
      dbg_clear     <= 1'b0;     // W1P
      dbg_step      <= 1'b0;     // W1P
      dbg_bp_clr    <= 1'b0;     // W1P
`endif
      if (wr_fire) begin
        unique case (waddr)
          R_CTRL: begin
            if (s_axil_wstrb[0]) begin
              core_run <= s_axil_wdata[0];
              if (s_axil_wdata[1]) flush_all <= 1'b1;          // W1P FLUSH_ALL_REQ
              if (s_axil_wdata[2]) core_run  <= 1'b0;          // W1P CORE_RST_REQ -> drop run
              shutdown <= s_axil_wdata[3];                     // [3] SHUTDOWN level (held)
            end
            if (s_axil_wstrb[1]) irq_en <= s_axil_wdata[8];
          end
          R_INIT_EIP: begin
            if (s_axil_wstrb[0]) init_eip_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) init_eip_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) init_eip_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) init_eip_r[31:24] <= s_axil_wdata[31:24];
          end
          R_INIT_ESP: begin
            if (s_axil_wstrb[0]) init_esp_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) init_esp_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) init_esp_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) init_esp_r[31:24] <= s_axil_wdata[31:24];
          end
          R_MODE: if (s_axil_wstrb[0]) begin
            boot_mode_r <= s_axil_wdata[0]; cycle_mode_r <= s_axil_wdata[1];
            bus_mode_r  <= s_axil_wdata[2]; l1axi_en_r   <= s_axil_wdata[3];
            proxy_en_r  <= s_axil_wdata[4]; cosim_en_r   <= s_axil_wdata[5];
            soc_en_r    <= s_axil_wdata[6];  // F3: SOCEN (ungates the core's intr divert)
            if (s_axil_wstrb[1]) errata_en_r <= s_axil_wdata[12:8];
          end
          R_IO_RDATA: begin
            if (s_axil_wstrb[0]) io_rdata_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) io_rdata_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) io_rdata_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) io_rdata_r[31:24] <= s_axil_wdata[31:24];
          end
          R_IO_CTRL: if (s_axil_wstrb[0]) begin
            if (s_axil_wdata[0]) ps_ack_pulse  <= 1'b1;        // commit RDATA + ack the core
            if (s_axil_wdata[1]) irq_clr_pulse <= 1'b1;        // clear the IRQ latch
          end
          // F3 interrupt-injection seam: the PS (acting as the 8259) stages a vector
          // and asserts/deasserts the level. Writing assert=0 withdraws the request
          // (e.g. the PIC model's IMR masked it before the core took it).
          R_INTR: begin
            if (s_axil_wstrb[0]) intr_vec_r <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) begin
              intr_pend_r <= s_axil_wdata[8];
              if (s_axil_wdata[9]) intr_seen_r <= 1'b0;        // W1C inta-seen
            end
            if (s_axil_wstrb[2]) intr_irq_en_r <= s_axil_wdata[16];
          end
          R_IRQ_STAT: if (s_axil_wstrb[0]) begin
            if (s_axil_wdata[0]) irq_clr_pulse <= 1'b1;        // W1C io irq
            if (s_axil_wdata[1]) intr_seen_r   <= 1'b0;        // W1C inta-seen
          end
`ifdef VEN_PS_PROXY
          // int-0x80 response: the PS posts RET/GS/RESUME, then W1P CTRL.RESP_VALID.
          // The AXI-Lite write order IS the contract (RET/GS before CTRL) — the core
          // latches syscall_eax/gs combinationally on the resp_valid clock.
          R_SYS_RET: begin
            if (s_axil_wstrb[0]) sys_eax_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) sys_eax_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) sys_eax_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) sys_eax_r[31:24] <= s_axil_wdata[31:24];
          end
          R_SYS_GS: begin
            if (s_axil_wstrb[0]) sys_gs_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) sys_gs_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) sys_gs_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) sys_gs_r[31:24] <= s_axil_wdata[31:24];
          end
          R_SYS_RESUME: begin
            if (s_axil_wstrb[0]) sys_resume_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) sys_resume_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) sys_resume_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) sys_resume_r[31:24] <= s_axil_wdata[31:24];
          end
          R_SYS_CTRL: if (s_axil_wstrb[0]) begin
            if (s_axil_wdata[0]) sys_resp_pulse <= 1'b1;       // W1P commit -> resp_valid
            sys_apply_gs_r <= s_axil_wdata[1];                 // latch apply-gs (level)
          end
`endif
`ifdef VEN_DBG_CORE
          R_DBG_TRACE_IDX: if (s_axil_wstrb[0]) dbg_trace_idx_r <= s_axil_wdata[4:0];
          R_DBG_CTRL:      if (s_axil_wstrb[0] && s_axil_wdata[0]) dbg_clear <= 1'b1; // W1P
          R_DBG_FREEZE_TH: begin
            if (s_axil_wstrb[0]) dbg_freeze_th_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) dbg_freeze_th_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) dbg_freeze_th_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) dbg_freeze_th_r[31:24] <= s_axil_wdata[31:24];
          end
          R_DBG_BP_ADDR: begin
            if (s_axil_wstrb[0]) dbg_bp_addr_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) dbg_bp_addr_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) dbg_bp_addr_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) dbg_bp_addr_r[31:24] <= s_axil_wdata[31:24];
          end
          R_DBG_RUNCTL: if (s_axil_wstrb[0]) begin
            dbg_halt_req_r <= s_axil_wdata[0];
            if (s_axil_wdata[1]) dbg_step   <= 1'b1;   // W1P single-step
            dbg_bp_en_r    <= s_axil_wdata[2];
            if (s_axil_wdata[3]) dbg_bp_clr <= 1'b1;   // W1P clear breakpoint latch
          end
`endif
          default: ;
        endcase
      end
      // ---- core INTA boundary (mirrors the 8259 dropping INT at the intack) ------
      // The core pulses inta for exactly ONE clock when it accepts the maskable INTR
      // (S_DECODE/S_HLTWAIT intr_take) and latches intr_vec that same clock. Clear
      // the level here so the core cannot re-take the same injection after IRET, and
      // latch the sticky seen bit so the PS knows to intack its PIC model and stage
      // the next vector. Placed AFTER the write decode: a same-cycle AXI write to
      // R_INTR loses to the inta consume (the PS re-syncs off intr_seen_r).
      if (inta) begin
        intr_pend_r <= 1'b0;
        intr_seen_r <= 1'b1;
      end
    end
  end

  // ================= port-I/O capture/release FSM =================
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      iost <= IO_IDLE; io_pending <= 1'b0; io_ack_r <= 1'b0; irq_pending <= 1'b0;
      io_we_q <= 1'b0; io_addr_q <= 16'd0; io_size_q <= 3'd0; io_wdata_q <= 32'd0;
    end else begin
      io_ack_r <= 1'b0;                       // default: ack low (one-cycle pulse in RELEASE)
      if (irq_clr_pulse) irq_pending <= 1'b0; // PS cleared the interrupt
      unique case (iost)
        IO_IDLE: if (io_req) begin
          // capture the request (stable for the whole S_IO stall) + flag the PS.
          io_we_q    <= io_we;    io_addr_q <= io_addr;
          io_size_q  <= io_size;  io_wdata_q <= io_wdata;
          io_pending <= 1'b1;     irq_pending <= 1'b1;
          iost <= IO_WAIT;
        end
        IO_WAIT: if (ps_ack_pulse) begin
          // PS has written IO_RDATA (already in io_rdata_r) -> release the core.
          iost <= IO_RELEASE;
        end
        IO_RELEASE: begin
          io_ack_r <= 1'b1;       // single-cycle ack; the core latches io_rdata + advances
          iost <= IO_DONE;
        end
        IO_DONE: begin
          io_pending <= 1'b0;     // the core has left S_IO (io_req dropped); re-arm
          iost <= IO_IDLE;
        end
        default: iost <= IO_IDLE;
      endcase
    end
  end

`ifdef VEN_PS_PROXY
  // ================= int-0x80 syscall capture/release =================
  // On the core's 1-clock syscall_active doorbell, snapshot {nr,args,n} and raise
  // sys_pending (which also raises irq_out). The core then spins in S_SYSCALL_WAIT
  // holding syscall_* stable; the PS reads the snapshot, stages the kernel memory
  // effects into the DDR carveout, writes the response regs, then W1P
  // R_SYS_CTRL.RESP_VALID -> sys_resp_pulse fires syscall_resp_valid for ONE cycle
  // and clears sys_pending. Mirrors the io_* bridge (the core holds the request
  // stable for the whole stall — no retire ticks cn — so no IO_WAIT/RELEASE FSM is
  // needed; the snapshot + the single-cycle resp_pulse are the whole handshake).
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      sys_pending <= 1'b0;
      sys_nr_q <= 32'd0; sys_a0_q <= 32'd0; sys_a1_q <= 32'd0; sys_a2_q <= 32'd0;
      sys_a3_q <= 32'd0; sys_a4_q <= 32'd0; sys_a5_q <= 32'd0; sys_n_q <= 64'd0;
    end else begin
      if (syscall_active) begin
        sys_pending <= 1'b1;
        sys_nr_q <= syscall_arg_eax; sys_a0_q <= syscall_arg_ebx;
        sys_a1_q <= syscall_arg_ecx; sys_a2_q <= syscall_arg_edx;
        sys_a3_q <= syscall_arg_esi; sys_a4_q <= syscall_arg_edi;
        sys_a5_q <= syscall_arg_ebp; sys_n_q  <= syscall_n;
      end
      if (sys_resp_pulse) sys_pending <= 1'b0;  // commit clears the latch
    end
  end
`endif

`ifndef SYNTHESIS
  // io_ack is exactly one cycle per release (the core needs precisely one ack edge).
  ioack_pulse: assert property (@(posedge clk) disable iff (!aresetn)
      io_ack_r |=> !io_ack_r);
  // never ack without a captured pending request.
  ioack_pending: assert property (@(posedge clk) disable iff (!aresetn)
      io_ack_r |-> io_pending);
`ifdef VEN_PS_PROXY
  // syscall_resp_valid is exactly one cycle per commit (the core needs one edge).
  sysresp_pulse: assert property (@(posedge clk) disable iff (!aresetn)
      sys_resp_pulse |=> !sys_resp_pulse);
  // never commit a response without a pending captured syscall.
  sysresp_pending: assert property (@(posedge clk) disable iff (!aresetn)
      sys_resp_pulse |-> sys_pending);
`endif
  // F3 seam: the inta strobe always drops the assert level on the next clock
  // (the 8259-INT-drops-at-INTA semantics) and always latches the seen bit
  // (a same-cycle W1C must not lose an intack).
  inta_clears_pend: assert property (@(posedge clk) disable iff (!aresetn)
      inta |=> !intr_pend_r);
  inta_sets_seen: assert property (@(posedge clk) disable iff (!aresetn)
      inta |=> intr_seen_r);
  // AXI-Lite: BVALID/RVALID hold until accepted.
  b_hold: assert property (@(posedge clk) disable iff (!aresetn)
      (s_axil_bvalid && !s_axil_bready) |=> s_axil_bvalid);
  r_hold: assert property (@(posedge clk) disable iff (!aresetn)
      (s_axil_rvalid && !s_axil_rready) |=> s_axil_rvalid && $stable(s_axil_rdata));
`endif

endmodule : ven_soc_axil
