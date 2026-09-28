`timescale 1ns/1ps
module tb_l1axi_pair_hit;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  logic clk = 0, rst_n = 0, flush = 0, cd = 0;
  always #5 clk = !clk;
  logic core_req = 0, core_we = 0;
  logic [31:0] core_addr = 0, core_wdata = 0, core_rdata;
  logic [3:0] core_wstrb = 0;
  logic core_ack, bus_err, m_idle, core_ic_nocache;
  logic [1:0] pair_req_valid = 0, pair_req_ready, pair_req_split;
  logic [1:0][31:0] pair_paddr = '0;
  logic [1:0][1:0] pair_size_log2 = '0;
  logic [1:0][15:0] pair_owner = '0, pair_rsp_owner;
  logic pair_bank_conflict;
  logic [1:0] pair_rsp_valid, pair_rsp_cancel, pair_rsp_ready = 0;
  logic [1:0][31:0] pair_rsp_paddr, pair_rsp_data;
  logic [3:0] awid, awcache, awqos, awprot, bid, arid, arcache, arqos, arprot, rid;
  logic [39:0] awaddr, araddr;
  logic [7:0] awlen, arlen;
  logic [2:0] awsize, arsize;
  logic [1:0] awburst, arburst, bresp, rresp;
  logic awlock, awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic arlock, arvalid, arready, rlast, rvalid, rready;
  logic [31:0] ar_count, burst_beats;
  int checks = 0;

  ventium_l1_axi #(.ADDR_W(40), .REMAP_BASE(REMAP_BASE),
                   .ADDR_MASK(32'h3fff_ffff)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(flush), .golden_l1(1'b0), .shutdown(1'b0), .m_idle,
      .smm_active(1'b0), .smbase(32'h0003_0000), .smm_flush_o(),
      .core_lock(1'b0), .core_lock_hold(1'b0),
      .core_req, .core_we, .core_addr, .core_lin(core_addr),
      .core_wdata, .core_wstrb, .core_rdata, .core_ack,
      .core_pair_req_valid(pair_req_valid), .core_pair_paddr(pair_paddr),
      .core_pair_size_log2(pair_size_log2), .core_pair_owner(pair_owner),
      .core_pair_req_ready(pair_req_ready), .core_pair_req_split(pair_req_split),
      .core_pair_bank_conflict(pair_bank_conflict),
      .core_pair_rsp_valid(pair_rsp_valid), .core_pair_rsp_cancel(pair_rsp_cancel),
      .core_pair_rsp_ready(pair_rsp_ready), .core_pair_rsp_owner(pair_rsp_owner),
      .core_pair_rsp_paddr(pair_rsp_paddr), .core_pair_rsp_data(pair_rsp_data),
      .core_ic_nocache, .bus_err, .cr0_cd(cd),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
      .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
      .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos),
      .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
      .m_axi_wvalid(wvalid), .m_axi_wready(wready),
      .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
      .m_axi_bready(bready), .m_axi_arid(arid), .m_axi_araddr(araddr),
      .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
      .m_axi_arlock(arlock), .m_axi_arcache(arcache), .m_axi_arprot(arprot),
      .m_axi_arqos(arqos), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
      .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
      .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));

  axi_slave_bfm #(.ADDR_W(40), .REMAP_BASE(REMAP_BASE), .RD_LAT(2)) slv (
      .clk, .rst_n, .ar_count, .burst_beats,
      .awid, .awaddr, .awlen, .awsize, .awburst, .awvalid, .awready,
      .wdata, .wstrb, .wlast, .wvalid, .wready,
      .bid, .bresp, .bvalid, .bready,
      .arid, .araddr, .arlen, .arsize, .arburst, .arvalid, .arready,
      .rid, .rdata, .rresp, .rlast, .rvalid, .rready);

  task automatic step;
    @(posedge clk); #1;
  endtask

  task automatic fill_line(input logic [31:0] addr);
    int guard;
    @(negedge clk);
    core_req = 1; core_we = 0; core_addr = addr; core_wstrb = 4'hf;
    guard = 0;
    do begin
      step();
      if (++guard > 300) $fatal(1, "line fill timed out at %h", addr);
    end while (!core_ack);
    if (core_rdata != slv.peek(addr))
      $fatal(1, "line fill value mismatch at %h got=%h", addr, core_rdata);
    @(negedge clk); core_req = 0;
    // Critical-word-first ACK precedes the remaining burst beats. A resident
    // pair must wait until the fill owns no backing response and the tag is
    // committed, not infer readiness from the first architectural ACK.
    guard = 0;
    do begin
      step();
      if (++guard > 300) $fatal(1, "line fill never drained at %h", addr);
    end while (dut.u_l1d.st != 0);
  endtask

  initial begin
    logic [31:0] ar_before;
    for (int i = 0; i < 8; i++)
      slv.poke(32'h1000 + 32'(4*i), 32'h77000000 + 32'(i));
    repeat (4) step();
    @(negedge clk); rst_n = 1;
    fill_line(32'h1000);
    ar_before = ar_count;

`ifdef VEN_P54_DUAL_HIT_LEGACY_CAPTURE
    for (int i = 0; i < 8; i++)
      slv.poke(32'h1020 + 32'(4*i), 32'h88000000 + 32'(i));
    fill_line(32'h1024);
    ar_before = ar_count;
    @(negedge clk);
    core_req = 1; core_we = 0; core_addr = 32'h1000; core_wstrb = 4'hf;
    pair_req_valid = 2'b10; pair_paddr[1] = 32'h1024;
    pair_size_log2[1] = 2'd2; pair_owner[1] = 16'h6677;
    #1;
    if (pair_req_ready != 2'b10 || core_ack)
      $fatal(1, "fresh U/V distinct-bank capture not admitted");
    step();
    if (!core_ack || core_rdata != slv.peek(32'h1000) ||
        pair_rsp_valid != 2'b10 || pair_rsp_owner[1] != 16'h6677 ||
        pair_rsp_data[1] != slv.peek(32'h1024) || ar_count != ar_before)
      $fatal(1, "fresh U/V wrapper response or backing mismatch");
    checks++;
    @(negedge clk); pair_req_valid = 0; pair_rsp_ready = 2'b10;
    step();
    @(negedge clk); core_req = 0; pair_rsp_ready = 0;
    if (|pair_rsp_valid) $fatal(1, "fresh V wrapper response duplicated");
    fill_line(32'h1004); // rejects reuse of a mixed U/V line window
    if (ar_count != ar_before) $fatal(1, "fresh U/V overlap caused a miss");
    checks++;

    fill_line(32'h1024); // move the registered window off U's line
    @(negedge clk); core_req = 1; core_addr = 32'h1000;
    pair_req_valid = 2'b10; pair_paddr[1] = 32'h1020;
    #1;
    if (pair_req_ready != 0 || !pair_bank_conflict)
      $fatal(1, "same-bank V escaped U's capture reservation");
    step();
    if (!core_ack || core_rdata != slv.peek(32'h1000) || |pair_rsp_valid)
      $fatal(1, "same-bank V rejection disturbed U wrapper response");
    checks++;
    @(negedge clk); pair_req_valid = 0;
    step();
    @(negedge clk); core_req = 0;
`endif

    // A real two-bank resident read through the entire L1/AXI wrapper.
    @(negedge clk);
    pair_req_valid = 2'b11;
    pair_paddr[0] = 32'h1000; pair_paddr[1] = 32'h1004;
    pair_size_log2 = {2'd2,2'd2};
    pair_owner[0] = 16'h71; pair_owner[1] = 16'h72;
    #1;
    if (pair_req_ready != 2'b11 || pair_bank_conflict || |pair_req_split)
      $fatal(1, "distinct-bank pair was not admitted ready=%b enable=%b st=%0d armed=%b hit=%b map=%b/%b route=%b smram=%b",
             pair_req_ready, dut.pair_enable, dut.u_l1d.st,
             dut.u_l1d.rd_armed, dut.u_l1d.pair_hit,
             dut.pair_map_l1c, dut.pair_map_dram,
             dut.core_route_deny, dut.core_smram_deny);
    step();
    if (pair_rsp_valid != 2'b11 || pair_rsp_owner[0] != 16'h71 ||
        pair_rsp_owner[1] != 16'h72 || pair_rsp_data[0] != 32'h77000000 ||
        pair_rsp_data[1] != 32'h77000001 || ar_count != ar_before)
      $fatal(1, "pair response/owner/backing mismatch U=%h V=%h",
             pair_rsp_data[0], pair_rsp_data[1]);
    checks++;
    @(negedge clk); pair_req_valid = 0; pair_rsp_ready = 2'b11;
    step();
    if (|pair_rsp_valid) $fatal(1, "pair response did not drain");
    checks++;

    // Same-bank requests serialize in U-before-V order.
    @(negedge clk);
    pair_rsp_ready = 0; pair_req_valid = 2'b11;
    pair_paddr[0] = 32'h1000; pair_paddr[1] = 32'h1000;
    #1;
    if (pair_req_ready != 2'b01 || !pair_bank_conflict)
      $fatal(1, "same-bank pair did not serialize");
    step();
    if (pair_rsp_valid != 2'b01 || pair_rsp_data[0] != 32'h77000000)
      $fatal(1, "same-bank U response wrong");
    checks++;
    @(negedge clk); pair_req_valid = 0; pair_rsp_ready = 2'b01;
    step();

    // CR0.CD must reject even a still-resident tag; no extra AXI read occurs.
    @(negedge clk); cd = 1; pair_req_valid = 2'b01;
    #1;
    if (pair_req_ready != 2'b00 || ar_count != ar_before)
      $fatal(1, "cache-disable admitted a pair read");
    checks++;
    @(negedge clk); pair_req_valid = 0; cd = 0;

    // Cache type is classified independently for V. The U hit may be
    // accepted, but the MMIO V request must never become a cached response or
    // cause a speculative device read. With MMIO in U, younger V cannot pass.
    pair_req_valid = 2'b11;
    pair_paddr[0] = 32'h1000; pair_paddr[1] = 32'h000a_0000;
    #1;
    if (dut.pair_map_l1c[1] || pair_req_ready != 2'b01 || ar_count != ar_before)
      $fatal(1, "MMIO V was cached or older U was lost ready=%b", pair_req_ready);
    step();
    if (pair_rsp_valid != 2'b01 || pair_rsp_data[0] != 32'h77000000)
      $fatal(1, "cacheable U response lost while V MMIO rejected");
    @(negedge clk); pair_req_valid = 0; pair_rsp_ready = 2'b01;
    step();
    @(negedge clk);
    pair_rsp_ready = 0; pair_req_valid = 2'b11;
    pair_paddr[0] = 32'h000a_0000; pair_paddr[1] = 32'h1004;
    #1;
    if (pair_req_ready != 2'b00 || ar_count != ar_before)
      $fatal(1, "younger V overtook uncached U");
    checks++;
    @(negedge clk); pair_req_valid = 0;

    // Flush cancels a captured response before either lane can consume it.
    pair_req_valid = 2'b11;
    pair_paddr[0] = 32'h1000; pair_paddr[1] = 32'h1004;
    #1;
    if (pair_req_ready != 2'b11) $fatal(1, "refill pair not admitted");
    step();
    @(negedge clk); pair_req_valid = 0; flush = 1;
    #1;
    if (|pair_rsp_valid || pair_rsp_cancel != 2'b11)
      $fatal(1, "flush did not cancel owned pair");
    step();
    if (|pair_rsp_valid || |pair_rsp_cancel) $fatal(1, "canceled pair retained");
    checks++;
    $display("L1AXI-PAIR-HIT-OK checks=%0d", checks);
    $finish;
  end
  initial begin #1000000; $fatal(1, "L1AXI pair-hit timeout"); end
endmodule
