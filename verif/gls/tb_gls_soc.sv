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
    .dbg_retire_valid(), .dbg_eip(), .dbg_cs(), .dbg_esp(), .dbg_eflags(),
    .dbg_state(), .dbg_int_vec(), .dbg_fault_pc(), .dbg_cr0(), .dbg_fctrl(),
    .dbg_fxop(), .dbg_ibuf(), .dbg_seg(), .dbg_de_num(), .dbg_de_info(),
    .dbg_hook_cfg(16'd0), .dbg_hook_seq(), .dbg_hook_eip(), .dbg_hook_opa(),
    .dbg_hook_opb(), .dbg_hook_meta(),
    .dbg_cmp_cfg(32'd0), .dbg_cmp_range(32'd0),
    .dbg_div_eip(), .dbg_div_eip70(), .dbg_div_info(), .dbg_cmp_freeze(),
    .dbg_rd_valid(), .dbg_rd_addr(), .dbg_rd_data(),
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
      end
    end

    gls_io_stats(nin, nout);
    $display("gls: DONE cycles=%0d io_in=%0d io_out=%0d retire_count=%0d",
             cycles, nin, nout, retire_count);
    $finish;
  end

endmodule
