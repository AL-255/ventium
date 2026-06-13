// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ventium_kv260_core.sv — the KV260 PL design: ventium_top (core + L1 + AXI4
// master to PS-DDR) + ven_soc_axil (the PS<->PL control + port-I/O bridge). This is
// the whole FPGA-fabric side of the PS-assisted SoC (fpga/KV260_SOC_DESIGN.md): the
// PS A53 drives the AXI-Lite slave to boot/control the core and to emulate every slow
// peripheral, and services DDR over the AXI4 master (S_AXI_HPC0_FPD).
//
// Build with +VEN_L1_AXI +VEN_KV260_SOC. The default cosim build defines neither, so
// ventium_top stays byte-identical (no extra ports, no mode-2 leg).
//
//   PS HPM0 (AXI-Lite) -> s_axil -> ven_soc_axil -> {boot cfg, io bridge, status}
//                                                      |            ^   |
//                                          core_rst_n  v   io_req   |   v cpu_hung/bus_err/retire
//   PS HPC0 (AXI4) <- m_axi <----------------- ventium_top (cosim_en=1 io, l1axi_en=1 mem)
//   PL->PS GIC <- irq_out (io/syscall pending)

module ventium_kv260_core #(
    parameter int AXIL_AW = 16
) (
    input  logic        clk,           // pl_clk0 (single domain: core + L1 + HPC0 + slave)
    input  logic        aresetn,       // peripheral_aresetn (active-low)

    // ---- AXI4-Lite control slave (<- PS M_AXI_HPM0_FPD) -----------------------
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

    // ---- AXI4 master (-> PS S_AXI_HPC0_FPD, the DDR carveout) ------------------
    output logic [3:0]        m_axi_awid,
    output logic [39:0]       m_axi_awaddr,
    output logic [7:0]        m_axi_awlen,
    output logic [2:0]        m_axi_awsize,
    output logic [1:0]        m_axi_awburst,
    output logic              m_axi_awlock,
    output logic [3:0]        m_axi_awcache,
    output logic [2:0]        m_axi_awprot,
    output logic [3:0]        m_axi_awqos,
    output logic              m_axi_awvalid,
    input  logic              m_axi_awready,
    output logic [31:0]       m_axi_wdata,
    output logic [3:0]        m_axi_wstrb,
    output logic              m_axi_wlast,
    output logic              m_axi_wvalid,
    input  logic              m_axi_wready,
    input  logic [3:0]        m_axi_bid,
    input  logic [1:0]        m_axi_bresp,
    input  logic              m_axi_bvalid,
    output logic              m_axi_bready,
    output logic [3:0]        m_axi_arid,
    output logic [39:0]       m_axi_araddr,
    output logic [7:0]        m_axi_arlen,
    output logic [2:0]        m_axi_arsize,
    output logic [1:0]        m_axi_arburst,
    output logic              m_axi_arlock,
    output logic [3:0]        m_axi_arcache,
    output logic [2:0]        m_axi_arprot,
    output logic [3:0]        m_axi_arqos,
    output logic              m_axi_arvalid,
    input  logic              m_axi_arready,
    input  logic [3:0]        m_axi_rid,
    input  logic [31:0]       m_axi_rdata,
    input  logic [1:0]        m_axi_rresp,
    input  logic              m_axi_rlast,
    input  logic              m_axi_rvalid,
    output logic              m_axi_rready,

    // ---- PL -> PS interrupt (io/syscall pending) ------------------------------
    output logic              irq_out
);

  // ---- slave <-> core control/status/io nets --------------------------------
  logic        core_rst_n;
  logic [31:0] cfg_init_eip, cfg_init_esp;
  logic        cfg_boot_mode, cfg_cycle_mode, cfg_bus_mode, cfg_l1axi_en;
  logic        cfg_proxy_en, cfg_cosim_en, cfg_soc_en, cfg_flush_all;
  logic        cfg_shutdown;     // R_CTRL.SHUTDOWN -> quiesce the AXI master
  logic        st_axi_idle;      // ven_axi_master m_idle -> R_STATUS.AXI_IDLE
  logic [4:0]  cfg_errata_en;
  logic        st_cpu_hung, st_bus_err;
  logic [63:0] st_retire_n;
  logic        io_req, io_we; logic [15:0] io_addr; logic [2:0] io_size;
  logic [31:0] io_wdata, io_rdata; logic io_ack;
  // F3 PS->core interrupt-injection seam (ven_soc_axil R_INTR <-> ventium_top).
  logic        core_intr; logic [7:0] core_intr_vec; logic core_inta;

