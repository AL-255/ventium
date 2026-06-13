// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_cdc.sv — P1-3 dual-clock gate for ventium_l1_axi (+VEN_AXI_CDC).
//
// Proves the clock-domain-crossing bridge (ven_axi_cdc + two ven_cdc_afifo + the
// reset synchronizers) preserves the ven_l1d <-> ven_axi_master backing contract when
// core_clk and axi_clk run at DIFFERENT, unrelated rates. The same DUT + behavioral
// AXI4 DDR slave (axi_slave_bfm, multi-cycle + BUBBLE) is instantiated at four clock
// ratios — axi faster, axi slower, equal, and a 5:3 coprime skew — and each runs a
// read-fill / all-8-hit / write-through+readback / 2-way-evict / store-miss->load
// scenario, checking every returned word. A CDC bug (lost ack, FIFO pointer/Gray
// error, re-triggered burst, dropped beat) corrupts data or hangs -> FAIL. Verilator
// cannot model metastability (that is guaranteed structurally by the 2-FF Gray
// synchronizers); it DOES prove the functional protocol across the ratios.
//
// Build: verilator --binary -sv --assert +define+VEN_AXI_CDC ... (run-l1axi-cdc-gate.sh)
// Prints L1AXICDC-GATE-OK / L1AXICDC-GATE-FAIL.

