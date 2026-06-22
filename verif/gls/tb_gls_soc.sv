// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/gls/tb_gls_soc.sv — xsim gate-level FreeDOS boot testbench.
//
// Drives ventium_top (RTL in stage-1, the funcsim netlist in stage-2) with:
//   * the deployed KV260 L1AXI boot config (boot_mode=1, l1axi_en=1, soc_en=1);
//   * a behavioral AXI4 DDR slave (read + write channels, single + burst beats)
//     backed by MemModel via DPI-C (gls_mem_read32/gls_mem_write32);
//   * the port-I/O bridge (cosim_en=1, io_req/io_we/io_addr/io_size/io_wdata ->
//     io_rdata/io_ack) serviced by the PS peripheral C models via gls_io_service;
//   * the F3 IRQ0 timer pump (gls_irq_poll / gls_inta).
//
// This is the SystemVerilog re-creation of the seams in verif/tb/tb_main.cpp
// (the Verilator C++ tb). The DDR slave's pre-edge-capture / post-edge-advance
// phasing matches axi_capture()/axi_advance(); the io-bridge does ONE side-effect
// per io_req assertion (gls_io_idle re-arms on deassert), matching service_io().
//
// The netlist is built with VTM_NO_DPI (no retire DPI), so there is no retire
// counter to watch. Progress/termination is observed off the bus instead: IDE
// port-0x1F0 reads (FreeDOS disk load), the COM1/debug console, and the
// isa-debug-exit `out 0xf4` (gls_io_service flags it -> g_term).

