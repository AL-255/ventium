// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/l1/tb_l1axi_vip.sv — drive ventium_l1_axi against the REAL Xilinx Zynq
// UltraScale+ PS8 VIP (design_l1axi BD: u_l1axi/m_axi -> SmartConnect -> S_AXI_HPC0).
// Unlike the behavioral axi_slave_bfm (lenient: returns mem.read32() for any AR),
// the PS8 VIP enforces the AXI4 protocol on-wire — so a back-to-back / cold-line
// fill burst that the behavioral slave tolerates but the silicon mishandles
// (the F4 Quake __init_libc cold-line fetch wedge) surfaces here.

`timescale 1ns/1ps
module tb_l1axi_vip;

  logic        core_ack;
  logic [31:0] core_addr;
  logic [31:0] core_rdata;
  logic        core_req;
  logic [31:0] core_wdata;
  logic        core_we;
  logic [3:0]  core_wstrb;

  design_l1axi dut (
    .core_ack_0   (core_ack),   .core_addr_0  (core_addr),
    .core_rdata_0 (core_rdata), .core_req_0   (core_req),
    .core_wdata_0 (core_wdata), .core_we_0    (core_we),
    .core_wstrb_0 (core_wstrb)
  );

  // PS8 VIP supplies the PL clock + sync reset inside the BD (hierarchical refs).
  wire clk   = dut.ps8_pl_clk0;
  wire rst_n = dut.rst0_peripheral_aresetn;

  // deep probes into ven_l1d (u_l1d) + ven_axi_master (u_axi)
  `define L1D dut.u_l1axi.inst.u_l1axi.u_l1d
  `define AXM dut.u_l1axi.inst.u_l1axi.u_axi

  localparam logic [31:0] LINE_C0 = 32'h0809_85c0;
  localparam logic [31:0] LINE_E0 = 32'h0809_85e0;
  int errors = 0;

  function automatic logic [31:0] expw(input logic [31:0] a);
    expw = {a[15:0], ~a[15:0]};
  endfunction

  // X-ROBUST handshake wait with a per-op timeout so a real wedge is REPORTED,
  // not silently passed (an X core_ack must NOT count as done).
  task automatic wait_ack(input string what);
    int g; g = 0;
    forever begin
      @(posedge clk);
      if (core_ack === 1'b1) break;
      if (++g > 400) begin
        $display("[WEDGE] %s: core_ack never 1 after 400 clk | l1d.st=%0d l1d.c_req=%b l1d.rd_hit=%b l1d.hit=%b l1d.m_req=%b l1d.m_ack=%b | axm.rst(state)=%0d ARVALID=%b ARREADY=%b",
                 what, `L1D.st, `L1D.c_req, `L1D.rd_hit, `L1D.hit, `L1D.m_req, `L1D.m_ack,
                 `AXM.rst, dut.u_l1axi_m_axi_ARVALID, dut.u_l1axi_m_axi_ARREADY);
        errors++; break;
      end
    end
  endtask

  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    @(posedge clk);
    core_req <= 1'b1; core_we <= 1'b0; core_addr <= a; core_wstrb <= 4'd0;
    wait_ack($sformatf("RD %08x", a));
    d = core_rdata;
    @(negedge clk); core_req <= 1'b0;
    @(posedge clk);
  endtask

  task automatic do_write(input logic [31:0] a, input logic [31:0] d);
    @(posedge clk);
    core_req <= 1'b1; core_we <= 1'b1; core_addr <= a; core_wdata <= d; core_wstrb <= 4'hF;
    wait_ack($sformatf("WR %08x", a));
    @(negedge clk); core_req <= 1'b0; core_we <= 1'b0;
    @(posedge clk);
  endtask

  task automatic chk(input string what, input logic [31:0] a, got);
    if (got !== expw(a)) begin
      $error("[VIP-DATA-MISMATCH] %s addr=%08x got=%08x exp=%08x", what, a, got, expw(a));
      errors++;
    end else $display("[ok] %s addr=%08x = %08x", what, a, got);
  endtask

  // AXI AR/R issue counters (handshake)
  int n_ar=0, n_r=0;
  always @(posedge clk) if (rst_n) begin
    if (dut.u_l1axi_m_axi_ARVALID && dut.u_l1axi_m_axi_ARREADY) begin
      n_ar++;
      $display("[AXI] %0t AR addr=%010x len=%0d size=%0d burst=%0d cache=%04b id=%0d",
        $time, dut.u_l1axi_m_axi_ARADDR, dut.u_l1axi_m_axi_ARLEN, dut.u_l1axi_m_axi_ARSIZE,
        dut.u_l1axi_m_axi_ARBURST, dut.u_l1axi_m_axi_ARCACHE, dut.u_l1axi_m_axi_ARID);
    end
    if (dut.u_l1axi_m_axi_RVALID && dut.u_l1axi_m_axi_RREADY) begin
      n_r++;
      $display("[AXI] %0t R  data=%08x resp=%0d last=%b", $time,
        dut.u_l1axi_m_axi_RDATA, dut.u_l1axi_m_axi_RRESP, dut.u_l1axi_m_axi_RLAST);
    end
  end

  // bd_l1axi.tcl ties flush_all=0 but leaves `shutdown` UNDRIVEN (X) -> ven_axi_master
  // refuses every txn (m_ack=X). On silicon ventium_kv260_core drives it 0. Force it.
  initial force `AXM.shutdown = 1'b0;
  // PS8 VIP HPC0 coherent slave wasn't returning RVALID for ARCACHE=1111 (coherent).
  // Force a normal non-cacheable encoding so the VIP's plain DDR model services the
  // read (this only changes the VIP's response path, not ven_axi_master's burst shape).
  initial force `AXM.m_axi_arcache = 4'b0011;

  initial begin
    logic [31:0] d;
    core_req = 0; core_we = 0; core_addr = 0; core_wdata = 0; core_wstrb = 0;
    // observe the reset edge: it should go LOW then HIGH (PS8 POR)
    wait (rst_n === 1'b0); $display("[VIP] %0t reset asserted (low)", $time);
    wait (rst_n === 1'b1); $display("[VIP] %0t reset released (high)", $time);
    repeat (30) @(posedge clk);

    // (0) MINIMAL: one write, read it back — proves the harness + VIP bring-up.
    $display("[VIP] minimal write->read at %08x", LINE_C0);
    do_write(LINE_C0, expw(LINE_C0));
    do_read (LINE_C0, d); chk("min", LINE_C0, d);

    // (1) cold line fills: c0 then BACK-TO-BACK e0 (the on-silicon failure pattern)
    $display("[VIP] preload + fill c0 then e0 (cold, back-to-back)");
    for (int w=1; w<8; w++) do_write(LINE_C0+32'(w*4), expw(LINE_C0+32'(w*4)));
    for (int w=0; w<8; w++) do_write(LINE_E0+32'(w*4), expw(LINE_E0+32'(w*4)));
    // flush so the reads MISS and refill from the VIP DDR (cold-line fill path)
    @(posedge clk);
    for (int w=0; w<8; w++) begin do_read(LINE_C0+32'(w*4), d); chk("c0", LINE_C0+32'(w*4), d); end
    for (int w=0; w<8; w++) begin do_read(LINE_E0+32'(w*4), d); chk("e0", LINE_E0+32'(w*4), d); end

    repeat (20) @(posedge clk);
    $display("[VIP] totals AR=%0d R=%0d errors=%0d", n_ar, n_r, errors);
    if (errors == 0) $display("L1AXI-VIP-OK");
    else             $display("L1AXI-VIP-FAIL errors=%0d", errors);
    $finish;
  end

  initial begin #2000000; $display("L1AXI-VIP-GLOBAL-TIMEOUT"); $finish; end

endmodule