`ifdef VEN_PS_PROXY
  // F4 int-0x80 syscall proxy seam (ven_soc_axil 0x40-0x6C <-> ventium_top/core).
  logic        sc_active, sc_resp_valid, sc_apply_gs;
  logic [63:0] sc_n;
  logic [31:0] sc_arg_eax, sc_arg_ebx, sc_arg_ecx, sc_arg_edx, sc_arg_esi, sc_arg_edi, sc_arg_ebp;
  logic [31:0] sc_eax, sc_gs_base, sc_resume_eip;
`endif

`ifdef VEN_DBG_CORE
  // VEN_DBG_CORE bundle: ventium_top debug taps -> ven_soc_dbg -> ven_soc_axil regs.
  logic        dbg_retire_valid;
  logic [31:0] dbg_eip, dbg_esp, dbg_eflags, dbg_fault_pc, dbg_cr0;
  logic [15:0] dbg_cs;
  logic [5:0]  dbg_state;  logic [7:0] dbg_int_vec;
  // ven_soc_dbg readback + control nets (d_*):
  logic        d_clear, d_frozen;
  logic [31:0] d_freeze_th, d_last_eip, d_last_esp, d_last_eflags, d_frozen_eip;
  logic [31:0] d_trace_pc, d_trace_aux, d_perf_stall, d_perf_io, d_perf_irq;
  logic [15:0] d_last_cs;
  logic [4:0]  d_trace_idx;
  logic [5:0]  d_frozen_state, d_trace_count;
  logic [7:0]  d_frozen_vec;
  logic [63:0] d_perf_cyc, d_perf_ret;
  // single-step / breakpoint control (ven_soc_axil <-> ventium_top/core)
  logic        d_halt_req, d_step, d_bp_en, d_bp_clr, d_halted;
  logic [31:0] d_bp_addr;
`endif

  ven_soc_axil #(.AXIL_AW(AXIL_AW)) u_axil (
      .clk(clk), .aresetn(aresetn),
      .s_axil_awaddr(s_axil_awaddr), .s_axil_awprot(s_axil_awprot),
      .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
      .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb),
      .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
      .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
      .s_axil_araddr(s_axil_araddr), .s_axil_arprot(s_axil_arprot),
      .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
      .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
      .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
      .core_rst_n(core_rst_n),
      .init_eip(cfg_init_eip), .init_esp(cfg_init_esp), .boot_mode(cfg_boot_mode),
      .cycle_mode(cfg_cycle_mode), .bus_mode(cfg_bus_mode), .l1axi_en(cfg_l1axi_en),
      .proxy_en(cfg_proxy_en), .cosim_en(cfg_cosim_en), .soc_en(cfg_soc_en),
      .errata_en(cfg_errata_en),
      .flush_all(cfg_flush_all),
      .shutdown(cfg_shutdown), .axi_idle(st_axi_idle),
      .cpu_hung(st_cpu_hung), .bus_err(st_bus_err), .retire_n(st_retire_n),
      .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_size(io_size),
      .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ack(io_ack),
      .intr_out(core_intr), .intr_vec(core_intr_vec), .inta(core_inta),
      .irq_out(irq_out)