`timescale 1ns/1ps

module tb_gls_soc;

  // Hold rst_n low past the unisim GSR window (glbl ROC_WIDTH = 100 ns) + margin,
  // so every funcsim flop gets a clean synchronous reset AFTER GSR releases. See
  // the reset block below for the full rationale (the 0xFE05B->0x3620 far-jump bug).
  localparam time GSR_CLEAR = 150ns;   // > glbl ROC_WIDTH (100 ns) + margin

  // ---- DPI-C imports (verif/gls/gls_dpi.cpp) --------------------------------
  import "DPI-C" function int  gls_init(input string disk, input string bios);
  import "DPI-C" function int  gls_mem_read32(input int unsigned addr);
  import "DPI-C" function void gls_mem_write32(input int unsigned addr,
                                               input int unsigned data,
                                               input int unsigned wstrb);
  import "DPI-C" function int  gls_io_service(input int we, input int addr,
                                              input int size,
                                              input int unsigned wdata,
                                              output int unsigned rdata);
  import "DPI-C" function void gls_io_idle();
  import "DPI-C" function int  gls_irq_poll(input longint unsigned cycle);
  import "DPI-C" function void gls_inta();
  import "DPI-C" function void gls_io_stats(output longint unsigned nin,
                                            output longint unsigned nout);

  // ---- clock / reset --------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;

  // ---- DUT port nets --------------------------------------------------------
  logic [31:0] init_eip = 32'h0000_fff0;  // informational under boot_mode=1
  logic [31:0] init_esp = 32'h0000_0000;
  logic        boot_mode = 1'b1;   // system cold reset (CS:EIP=F000:FFF0)
  logic        bus_mode  = 1'b0;
  logic        cycle_mode = 1'b0;
  logic [4:0]  errata_en = 5'd0;
  logic        cpu_hung;

  // proxy (inert)
  logic        proxy_en = 1'b0;
  logic        syscall_active;
  logic [63:0] syscall_n;
  logic [31:0] syscall_resume_eip = 32'd0;
  logic [31:0] syscall_eax = 32'd0;
  logic        syscall_apply_gs = 1'b0;
  logic [31:0] syscall_gs_base = 32'd0;
  logic        syscall_resp_valid = 1'b0;
  logic [31:0] syscall_arg_eax, syscall_arg_ebx, syscall_arg_ecx, syscall_arg_edx;
  logic [31:0] syscall_arg_esi, syscall_arg_edi, syscall_arg_ebp;

  // port-I/O bridge
  logic        cosim_en = 1'b1;
  logic        io_req;
  logic        io_we;
  logic [15:0] io_addr;
  logic [2:0]  io_size;
  logic [31:0] io_wdata;
  logic [31:0] io_rdata = 32'd0;
  logic        io_ack = 1'b0;

  // legacy mem_* (unused in mode 2, tied off)
  logic        mem_req;
  logic        mem_we;
  logic [31:0] mem_addr;
  logic [31:0] mem_wdata;
  logic [3:0]  mem_wstrb;
  logic [31:0] mem_rdata = 32'd0;
  logic        mem_ack = 1'b0;

  // L1AXI mode-2 controls
  logic        l1axi_en = 1'b1;
  logic        flush_all = 1'b0;
  logic        golden_l1 = 1'b0;

  // AXI4 master (DUT drives most; slave drives the *ready/*valid/*data back)
  logic [3:0]  m_axi_awid;
  logic [39:0] m_axi_awaddr;
  logic [7:0]  m_axi_awlen;
  logic [2:0]  m_axi_awsize;
  logic [1:0]  m_axi_awburst;
  logic        m_axi_awlock;
  logic [3:0]  m_axi_awcache;
  logic [2:0]  m_axi_awprot;
  logic [3:0]  m_axi_awqos;
  logic        m_axi_awvalid;
  logic        m_axi_awready = 1'b0;
  logic [31:0] m_axi_wdata;
  logic [3:0]  m_axi_wstrb;
  logic        m_axi_wlast;
  logic        m_axi_wvalid;
  logic        m_axi_wready = 1'b0;
  logic [3:0]  m_axi_bid = 4'd0;
  logic [1:0]  m_axi_bresp = 2'd0;
  logic        m_axi_bvalid = 1'b0;
  logic        m_axi_bready;
  logic [3:0]  m_axi_arid;
  logic [39:0] m_axi_araddr;
  logic [7:0]  m_axi_arlen;
  logic [2:0]  m_axi_arsize;
  logic [1:0]  m_axi_arburst;
  logic        m_axi_arlock;
  logic [3:0]  m_axi_arcache;
  logic [2:0]  m_axi_arprot;
  logic [3:0]  m_axi_arqos;
  logic        m_axi_arvalid;
  logic        m_axi_arready = 1'b0;
  logic [3:0]  m_axi_rid = 4'd0;
  logic [31:0] m_axi_rdata = 32'd0;
  logic [1:0]  m_axi_rresp = 2'd0;
  logic        m_axi_rlast = 1'b0;
  logic        m_axi_rvalid = 1'b0;
  logic        m_axi_rready;
  logic        bus_err;
  logic        shutdown = 1'b0;
  logic        m_idle;

  // KV260 SoC observability + IRQ-injection seam
  logic [63:0] retire_count;
  logic        soc_en = 1'b1;     // ungate the external-interrupt path (DOS IRQs)
  logic        intr = 1'b0;
  logic [7:0]  inta_vector = 8'd0;
  logic        inta;

  // ---- VEN_DBG_CORE observability taps (DBG netlist only) -------------------
  // The DBG funcsim netlist (synth_ventop_funcsim_dbg.tcl, +VEN_DBG_CORE) exposes
  // ventium_top's dbg_* outputs: committed EIP/CS/ESP/EFLAGS + FSM micro-state +
  // last vector + fault PC + per-retire strobe + the AXI read-beat tap. The PC
  // ring (ven_soc_dbg) lives BELOW ventium_top in the real SoC, so the tb rebuilds
  // it here from dbg_eip + dbg_retire_valid (the GLS equivalent of dbg_dump_core).
`ifdef VEN_DBG_CORE
  logic        dbg_retire_valid;
  logic [31:0] dbg_eip;
  logic [15:0] dbg_cs;
  logic [31:0] dbg_esp;
  logic [31:0] dbg_eflags;
  logic [5:0]  dbg_state;
  logic [7:0]  dbg_int_vec;
  logic [31:0] dbg_fault_pc;
  logic [31:0] dbg_cr0;
  logic [63:0] dbg_ibuf;
  logic        dbg_rd_valid;
  logic [31:0] dbg_rd_addr;
  logic [31:0] dbg_rd_data;