// ----------------------------------------------------------------------------
// one ratio: clocks, DUT(+CDC), slave, scenario. Reports errs + done (no $finish).
// ----------------------------------------------------------------------------
module cdc_harness #(
    parameter int    CORE_HALF = 5,    // core_clk half-period
    parameter int    AXI_HALF  = 2,    // axi_clk  half-period
    parameter string TAG       = "?"
) (
    output logic       done,
    output int         errs
);
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;
  localparam int          ADDR_W     = 40;

  logic core_clk=0, axi_clk=0, core_rst_n=0, axi_rst_n=0;
  always #(CORE_HALF) core_clk = ~core_clk;
  always #(AXI_HALF)  axi_clk  = ~axi_clk;

  // core side
  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        bus_err; logic flush = 1'b0;

  // AXI master <-> slave
  logic [3:0]        awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]        awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]        awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0]       wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]        bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]        arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]        arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]        arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]        rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK)) dut (
      .core_clk(core_clk), .core_rst_n(core_rst_n), .axi_clk(axi_clk), .axi_rst_n(axi_rst_n),
      .flush_all(flush), .shutdown(1'b0), .m_idle(),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack), .bus_err(bus_err),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache),
      .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
      .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
      .m_axi_bready(bready), .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
      .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_rid(rid), .m_axi_rdata(rdata),
      .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  // the slave runs in the AXI clock domain.
  axi_slave_bfm #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .RD_LAT(4), .WR_LAT(3), .BUBBLE(1)) slv (
      .clk(axi_clk), .rst_n(axi_rst_n),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
      .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp),
      .rlast(rlast), .rvalid(rvalid), .rready(rready)
  );

  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin $display("  FAIL [%s] %s: got %08x exp %08x", TAG, what, got, exp); errs++; end
  endtask

  // core READ to `a`, spin to c_ack (multi-cycle miss through the CDC), return data.
  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    int guard;
    @(negedge core_clk); c_req<=1'b1; c_we<=1'b0; c_addr<=a; c_wstrb<=4'd0;
    guard=0;
    forever begin
      @(posedge core_clk); #1;
      if (c_ack) begin d = c_rdata; break; end
      if (++guard > 5000) begin $display("  FAIL [%s] read %08x: no ack", TAG, a); errs++; d=32'hx; break; end
    end
    @(negedge core_clk); c_req<=1'b0;
  endtask

  task automatic do_write(input logic [31:0] a, d);
    int guard;
    @(negedge core_clk); c_req<=1'b1; c_we<=1'b1; c_addr<=a; c_wdata<=d; c_wstrb<=4'hF;
    guard=0;
    forever begin @(posedge core_clk); #1; if (c_ack) break;
      if (++guard>5000) begin $display("  FAIL [%s] write %08x: no ack",TAG,a); errs++; break; end end
    @(negedge core_clk); c_req<=1'b0; c_we<=1'b0;
  endtask

  // back-to-back write burst KEEPING c_req HIGH the whole time — ven_l1d then holds
  // m_req continuously (the FNSAVE / stack-push pattern that DEADLOCKED a bridge that
  // waited for !c_req). The address advances only BETWEEN posedges (next iteration's
  // negedge), mimicking the core presenting the next access the cycle after c_ack —
  // so no posedge ever samples a stale (held) address. A regression for that bug.
  task automatic do_wburst(input logic [31:0] base, input int n);
    int guard;
    for (int i=0;i<n;i++) begin
      @(negedge core_clk); c_req<=1'b1; c_we<=1'b1; c_addr<=base+32'(i)*4;
      c_wdata<=32'hB00B_0000+32'(i); c_wstrb<=4'hF;
      guard=0;
      forever begin @(posedge core_clk); #1; if (c_ack) break;
        if (++guard>5000) begin $display("  FAIL [%s] wburst %0d: no ack",TAG,i); errs++; break; end end
      // c_req STAYS HIGH across the boundary (continuous m_req).
    end
    @(negedge core_clk); c_req<=1'b0; c_we<=1'b0;
  endtask

  logic [31:0] d;
  initial begin
    errs=0; done=1'b0;
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    for (logic [31:0] a=0; a<32'h4000; a+=4) slv.poke(a, a ^ 32'hA5A5_0000);
    // hold both raw resets low, release, then let the per-domain reset syncs settle.
    repeat(10) @(posedge core_clk);
    @(negedge core_clk); core_rst_n<=1'b1;
    @(negedge axi_clk);  axi_rst_n<=1'b1;
    repeat(8) @(posedge core_clk);

    // [1] cold read -> miss -> CDC -> INCR8 line fill -> hit
    do_read(32'h0000_1004, d); chk("read 0x1004", d, 32'h1004 ^ 32'hA5A5_0000);
    // [2] all 8 words of the filled line hit, correct data (FIFO order preserved)
    for (int w=0; w<8; w++) begin
      automatic logic [31:0] a = 32'h0000_1000 + 32'(w)*4;
      do_read(a, d); chk($sformatf("hit word %0d", w), d, a ^ 32'hA5A5_0000);
    end
    // [3] write-through then read-back (L1 array + DDR slave both updated via CDC)
    do_write(32'h0000_1008, 32'hDEAD_BEEF);
    do_read (32'h0000_1008, d); chk("read-after-write", d, 32'hDEAD_BEEF);
    chk("DDR slave got the write", slv.peek(32'h0000_1008), 32'hDEAD_BEEF);
    // [4] 2-way set: a 3rd distinct line into the same set evicts LRU
    do_read(32'h0000_2000, d); chk("line@2000", d, 32'h2000 ^ 32'hA5A5_0000);
    do_read(32'h0000_3000, d); chk("line@3000", d, 32'h3000 ^ 32'hA5A5_0000);
    do_read(32'h0000_2000, d); chk("rehit@2000", d, 32'h2000 ^ 32'hA5A5_0000);
    // [5] store-miss to a COLD line, then dependent load -> store landed in DDR
    do_write(32'h0000_6020, 32'hCAFE_F00D);
    chk("DDR slave has the cold store", slv.peek(32'h0000_6020), 32'hCAFE_F00D);
    do_read (32'h0000_6020, d); chk("dependent load sees store", d, 32'hCAFE_F00D);

    // [6] back-to-back write burst with CONTINUOUS c_req — the deadlock regression
    // (a bridge that waited for !c_req between transactions hangs here).
    do_wburst(32'h0000_7000, 6);
    for (int i=0;i<6;i++)
      chk($sformatf("wburst[%0d] in DDR", i), slv.peek(32'h0000_7000+32'(i)*4), 32'hB00B_0000+32'(i));

    // [7] reset-coupling regression: drop ONLY axi_rst_n mid-fill. The AND-coupled
    // reset syncs force BOTH domains to reset together, so the in-flight transaction
    // is abandoned in lockstep (no orphaned command -> no wedge). After release the
    // cold cache refills and traffic resumes. A bridge with INDEPENDENT resets would
    // hang here forever (the #34 watchdog, in the just-reset axi domain, can't fire).
    fork begin
      repeat(2) @(posedge core_clk);
      @(negedge axi_clk); axi_rst_n <= 1'b0;        // asymmetric: only the AXI domain
      repeat(5) @(posedge axi_clk);
      @(negedge axi_clk); axi_rst_n <= 1'b1;
    end join_none
    do_read(32'h0000_2480, d); chk("read across asym-reset", d, 32'h2480 ^ 32'hA5A5_0000);
    repeat(6) @(posedge core_clk);
    do_read(32'h0000_2500, d); chk("post-reset read", d, 32'h2500 ^ 32'hA5A5_0000);

    if (errs==0) $display("  ok  [%s] all CDC checks pass", TAG);
    done <= 1'b1;
  end
endmodule

// ----------------------------------------------------------------------------
// top: four clock ratios, aggregate.
// ----------------------------------------------------------------------------
module tb_l1axi_cdc;
  logic d0,d1,d2,d3; int e0,e1,e2,e3;
  // axi 2.5x faster than core (the intended MMCM case: slow core, fast PS-DDR link)
  cdc_harness #(.CORE_HALF(5), .AXI_HALF(2), .TAG("axi-fast 5:2"))  h0(.done(d0),.errs(e0));
  // axi slower than core (stress the other direction)
  cdc_harness #(.CORE_HALF(2), .AXI_HALF(5), .TAG("axi-slow 2:5"))  h1(.done(d1),.errs(e1));
  // equal rate (degenerate; must also hold)
  cdc_harness #(.CORE_HALF(4), .AXI_HALF(4), .TAG("equal 4:4"))     h2(.done(d2),.errs(e2));
  // coprime skew 5:3
  cdc_harness #(.CORE_HALF(5), .AXI_HALF(3), .TAG("coprime 5:3"))   h3(.done(d3),.errs(e3));

  initial begin
    wait (d0 && d1 && d2 && d3);
    if (e0+e1+e2+e3 == 0)
      $display("L1AXICDC-GATE-OK (CDC data-coherent across axi-fast/slow/equal/coprime)");
    else
      $display("L1AXICDC-GATE-FAIL (%0d errors)", e0+e1+e2+e3);
    $finish;
  end
  initial begin #4000000; $display("L1AXICDC-GATE-FAIL (timeout — CDC hang)"); $finish; end
endmodule
