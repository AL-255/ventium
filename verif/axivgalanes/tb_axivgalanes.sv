// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Production AXI->Avalon adapter AND actual ao486 VGA byte sequencer.
// The endpoint records device-read side effects; it is not a scanout model.
module tb_axivgalanes;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin #2000000; $fatal(1, "AXIVGALANES protocol watchdog"); end
  logic [3:0] awid = 1, bid, arid = 6, rid;
  logic [39:0] awaddr = 0, araddr = 0;
  logic [7:0] awlen = 0, arlen = 0;
  logic [2:0] awsize = 2, arsize = 0;
  logic [1:0] awburst = 1, arburst = 1, bresp, rresp;
  logic awvalid = 0, awready, wvalid = 0, wready, bvalid;
  logic arvalid = 0, arready, rvalid, rlast;
  logic [31:0] wdata = 32'h87654321, rdata;
  logic [3:0] wstrb = 0;
  logic [29:0] avaddr;
  logic [31:0] avwdata, avrdata;
  logic [3:0] avbe, avcount;
  logic avwrite, avread, avbusy, avvalid;
  ven_axi2avalon bridge (
    .clk, .rst_n, .s_axi_awid(awid), .s_axi_awaddr(awaddr),
    .s_axi_awlen(awlen), .s_axi_awsize(awsize), .s_axi_awburst(awburst),
    .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wlast(1'b1), .s_axi_wvalid(wvalid),
    .s_axi_wready(wready), .s_axi_bid(bid), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(1'b1), .s_axi_arid(arid),
    .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize),
    .s_axi_arburst(arburst), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
    .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(1'b1),
    .avm_address(avaddr), .avm_writedata(avwdata), .avm_byteenable(avbe),
    .avm_burstcount(avcount), .avm_write(avwrite), .avm_read(avread),
    .avm_waitrequest(avbusy), .avm_readdatavalid(avvalid), .avm_readdata(avrdata)
  );
  wire [16:0] vga_addr;
  wire [7:0] vga_dout;
  wire vga_rd, vga_we;
  wire [24:0] ddr_addr;
  wire [63:0] ddr_data;
  wire [7:0] ddr_be, ddr_count;
  wire ddr_rd, ddr_we;
  l2_cache #(.ADDRBITS(24)) cache (
    .CLK(clk), .RESET(!rst_n), .DISABLE(1'b1),
    .l2_inv_pulse(1'b0), .l2_inv_addr(25'd0),
    .CPU_ADDR(avaddr), .CPU_DIN(avwdata), .CPU_DOUT(avrdata),
    .CPU_DOUT_READY(avvalid), .CPU_BE(avbe), .CPU_BURSTCNT(avcount),
    .CPU_BUSY(avbusy), .CPU_RD(avread), .CPU_WE(avwrite),
    .DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_data), .DDRAM_DOUT(64'd0),
    .DDRAM_DOUT_READY(1'b0), .DDRAM_BE(ddr_be), .DDRAM_BURSTCNT(ddr_count),
    .DDRAM_BUSY(1'b0), .DDRAM_RD(ddr_rd), .DDRAM_WE(ddr_we),
    .VGA_ADDR(vga_addr), .VGA_DIN(8'h80 | {6'd0, vga_addr[1:0]}),
    .VGA_DOUT(vga_dout), .VGA_MODE(3'd5), .VGA_RD(vga_rd), .VGA_WE(vga_we),
`ifdef VEN_VGA_WIDE_STORE
    .VGA_WIDE_READY(1'b0), .VGA_WIDE_WE(), .VGA_WIDE_DOUT(),
`endif
    .VGA_WR_SEG(6'd0), .VGA_RD_SEG(6'd0), .VGA_FB_EN(1'b0), .uma_ram(1'b0)
  );

  int cases = 0, mask_failures = 0, strobe_failures = 0, latch_failures = 0;
  int read_commands = 0, responses = 0;
  bit observing = 0;
  logic [3:0] wanted, seen;
  logic [16:0] wanted_last, last_read;
  bit latch_valid = 0;
  // VGA's architectural latches load ONLY on enabled reads. Merely returning
  // plausible RDATA is insufficient: real VGA RAM outputs update without RD.
  always @(posedge clk) begin
    if (observing && avread && !avbusy) begin
      read_commands++;
      if (avcount != 1 || avaddr != araddr[31:2])
        $fatal(1, "unexpected Avalon command geometry");
      if (avbe !== wanted) begin
        mask_failures++;
        if (mask_failures <= 12)
          $display("MASK-FAIL case=%0d address=%h size=%0d previous_wstrb=%h got=%h want=%h",
                   cases, araddr, arsize, wstrb, avbe, wanted);
      end
    end
    if (observing && vga_rd) begin
      seen[vga_addr[1:0]] = 1;
      last_read = vga_addr;
      latch_valid = 1;
    end
    if (observing && rvalid) begin
      responses++;
      if (rid != arid || rresp != 0 || !rlast)
        $fatal(1, "unexpected AXI response metadata");
    end
    if (ddr_rd) $fatal(1, "VGA test unexpectedly routed a read to DDR");
  end

  task automatic wait_idle;
    bit ready;
    ready = 0;
    for (int guard = 0; guard < 2048 && !ready; guard++) begin
      @(negedge clk);
      ready = arready && !avbusy;
    end
    if (!ready) $fatal(1, "bus did not become idle");
  endtask

  task automatic preceding_write(input logic [3:0] mask);
    bit accepted;
    wait_idle();
    awaddr = 40'h00000a1000;
    wstrb = mask; awvalid = 1; wvalid = 1;
    accepted = 0;
    for (int guard = 0; guard < 2048 && !accepted; guard++) begin
      @(posedge clk); accepted = awready;
    end
    if (!accepted) $fatal(1, "AW timeout");
    // A write-through profile may accept W on the AW edge.
    accepted = wready;
    @(negedge clk); awvalid = 0;
    if (!accepted) begin
      for (int guard = 0; guard < 2048 && !accepted; guard++) begin
        @(posedge clk); accepted = wready;
      end
      @(negedge clk);
    end
    if (!accepted) $fatal(1, "W timeout");
    wvalid = 0;
    wait_idle();
    // WSTRB is deliberately retained after the legitimate write, matching
    // the production master register; an idle W channel is not read metadata.
  endtask

  task automatic read_piece(input logic [39:0] address, input logic [2:0] size);
    bit accepted, completed;
    int highest;
    wait_idle();
    cases++; araddr = address; arsize = size;
    wanted = 4'(((1 << (1 << size)) - 1) << address[1:0]);
    if (size > 2 || (size == 1 && address[0]) || (size == 2 && address[1:0] != 0))
      $fatal(1, "TB must issue naturally aligned AXI pieces");
    highest = 0;
    for (int lane = 0; lane < 4; lane++) if (wanted[lane]) highest = lane;
    wanted_last = {address[16:2], 2'b00} + 17'(highest);
    seen = 0; latch_valid = 0; last_read = 0;
    read_commands = 0; responses = 0; observing = 1;
    arvalid = 1; accepted = 0;
    for (int guard = 0; guard < 2048 && !accepted; guard++) begin
      @(posedge clk); accepted = arready;
    end
    if (!accepted) $fatal(1, "AR timeout");
    @(negedge clk); arvalid = 0;
    completed = 0;
    for (int guard = 0; guard < 2048 && !completed; guard++) begin
      @(negedge clk); completed = responses == 1;
    end
    if (!completed || read_commands != 1) $fatal(1, "read protocol failed");
    if (seen !== wanted) begin
      strobe_failures++;
      if (strobe_failures <= 12)
        $display("STROBE-FAIL case=%0d address=%h got=%h want=%h", cases, address, seen, wanted);
    end
    if (!latch_valid || last_read !== wanted_last) begin
      latch_failures++;
      if (latch_failures <= 12)
        $display("LATCH-OWNER-FAIL case=%0d valid=%0b got=%h want=%h", cases, latch_valid, last_read, wanted_last);
    end
    observing = 0;
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (200) @(negedge clk);
    for (int mask = 0; mask < 16; mask++) begin
      preceding_write(4'(mask));
      for (int lane = 0; lane < 4; lane++) read_piece(40'h00000a0200 + 40'(lane), 0);
      read_piece(40'h00000a0200, 1); read_piece(40'h00000a0202, 1);
      read_piece(40'h00000a0200, 2);
      // Unaligned logical 2B/4B MMIO spans are decomposed into the same legal
      // byte-exact pieces used by ven_l1d, never widened over adjacent bytes.
      read_piece(40'h00000a0201, 0); read_piece(40'h00000a0202, 0);
      read_piece(40'h00000a0201, 0); read_piece(40'h00000a0202, 1);
      read_piece(40'h00000a0204, 0);
    end
    $display("AXIVGALANES-SUMMARY cases=%0d mask_failures=%0d strobe_failures=%0d latch_failures=%0d",
             cases, mask_failures, strobe_failures, latch_failures);
    if (mask_failures || strobe_failures || latch_failures)
      $fatal(1, "AXIVGALANES-GATE-FAIL");
    $display("AXIVGALANES-GATE-OK");
    $finish;
  end
endmodule