`endif

  // ---- DUT instance ---------------------------------------------------------
  ventium_top u_dut (
    .clk(clk), .rst_n(rst_n),
    .init_eip(init_eip), .init_esp(init_esp),
    .boot_mode(boot_mode), .bus_mode(bus_mode), .cycle_mode(cycle_mode),
    .errata_en(errata_en), .cpu_hung(cpu_hung),
    .proxy_en(proxy_en), .syscall_active(syscall_active), .syscall_n(syscall_n),
    .syscall_resume_eip(syscall_resume_eip), .syscall_eax(syscall_eax),
    .syscall_apply_gs(syscall_apply_gs), .syscall_gs_base(syscall_gs_base),
`ifdef VEN_PS_PROXY
    .syscall_resp_valid(syscall_resp_valid),
`endif
    .syscall_arg_eax(syscall_arg_eax), .syscall_arg_ebx(syscall_arg_ebx),
    .syscall_arg_ecx(syscall_arg_ecx), .syscall_arg_edx(syscall_arg_edx),
    .syscall_arg_esi(syscall_arg_esi), .syscall_arg_edi(syscall_arg_edi),
    .syscall_arg_ebp(syscall_arg_ebp),
    .cosim_en(cosim_en), .io_req(io_req), .io_we(io_we), .io_addr(io_addr),
    .io_size(io_size), .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ack(io_ack),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
    .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .l1axi_en(l1axi_en), .flush_all(flush_all), .golden_l1(golden_l1),
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
    .bus_err(bus_err), .shutdown(shutdown), .m_idle(m_idle),
    .retire_count(retire_count),
    .soc_en(soc_en), .intr(intr), .inta_vector(inta_vector), .inta(inta)
`ifdef VEN_DBG_CORE
    ,
    .dbg_retire_valid(dbg_retire_valid), .dbg_eip(dbg_eip), .dbg_cs(dbg_cs),
    .dbg_esp(dbg_esp), .dbg_eflags(dbg_eflags),
    .dbg_state(dbg_state), .dbg_int_vec(dbg_int_vec), .dbg_fault_pc(dbg_fault_pc),
    .dbg_cr0(dbg_cr0), .dbg_fctrl(), .dbg_fxop(),
    .dbg_ibuf(dbg_ibuf), .dbg_seg(), .dbg_de_num(), .dbg_de_info(),
    .dbg_hook_cfg(16'd0), .dbg_hook_seq(), .dbg_hook_eip(), .dbg_hook_opa(),
    .dbg_hook_opb(), .dbg_hook_meta(),
    .dbg_cmp_cfg(32'd0), .dbg_cmp_range(32'd0),
    .dbg_div_eip(), .dbg_div_eip70(), .dbg_div_info(), .dbg_cmp_freeze(),
    .dbg_rd_valid(dbg_rd_valid), .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
    .dbg_halt_req(1'b0), .dbg_step(1'b0), .dbg_bp_en(1'b0), .dbg_bp_addr(32'd0),
    .dbg_bp_clr(1'b0), .dbg_halted()
`endif
  );

  // ---- glbl (unisim/secureip need it for GSR in netlist mode) ---------------
  // (instantiated by xelab via the glbl module on the elaborate command line)

  // ---- KV260 AXI carveout remap (mirrors tb_main.cpp AXI_REMAP) -------------
  localparam [39:0] AXI_REMAP = 40'h40_0000_0000 >> 6; // placeholder, set below
  // The deployed VEN_KV260_SOC build remaps x86 phys into the DDR carveout at
  // 0x4000_0000. The MemModel is x86-phys-indexed, so subtract the base off every
  // AXI address before indexing. (tb_main.cpp: AXI_REMAP = 0x40000000.)
  localparam int unsigned REMAP_BASE = 32'h4000_0000;

  // ---- behavioral AXI4 DDR slave -------------------------------------------
  // FSMs mirror tb_main.cpp axr/axw. Pre-edge capture (snapshot the handshakes
  // the DUT presents before the rising edge) + post-edge advance.
  // axr: 0=IDLE (arready), 1=BEAT (rvalid)
  // axw: 0=IDLE (awready), 1=DATA (wready), 2=RESP (bvalid)
  int          axr = 0, axw = 0;
  int unsigned axr_addr = 0, axw_addr = 0, axr_cnt = 0;

  // diagnostics: AXI transaction counters + last accepted read/write addr.
  longint unsigned n_ar = 0, n_rbeat = 0, n_aw = 0, n_wbeat = 0;
  int unsigned last_rd_addr = 0, last_wr_addr = 0;
  // +gls_trace prints the first N AR addresses + their R-beat fill data (the
  // netlist-vs-RTL fetch-divergence forensic view). gls_trace_n = bursts to log.
  bit          gls_trace = 1'b0;
  int          gls_trace_n = 8;

  // Captured pre-edge handshakes.
  logic        hs_ar, hs_r, hs_aw, hs_w, hs_b;
  int unsigned hs_araddr, hs_arlen, hs_awaddr, hs_wdata, hs_wstrb;

  // axi_drive(): drive the slave's combinational outputs from registered state.
  task automatic axi_drive();
    m_axi_arready = (axr == 0);
    m_axi_rvalid  = (axr == 1);
    m_axi_rdata   = (axr == 1) ? gls_mem_read32(axr_addr) : 32'd0;
    m_axi_rlast   = (axr == 1) && (axr_cnt == 0);
    m_axi_rid     = 4'd0; m_axi_rresp = 2'd0;
    m_axi_awready = (axw == 0);
    m_axi_wready  = (axw == 1);
    m_axi_bvalid  = (axw == 2);
    m_axi_bid     = 4'd0; m_axi_bresp = 2'd0;
  endtask

  // axi_capture(): snapshot the pre-edge handshakes (DUT outputs + slave state).
  task automatic axi_capture();
    hs_ar = (axr == 0) && m_axi_arvalid;
    hs_r  = (axr == 1) && m_axi_rready;
    hs_aw = (axw == 0) && m_axi_awvalid;
    hs_w  = (axw == 1) && m_axi_wvalid;
    hs_b  = (axw == 2) && m_axi_bready;
    hs_araddr = m_axi_araddr[31:0] - REMAP_BASE;
    hs_arlen  = m_axi_arlen;
    hs_awaddr = m_axi_awaddr[31:0] - REMAP_BASE;
    hs_wdata  = m_axi_wdata;
    hs_wstrb  = m_axi_wstrb;
  endtask

  // axi_advance(): advance the slave FSMs on the rising edge using the snapshot.
  task automatic axi_advance();
    if (!rst_n) begin axr = 0; axw = 0; return; end
    // read channel
    if (axr == 0) begin
      if (hs_ar) begin
        axr_addr = hs_araddr; axr_cnt = hs_arlen; axr = 1; n_ar = n_ar + 1;
        if (gls_trace && n_ar <= gls_trace_n)
          $display("gls: [AR #%0d @cyc %0d] araddr=%h (phys %h) arlen=%0d",
                   n_ar, cycles, m_axi_araddr, hs_araddr, hs_arlen);
      end
    end else begin
      if (hs_r) begin
        n_rbeat = n_rbeat + 1; last_rd_addr = axr_addr;
        if (gls_trace && n_rbeat <= (gls_trace_n*8))
          $display("gls: [R beat #%0d] phys=%h data=%h rlast=%b",
                   n_rbeat, axr_addr, gls_mem_read32(axr_addr), m_axi_rlast);
        if (axr_cnt == 0) axr = 0;
        else begin axr_cnt = axr_cnt - 1; axr_addr = axr_addr + 4; end
      end
    end
    // write channel
    if (axw == 0) begin
      if (hs_aw) begin axw_addr = hs_awaddr; axw = 1; n_aw = n_aw + 1; end
    end else if (axw == 1) begin
      if (hs_w) begin
        gls_mem_write32(axw_addr & ~32'd3, hs_wdata, hs_wstrb);
        n_wbeat = n_wbeat + 1; last_wr_addr = axw_addr;
        axw = 2;
      end
    end else begin
      if (hs_b) axw = 0;
    end
  endtask

  // ---- port-I/O bridge service ---------------------------------------------
  // ONE side-effect per io_req assertion (gls_io_idle re-arms on deassert).
  logic g_term = 1'b0;   // isa-debug-exit seen
  task automatic io_service();
    int          r;
    int unsigned rd;
    if (!cosim_en || !io_req) begin
      io_rdata = 32'd0; io_ack = 1'b0;
      gls_io_idle();
      return;
    end
    r = gls_io_service(io_we ? 1 : 0, int'(io_addr), int'(io_size), io_wdata, rd);
    io_rdata = rd;
    io_ack   = r[0];          // bit0 = ack
    if (r[8]) g_term = 1'b1;  // bit8 = isa-debug-exit (out 0xf4)
  endtask

  // ---- VEN_DBG_CORE: committed-PC ring + wedge/fault auto-detector ----------
  // The GLS equivalent of dbg_dump_core(): a 32-deep ring of the most-recently-
  // retired committed PCs ({eip,cs,state}), a no-retire wedge watchdog, and a
  // non-IRQ exception detector. On a wedge or a fault the ring + AXI fetch addr
  // are dumped automatically and the sim stops, so a divergence is caught without
  // watching a slow log.
`ifdef VEN_DBG_CORE
  localparam int DBG_RING = 32;
  logic [31:0] ring_eip   [DBG_RING];
  logic [15:0] ring_cs    [DBG_RING];
  logic [5:0]  ring_state [DBG_RING];
  logic [63:0] ring_cyc   [DBG_RING];
  int          ring_head  = 0;   // next write slot
  int          ring_n     = 0;   // entries captured (saturates at DBG_RING)
  longint unsigned dbg_retired = 0;

  // wedge watchdog: cycles since the last retire.
  longint unsigned last_retire_cyc = 0;
  // fault detector: the previous-cycle vector, so we see a NEW delivery edge.
  logic [7:0]  prev_int_vec = 8'd0;
  bit          dbg_armed    = 1'b0;   // arm only after reset release
  // wedge threshold (cycles with no retire) — set via +dbg_wedge_k; 0 disables.
  longint unsigned dbg_wedge_k = 64'd200_000;
  bit          dbg_stop_on_fault = 1'b1;  // +dbg_no_stop_fault clears it
  bit          dbg_dumped = 1'b0;

  // sample one committed retire into the ring (called on a dbg_retire_valid edge).
  task automatic dbg_ring_push();
    ring_eip[ring_head]   = dbg_eip;
    ring_cs[ring_head]    = dbg_cs;
    ring_state[ring_head] = dbg_state;
    ring_cyc[ring_head]   = cycles;
    ring_head = (ring_head + 1) % DBG_RING;
    if (ring_n < DBG_RING) ring_n = ring_n + 1;
    dbg_retired = dbg_retired + 1;
    last_retire_cyc = cycles;
  endtask

  // dump the committed-PC ring newest->oldest + live state + the AXI fetch addr.
  task automatic dbg_dump_ring(input string reason);
    int idx;
    $display("");
    $display("gls-dbg: ======== CORE DUMP (%s) @ cyc %0d ========", reason, cycles);
    $display("gls-dbg:   committed: eip=%08h cs=%04h esp=%08h eflags=%08h",
             dbg_eip, dbg_cs, dbg_esp, dbg_eflags);
    $display("gls-dbg:   state=%0d(0x%02h) intvec=0x%02h faultpc=%08h cr0=%08h",
             dbg_state, dbg_state, dbg_int_vec, dbg_fault_pc, dbg_cr0);
    $display("gls-dbg:   ibuf@eip = %016h", dbg_ibuf);
    $display("gls-dbg:   retired=%0d (last @cyc %0d, %0d cyc ago) cpu_hung=%b",
             dbg_retired, last_retire_cyc, cycles - last_retire_cyc, cpu_hung);
    $display("gls-dbg:   AXI fetch: arvalid=%b araddr=%h (phys %h) | last AR phys=%h rbeat=%h@%h",
             m_axi_arvalid, m_axi_araddr, m_axi_araddr[31:0] - REMAP_BASE,
             last_rd_addr, dbg_rd_data, dbg_rd_addr);
    $display("gls-dbg:   --- committed-PC ring (newest first, %0d entries) ---", ring_n);
    for (int k = 0; k < ring_n; k++) begin
      idx = (ring_head - 1 - k + DBG_RING*4) % DBG_RING;
      $display("gls-dbg:     [-%0d] cs:eip=%04h:%08h state=%0d @cyc %0d",
               k, ring_cs[idx], ring_eip[idx], ring_state[idx], ring_cyc[idx]);
    end
    $display("gls-dbg: ===============================================");
    $display("");
  endtask
`endif

  // ---- run ------------------------------------------------------------------
  longint unsigned cycles = 0;
  longint unsigned max_cycles;
  longint unsigned report_every;
  longint unsigned nin, nout;
  int              irqp;
  string           disk_path, bios_path;
  int              rc;

  initial begin
    if (!$value$plusargs("disk=%s", disk_path)) disk_path = "";
    if (!$value$plusargs("bios=%s", bios_path))
      bios_path = "sw/ps/kv260/assets/seabios.bin";
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 64'd20_000_000;
    if (!$value$plusargs("report_every=%d", report_every)) report_every = 64'd200_000;
    if ($test$plusargs("gls_trace")) gls_trace = 1'b1;       // +gls_trace = AR/beat forensics
    void'($value$plusargs("gls_trace_n=%d", gls_trace_n));
`ifdef VEN_DBG_CORE
    void'($value$plusargs("dbg_wedge_k=%d", dbg_wedge_k));   // 0 = disable wedge watchdog
    if ($test$plusargs("dbg_no_stop_fault")) dbg_stop_on_fault = 1'b0;
    $display("gls-dbg: VEN_DBG_CORE taps ACTIVE (wedge_k=%0d stop_on_fault=%b)",
             dbg_wedge_k, dbg_stop_on_fault);
`endif

    rc = gls_init(disk_path, bios_path);
    if (rc != 0) begin $display("gls: init failed rc=%0d", rc); $finish; end
    $display("gls: boot disk=%s bios=%s max_cycles=%0d",
             disk_path == "" ? "(none)" : disk_path, bios_path, max_cycles);

    // ---- reset: hold rst_n low until WELL PAST the unisim GSR release ----
    // CRITICAL (netlist mode): the funcsim unisim flops are pinned to their INIT
    // value by glbl's global-set-reset (GSR) for ROC_WIDTH = 100000 ps = 100 ns
    // after t=0 (glbl `initial`: GSR_int=1 for #(ROC_WIDTH)). A funcsim flop whose
    // synchronous reset term is itself derived from gated logic does NOT settle to
    // its true rst_n-reset value while GSR is still pinning the design — releasing
    // rst_n during the GSR window leaves part of the far-jump path at its raw INIT
    // (X-resolved-to-0) state instead of its proper reset value. Symptom: the reset
    // far-jump `jmp f000:e05b` (target phys 0xFE05B) mis-fetches phys 0x3620 and the
    // core wedges with 0 retires. Holding rst_n low until >100 ns (here ~150 ns)
    // gives every flop a clean synchronous reset AFTER GSR is gone; the far-jump
    // then fetches 0xFE040 (the 0xFE05B line) and SeaBIOS POST boots normally.
    // (RTL mode has no GSR; the extra low-reset clocks are harmless there.)
    clk = 0; rst_n = 0;
    axi_drive();
    #1;
    // toggle the clock with rst_n held low until both: >=4 reset clocks AND past GSR.
    for (int c = 0; (c < 4) || ($time < GSR_CLEAR); c++) begin
      clk = 0; io_service(); axi_drive(); #1;
      clk = 1; axi_capture(); io_service(); axi_drive(); #1; axi_advance();
    end
    rst_n = 1;
    $display("gls: reset released @ cycle 0 (t=%0t, past GSR)", $time);
`ifdef VEN_DBG_CORE
    dbg_armed = 1'b1; last_retire_cyc = 0; prev_int_vec = dbg_int_vec;
`endif

    // ---- main run loop ----
    forever begin
      // F3 IRQ0 pump (drive intr/inta_vector before the clk-low phase).
      irqp = gls_irq_poll(cycles);
      if (irqp[8]) begin intr = 1'b1; inta_vector = irqp[7:0]; end
      else            intr = 1'b0;

      // clk low: combinational settle + serve bus + io.
      clk = 0;
      flush_all = 1'b0;
      io_service(); axi_drive();
      #1;
      io_service(); axi_drive();
      #1;

      // clk high: rising edge.
      clk = 1;
      axi_capture();           // pre-edge handshake snapshot
      io_service(); axi_drive();
      #1;
      axi_advance();           // advance the slave on the rising edge
      io_service(); axi_drive();
      #1;

      // INTA boundary: the core took our injected vector this clock.
      if (inta) gls_inta();

      cycles = cycles + 1;

`ifdef VEN_DBG_CORE
      if (dbg_armed) begin
        // sample committed retires into the PC ring.
        if (dbg_retire_valid) dbg_ring_push();

        // fault detector: a NEW non-IRQ exception vector delivered. The DOS IRQ0
        // pump delivers vector 0x08 (and the BIOS IRQs 0x08-0x0F / 0x70-0x77),
        // which are expected; flag a non-IRQ vector (a real exception 0x00-0x1F
        // that is NOT a hardware IRQ, or a far/wild jump that derails decode).
        if (dbg_int_vec != prev_int_vec && dbg_int_vec != 8'd0) begin
          bit is_hw_irq;
          is_hw_irq = (dbg_int_vec >= 8'h08 && dbg_int_vec <= 8'h0F) ||
                      (dbg_int_vec >= 8'h70 && dbg_int_vec <= 8'h77);
          if (!is_hw_irq && dbg_int_vec <= 8'h1F && !dbg_dumped) begin
            $display("gls-dbg: !! NON-IRQ EXCEPTION vector=0x%02h delivered (faultpc=%08h) @ cyc %0d",
                     dbg_int_vec, dbg_fault_pc, cycles);
            dbg_dump_ring($sformatf("exception vec 0x%02h", dbg_int_vec));
            dbg_dumped = 1'b1;
            if (dbg_stop_on_fault) begin
              $display("gls-dbg: stop on fault (use +dbg_no_stop_fault to keep running)");
              break;
            end
          end
          prev_int_vec = dbg_int_vec;
        end

        // wedge watchdog: two cases, both gated by dbg_wedge_k (0 = disabled):
        //  (a) made progress, then K cycles with NO retire (a derail/wedge), or
        //  (b) NEVER retired even once after K cycles past reset (the documented
        //      reset far-jump -> phys 0x3620 wedge at retire=0 — caught too).
        if (dbg_wedge_k != 0 && !dbg_dumped &&
            ((dbg_retired > 0 && (cycles - last_retire_cyc) >= dbg_wedge_k) ||
             (dbg_retired == 0 && cycles >= dbg_wedge_k))) begin
          if (dbg_retired == 0)
            $display("gls-dbg: !! WEDGE: core NEVER retired an instruction in %0d cycles @ cyc %0d",
                     cycles, cycles);
          else
            $display("gls-dbg: !! WEDGE: no retire for %0d cycles (last retire @cyc %0d) @ cyc %0d",
                     cycles - last_retire_cyc, last_retire_cyc, cycles);
          dbg_dump_ring("retire wedge");
          dbg_dumped = 1'b1;
          break;
        end
      end
`endif

      // termination: isa-debug-exit.
      if (g_term) begin
        $display("gls: stop: isa-debug-exit (out 0xf4) @ cycle %0d", cycles);
        break;
      end
      // termination: bus fault / cpu hung.
      if (bus_err) begin
        $display("gls: stop: bus_err asserted @ cycle %0d", cycles);
        break;
      end
      if (cycles >= max_cycles) begin
        $display("gls: stop: max_cycles %0d reached", max_cycles);
        break;
      end

      // progress report.
      if (report_every != 0 && (cycles % report_every) == 0) begin
        gls_io_stats(nin, nout);
        $display("gls: [cyc %0d] retire=%0d io_in=%0d io_out=%0d | AXI ar=%0d rbeat=%0d aw=%0d wbeat=%0d lastrd=%h lastwr=%h | arvalid=%b araddr=%h hung=%b",
                 cycles, retire_count, nin, nout,
                 n_ar, n_rbeat, n_aw, n_wbeat, last_rd_addr, last_wr_addr,
                 m_axi_arvalid, m_axi_araddr, cpu_hung);
`ifdef VEN_DBG_CORE
        // committed-PC + FSM trajectory line (the dbg taps the netlist now exposes).
        $display("gls-dbg: [cyc %0d] committed cs:eip=%04h:%08h esp=%08h efl=%08h | state=%0d intvec=0x%02h faultpc=%08h | dbg_retired=%0d ring=%0d",
                 cycles, dbg_cs, dbg_eip, dbg_esp, dbg_eflags,
                 dbg_state, dbg_int_vec, dbg_fault_pc, dbg_retired, ring_n);
`endif
      end
    end

    gls_io_stats(nin, nout);
    $display("gls: DONE cycles=%0d io_in=%0d io_out=%0d retire_count=%0d",
             cycles, nin, nout, retire_count);
`ifdef VEN_DBG_CORE
    // final trajectory snapshot (skip if a wedge/fault already dumped the ring).
    if (!dbg_dumped) dbg_dump_ring("final");
`endif
    $finish;
  end

endmodule