`ifdef VEN_PS_PROXY
      ,
      // int-0x80 syscall window <-> core seam (the response/commit side).
      .syscall_active(sc_active), .syscall_n(sc_n),
      .syscall_arg_eax(sc_arg_eax), .syscall_arg_ebx(sc_arg_ebx),
      .syscall_arg_ecx(sc_arg_ecx), .syscall_arg_edx(sc_arg_edx),
      .syscall_arg_esi(sc_arg_esi), .syscall_arg_edi(sc_arg_edi),
      .syscall_arg_ebp(sc_arg_ebp),
      .syscall_resp_valid(sc_resp_valid), .syscall_eax(sc_eax),
      .syscall_apply_gs(sc_apply_gs), .syscall_gs_base(sc_gs_base),
      .syscall_resume_eip(sc_resume_eip)
`endif
`ifdef VEN_DBG_CORE
      ,
      .dbg_clear(d_clear), .dbg_freeze_thresh(d_freeze_th), .dbg_trace_idx(d_trace_idx),
      .dbg_last_eip(d_last_eip), .dbg_last_cs(d_last_cs), .dbg_last_esp(d_last_esp),
      .dbg_last_eflags(d_last_eflags), .dbg_frozen(d_frozen), .dbg_frozen_eip(d_frozen_eip),
      .dbg_frozen_state(d_frozen_state), .dbg_frozen_vec(d_frozen_vec),
      .dbg_trace_pc(d_trace_pc), .dbg_trace_aux(d_trace_aux), .dbg_trace_count(d_trace_count),
      .dbg_live_state(dbg_state), .dbg_live_vec(dbg_int_vec), .dbg_live_fault_pc(dbg_fault_pc),
      .dbg_live_cr0(dbg_cr0), .dbg_cpu_hung(st_cpu_hung),
      .dbg_perf_cyc(d_perf_cyc), .dbg_perf_retired(d_perf_ret), .dbg_perf_stall(d_perf_stall),
      .dbg_perf_io(d_perf_io), .dbg_perf_irq(d_perf_irq),
      .dbg_halt_req(d_halt_req), .dbg_step(d_step), .dbg_bp_en(d_bp_en),
      .dbg_bp_addr(d_bp_addr), .dbg_bp_clr(d_bp_clr), .dbg_halted(d_halted)
`endif
  );

  // verilator lint_off PINCONNECTEMPTY
  ventium_top u_core (
      .clk(clk), .rst_n(core_rst_n),
      // boot/config from the slave (PS-written; latched by the core at its reset edge,
      // mode bits read live — the PS sets MODE then releases CORE_RUN, AXI-Lite ordered).
      .init_eip(cfg_init_eip), .init_esp(cfg_init_esp), .boot_mode(cfg_boot_mode),
      .bus_mode(cfg_bus_mode), .cycle_mode(cfg_cycle_mode), .errata_en(cfg_errata_en),
      .cpu_hung(st_cpu_hung),
      // int-0x80 proxy. +VEN_PS_PROXY: the core stalls in S_SYSCALL_WAIT and the
      // syscall_* seam is wired to ven_soc_axil's 0x40-0x6C window (the PS daemon
      // services it). Otherwise (F2/F3): proxy_en=0, inert; the response inputs
      // tied off (and there is no syscall_resp_valid port to connect).
      .proxy_en(cfg_proxy_en),
`ifdef VEN_PS_PROXY
      .syscall_active(sc_active), .syscall_n(sc_n),
      .syscall_resume_eip(sc_resume_eip), .syscall_eax(sc_eax),
      .syscall_apply_gs(sc_apply_gs), .syscall_gs_base(sc_gs_base),
      .syscall_resp_valid(sc_resp_valid),
      .syscall_arg_eax(sc_arg_eax), .syscall_arg_ebx(sc_arg_ebx),
      .syscall_arg_ecx(sc_arg_ecx), .syscall_arg_edx(sc_arg_edx),
      .syscall_arg_esi(sc_arg_esi), .syscall_arg_edi(sc_arg_edi),
      .syscall_arg_ebp(sc_arg_ebp),
`else
      .syscall_active(), .syscall_n(),
      .syscall_resume_eip(32'd0), .syscall_eax(32'd0),
      .syscall_apply_gs(1'b0), .syscall_gs_base(32'd0),
      .syscall_arg_eax(), .syscall_arg_ebx(), .syscall_arg_ecx(), .syscall_arg_edx(),
      .syscall_arg_esi(), .syscall_arg_edi(), .syscall_arg_ebp(),
`endif
      // port-I/O bridge (cosim_en routes IN/OUT to this bus; the slave services it).
      .cosim_en(cfg_cosim_en),
      .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_size(io_size),
      .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ack(io_ack),
      // direct mem_* port: INERT in mode 2 (l1axi_en=1) — tie the inputs, drop outputs.
      .mem_req(), .mem_we(), .mem_addr(), .mem_wdata(), .mem_wstrb(),
      .mem_rdata(32'd0), .mem_ack(1'b0),
      // L1+AXI mode 2 -> the AXI4 master to PS-DDR.
      .l1axi_en(cfg_l1axi_en), .flush_all(cfg_flush_all),
      .shutdown(cfg_shutdown), .m_idle(st_axi_idle),
      .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
      .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos),
      .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
      .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
      .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
      .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
      .m_axi_bready(m_axi_bready),
      .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
      .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
      .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
      .bus_err(st_bus_err),
      .retire_count(st_retire_n),
      // F3 PS-driven interrupt injection (R_INTR): inert until the PS sets
      // MODE.SOCEN and writes R_INTR — the F2 boot flow never touches either.
      .soc_en(cfg_soc_en),
      .intr(core_intr), .inta_vector(core_intr_vec), .inta(core_inta)
`ifdef VEN_DBG_CORE
      ,
      .dbg_retire_valid(dbg_retire_valid), .dbg_eip(dbg_eip), .dbg_cs(dbg_cs),
      .dbg_esp(dbg_esp), .dbg_eflags(dbg_eflags), .dbg_state(dbg_state),
      .dbg_int_vec(dbg_int_vec), .dbg_fault_pc(dbg_fault_pc), .dbg_cr0(dbg_cr0),
      .dbg_halt_req(d_halt_req), .dbg_step(d_step), .dbg_bp_en(d_bp_en),
      .dbg_bp_addr(d_bp_addr), .dbg_bp_clr(d_bp_clr), .dbg_halted(d_halted)
`endif
  );
  // verilator lint_on PINCONNECTEMPTY

`ifdef VEN_DBG_CORE
  // On-die debug/trace unit: PC ring + freeze detector + perf counters, fed by the
  // ventium_top debug bundle. Reset with the core (core_rst_n) so a window aligns
  // with a run; survives a hang (core_run stays 1) so the PS can read the snapshot.
  ven_soc_dbg #(.DEPTH(32)) u_dbg (
      .clk(clk), .rst_n(core_rst_n),
      .dbg_retire_valid(dbg_retire_valid), .dbg_eip(dbg_eip), .dbg_cs(dbg_cs),
      .dbg_esp(dbg_esp), .dbg_eflags(dbg_eflags), .dbg_state(dbg_state),
      .dbg_int_vec(dbg_int_vec), .dbg_fault_pc(dbg_fault_pc), .dbg_cr0(dbg_cr0),
      .io_pending(io_req), .inta(core_inta),
      .ctrl_clear(d_clear), .freeze_thresh(d_freeze_th), .trace_rd_idx(d_trace_idx),
      .last_eip(d_last_eip), .last_cs(d_last_cs), .last_esp(d_last_esp),
      .last_eflags(d_last_eflags), .frozen(d_frozen), .frozen_eip(d_frozen_eip),
      .frozen_state(d_frozen_state), .frozen_vec(d_frozen_vec),
      .trace_pc(d_trace_pc), .trace_aux(d_trace_aux), .trace_count(d_trace_count),
      .perf_cyc(d_perf_cyc), .perf_retired(d_perf_ret), .perf_stall(d_perf_stall),
      .perf_io(d_perf_io), .perf_irq(d_perf_irq)
  );
`endif

endmodule : ventium_kv260_core
