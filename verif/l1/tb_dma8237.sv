// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_dma8237.sv — Phase D.3 gate: the 8237 DMA TRANSFER ENGINE (ven_i8237_dma)
// driving the northbridge's coherent DMA requester end-to-end. The engine's memory master
// feeds ventium_l1_axi.dma_* (EN_L2=1, +VEN_NB_DMA); a DDR slave backs it. Proves:
//   * device→mem (dir=0): a programmed transfer writes a device pattern into memory; a CPU
//     read (through L1→NB→L2) sees it (coherent, write-back);
//   * mem→device (dir=1): a programmed transfer reads a seeded memory block into the device.
// Built with +define+VEN_NB_DMA. Prints DMA8237-GATE-OK / -FAIL. Run via run-dma8237-gate.sh.

module tb_dma8237;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;
  localparam int          ADDR_W     = 40;
  localparam int          L2_CAP     = 4096;     // a few sets so the 8-word lines fit
  localparam int          L2_WAYS    = 2;

  logic clk=0, rst_n=0; always #5 clk = ~clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        dma_req, dma_we; logic [31:0] dma_addr, dma_wdata; logic [3:0] dma_wstrb;
  logic [31:0] dma_rdata; logic dma_ack;

  logic [3:0]  awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]  awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]  awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0] wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]  bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]  arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]  arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]  arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]  rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  logic bus_err; logic m_idle;

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK),
                   .EN_L2(1'b1), .L2_CAP_BYTES(L2_CAP), .L2_WAYS(L2_WAYS)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(1'b0), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(m_idle),
      .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
      .dma_wstrb(dma_wstrb), .dma_rdata(dma_rdata), .dma_ack(dma_ack),
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

  axi_slave_bfm #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .RD_LAT(3), .WR_LAT(2), .BUBBLE(1)) slv (
      .clk(clk), .rst_n(rst_n),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
      .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp),
      .rlast(rlast), .rvalid(rvalid), .rready(rready)
  );

  // ---- the DMA transfer engine under test ------------------------------------
  logic        go; logic [31:0] start_addr; logic [15:0] count; logic dir;
  logic        busy, tc, dev_rd, dev_wr; logic [31:0] dev_rdata, dev_wdata;
  ven_i8237_dma u_dma (
      .clk(clk), .rst_n(rst_n),
      .go(go), .start_addr(start_addr), .count(count), .dir(dir), .busy(busy), .tc(tc),
      .dev_rd(dev_rd), .dev_rdata(dev_rdata), .dev_wr(dev_wr), .dev_wdata(dev_wdata),
      .m_req(dma_req), .m_we(dma_we), .m_addr(dma_addr), .m_wdata(dma_wdata),
      .m_wstrb(dma_wstrb), .m_rdata(dma_rdata), .m_ack(dma_ack)
  );

  // ---- device model: a source/sink buffer indexed by a transfer counter ------
  logic [31:0] devbuf [0:63];
  int devidx;
  assign dev_rdata = devbuf[devidx];                 // dir=0: device supplies words
  always @(posedge clk) begin
    if (dev_rd) devidx <= devidx + 1;
    if (dev_wr) begin devbuf[devidx] <= dev_wdata; devidx <= devidx + 1; end
  end

  int errors = 0;
  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %08x exp %08x", what, got, exp); errors++; end
    else $display("  ok   %s = %08x", what, got);
  endtask
  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_addr<=a; c_wstrb<=4'd0;
    guard=0; forever begin @(posedge clk); #1; if (c_ack) begin d=c_rdata; break; end
      if (++guard>400) begin $display("  FAIL read %08x: no ack",a); errors++; d=32'hx; break; end end
    @(negedge clk); c_req<=1'b0;
  endtask
  task automatic run_dma(input logic [31:0] a, input logic [15:0] n, input logic d);
    int guard;
    @(negedge clk); start_addr<=a; count<=n; dir<=d; go<=1'b1;
    @(negedge clk); go<=1'b0;
    guard=0; forever begin @(posedge clk); #1; if (tc) break;
      if (++guard>2000) begin $display("  FAIL dma never completed"); errors++; break; end end
  endtask

  logic [31:0] d;
  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0; go=0; start_addr=0; count=0; dir=0; devidx=0;
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    for (logic [32:0] a=0; a<33'h10_0000; a+=4) slv.poke(a[31:0], a[31:0] ^ 32'hA5A5_0000);
    for (int i=0;i<64;i++) devbuf[i] = 32'hD00D_0000 + i;       // device source pattern
    repeat(4) @(posedge clk); rst_n<=1'b1;
    repeat(40) @(posedge clk);                                  // wait L2 init

    $display("[1] device→mem (dir=0): DMA writes the device pattern into 0x5000..");
    devidx = 0;
    run_dma(32'h0000_5000, 16'd8, 1'b0);                        // 8 words device→mem
    chk("transfer completed (tc)", {31'd0, busy==0}, 32'd1);
    for (int w=0; w<8; w++) begin
      do_read(32'h0000_5000 + 32'(w)*4, d);
      chk($sformatf("mem[0x5000+%0d] == device word", w), d, 32'hD00D_0000 + w);
    end

    $display("[2] mem→device (dir=1): DMA reads a seeded block 0x6000.. into the device");
    // seed DDR via CPU writes so it's coherent in the L2 the DMA reads from.
    for (int w=0; w<8; w++) begin
      @(negedge clk); c_req<=1'b1; c_we<=1'b1; c_addr<=32'h0000_6000+32'(w)*4; c_wdata<=32'hBEEF_0000+w; c_wstrb<=4'hF;
      do begin @(posedge clk); #1; end while(!c_ack); @(negedge clk); c_req<=0; c_we<=0;
    end
    devidx = 0;
    run_dma(32'h0000_6000, 16'd8, 1'b1);                        // 8 words mem→device
    for (int w=0; w<8; w++)
      chk($sformatf("device[%0d] == mem 0x6000+%0d", w, w), devbuf[w], 32'hBEEF_0000 + w);

    // [COV] diverse DMA transfers: walking-bit device data + diverse start_addr,
    //       count and direction so the DMA datapath (rbuf/wbuf, start_addr/addr/
    //       m_addr, count/cnt, dev_rdata/dev_wdata/m_wdata) toggles broadly. The
    //       directed checks above use only two fixed transfers. Pure stimulus.
    for (int k = 0; k < 24; k++) begin
      for (int i = 0; i < 64; i++)
        devbuf[i] = (32'h1 << ((i + k) % 32)) ^ 32'(k * 32'h0408_1020 + i);
      devidx = 0;
      run_dma((32'h0001_0000 + (32'h20 << (k % 14))) & 32'h000F_FFE0,
              16'((16'h1 << (k % 7)) + 1), k[0]);   // diverse addr / count(1..65) / dir
    end

    // [COV] walking-bit CORE traffic (reads + writes) at diverse addresses so the
    //       core_addr/core_rdata/core_wdata path + the cache->AXI fill/evict
    //       addresses (m_addr, m_axi_awaddr/araddr, m_wdata) toggle their high bits.
    //       Pure stimulus (no chk). Addresses kept < 1 MiB (the seeded slave range).
    for (int i = 2; i < 20; i++) begin
      do_read(32'h1 << i, d);
      @(negedge clk); c_req<=1'b1; c_we<=1'b1; c_addr<=32'h1 << i;
      c_wdata<=~(32'h1 << i); c_wstrb<=4'hF;
      do begin @(posedge clk); #1; end while(!c_ack); @(negedge clk); c_req<=0; c_we<=0;
    end
    for (int i = 0; i < 20; i++) begin
      do_read((32'hA5A5_A5A5 >> i) & 32'h000F_FFFC, d);
      @(negedge clk); c_req<=1'b1; c_we<=1'b1; c_addr<=(32'h5A5A_5A5A >> i) & 32'h000F_FFFC;
      c_wdata<=32'(i) ^ 32'hF0F0_0F0F; c_wstrb<=4'hF;
      do begin @(posedge clk); #1; end while(!c_ack); @(negedge clk); c_req<=0; c_we<=0;
    end

    if (errors==0) $display("DMA8237-GATE-OK (all checks pass)");
    else           $display("DMA8237-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #2000000; $display("DMA8237-GATE-FAIL (timeout)"); $finish; end
endmodule
