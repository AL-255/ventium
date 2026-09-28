// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Self-checking AXI-WRAP8 -> Avalon bridge regression.  Avalon has only an
// incrementing burst, so each critical-word offset must split at the line end
// while presenting one ordered AXI R response. Runs all offsets with and without
// Avalon command/data stalls, changing IDs and addresses without resetting.

module tb_axi2avalon;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [3:0] awid = '0; logic [39:0] awaddr = '0; logic [7:0] awlen = '0;
  logic [2:0] awsize = '0; logic [1:0] awburst = '0; logic awvalid = 1'b0, awready;
  logic [31:0] wdata = '0; logic [3:0] wstrb = '0; logic wlast = 1'b0, wvalid = 1'b0, wready;
  logic [3:0] bid; logic [1:0] bresp; logic bvalid, bready = 1'b1;
  logic [3:0] arid = 4'h6; logic [39:0] araddr = 40'h0000_000014;
  logic [7:0] arlen = 8'd7; logic [2:0] arsize = 3'd2; logic [1:0] arburst = 2'b10;
  logic arvalid = 1'b0, arready;
  logic [3:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready = 1'b1;

  logic [29:0] avm_address; logic [31:0] avm_writedata; logic [3:0] avm_byteenable;
  logic [3:0] avm_burstcount; logic avm_write, avm_read, avm_waitrequest = 1'b0;
  logic avm_readdatavalid; logic [31:0] avm_readdata;
  int tick = 0;
  int start_word = 5;
  int line_base = 0;
  bit jitter = 0;
  logic [31:0] memory [1024];
  logic [31:0] expected_memory [1024];
  always @(negedge clk) begin
    tick = tick + 1;
`ifndef VEN_BRIDGE_REAL_L2
    avm_waitrequest = jitter && ((tick % 5) < 2);
`endif
  end

  ven_axi2avalon dut (
      .clk, .rst_n,
      .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
      .s_axi_awsize(awsize), .s_axi_awburst(awburst), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
      .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
      .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize),
      .s_axi_arburst(arburst), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
      .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
      .s_axi_rvalid(rvalid), .s_axi_rready(rready),
      .avm_address, .avm_writedata, .avm_byteenable, .avm_burstcount, .avm_write,
      .avm_read, .avm_waitrequest, .avm_readdatavalid, .avm_readdata);

  // Minimal Avalon responder.  It accepts one command and returns incrementing
  // dwords; the bridge must not issue its second command until this first data
  // stream has fully drained.
  logic av_active = 1'b0;
  logic [29:0] av_addr_q = '0;
  logic [3:0] av_left = '0;
`ifdef VEN_BRIDGE_REAL_L2
  // Real ao486 cache, not a replacement Avalon responder. The external DDR
  // transaction survives CPU reset and keeps BUSY asserted until its last beat.
  wire [24:0] ddr_addr;
  wire [63:0] ddr_din;
  wire [7:0] ddr_be, ddr_count;
  wire ddr_rd, ddr_we;
  logic [63:0] ddr_dout = 0;
  logic ddr_valid = 0;
  logic [24:0] ddr_next = 0;
  int ddr_left = 0, ddr_delay = 0;
  int ddr_reads = 0;
  int invalidation_reads_before;
  int forced_ddr_gap = 0;
  logic cache_inv = 0;
  logic [24:0] cache_inv_addr = 0;
  l2_cache #(.ADDRBITS(24)) cache (
    .CLK(clk), .RESET(!rst_n), .DISABLE(1'b0),
    .l2_inv_pulse(cache_inv), .l2_inv_addr(cache_inv_addr),
    .CPU_ADDR(avm_address), .CPU_DIN(avm_writedata),
    .CPU_DOUT(avm_readdata), .CPU_DOUT_READY(avm_readdatavalid),
    .CPU_BE(avm_byteenable), .CPU_BURSTCNT(avm_burstcount),
    .CPU_BUSY(avm_waitrequest), .CPU_RD(avm_read), .CPU_WE(avm_write),
    .DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be),
    .DDRAM_BURSTCNT(ddr_count), .DDRAM_RD(ddr_rd), .DDRAM_WE(ddr_we),
    .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_valid),
    .DDRAM_BUSY(av_active),
    .VGA_ADDR(), .VGA_DIN(8'd0), .VGA_DOUT(), .VGA_MODE(3'd0),
    .VGA_RD(), .VGA_WE(), .VGA_WR_SEG(6'd0), .VGA_RD_SEG(6'd0),
    .VGA_FB_EN(1'b0), .uma_ram(1'b0));
  always @(posedge clk) begin
    ddr_valid <= 0;
    if (ddr_rd && !av_active) begin
      if (ddr_count != 8) $fatal(1, "unexpected DDR read size");
      ddr_reads <= ddr_reads + 1;
      av_active <= 1; ddr_left <= int'(ddr_count);
      ddr_next <= ddr_addr; ddr_delay <= 3;
    end
    if (ddr_we && !av_active) begin
      if (ddr_count != 1) $fatal(1, "unexpected DDR write size");
      for (int lane = 0; lane < 8; lane++)
        if (ddr_be[lane])
          memory[int'(ddr_addr)*2 + lane/4][(lane%4)*8+:8] <= ddr_din[lane*8+:8];
    end
    if (av_active) begin
      if (ddr_delay != 0) ddr_delay <= ddr_delay - 1;
      else begin
        ddr_dout <= {memory[int'(ddr_next)*2+1], memory[int'(ddr_next)*2]};
        ddr_valid <= 1;
        ddr_next <= ddr_next + 1;
        ddr_left <= ddr_left - 1;
        ddr_delay <= forced_ddr_gap != 0 ? forced_ddr_gap : (jitter ? 3 : 0);
        if (ddr_left == 1) av_active <= 0;
      end
    end
  end
`else
  assign avm_readdatavalid = av_active && (!jitter || ((tick % 7) >= 3));
  assign avm_readdata = memory[av_addr_q[9:0]];
  always_ff @(posedge clk) begin
    if (rst_n && avm_write && !avm_waitrequest) begin
      if (av_active) $fatal(1, "write overlapped outstanding read");
      for (int lane = 0; lane < 4; lane++)
        if (avm_byteenable[lane])
          memory[avm_address[9:0]][8*lane+:8] <= avm_writedata[8*lane+:8];
    end
    if (!rst_n) begin
      av_active <= 1'b0; av_addr_q <= '0; av_left <= '0;
    end else if (avm_read && !avm_waitrequest) begin
      if (av_active) $fatal(1, "Avalon bridge launched overlapping commands");
      av_active <= 1'b1; av_addr_q <= avm_address; av_left <= avm_burstcount;
    end else if (avm_readdatavalid) begin
      if (av_left == 4'd1) av_active <= 1'b0;
      else begin av_left <= av_left - 4'd1; av_addr_q <= av_addr_q + 30'd1; end
    end
  end
`endif

  int errs = 0, cmd_n = 0, rsp_n = 0, rlast_n = 0;
`ifdef VEN_BRIDGE_WRITE_PERF
  int b_seen_total = 0;
  always_ff @(posedge clk) if (rst_n && bvalid && bready)
    b_seen_total <= b_seen_total + 1;
`endif
  function automatic logic [31:0] expect_data(input int n);
    logic [2:0] word;
    word = (start_word[2:0] + n[2:0]);
    expect_data = expected_memory[line_base + int'(word)];
  endfunction

  always_ff @(posedge clk) begin
    if (rst_n && avm_read && !avm_waitrequest) begin
      if (cmd_n == 0) begin
        if (avm_address != 30'(line_base + start_word) || avm_burstcount != 4'(8-start_word)) begin
          $display("FAIL first Avalon command addr=%0d count=%0d", avm_address, avm_burstcount);
          errs <= errs + 1;
        end
      end else if (cmd_n == 1) begin
        if (start_word == 0 || avm_address != 30'(line_base) || avm_burstcount != 4'(start_word)) begin
          $display("FAIL second Avalon command addr=%0d count=%0d", avm_address, avm_burstcount);
          errs <= errs + 1;
        end
      end else begin
        $display("FAIL unexpected Avalon read command %0d", cmd_n);
        errs <= errs + 1;
      end
      cmd_n <= cmd_n + 1;
    end
    if (rst_n && rvalid && rready) begin
      if (rdata != expect_data(rsp_n)) begin
        $display("FAIL AXI R beat %0d data=%08x want=%08x", rsp_n, rdata, expect_data(rsp_n));
        errs <= errs + 1;
      end
      if (rid != arid || rresp != 2'b00) begin
        $display("FAIL AXI R metadata rid=%0d resp=%0d", rid, rresp);
        errs <= errs + 1;
      end
      if (rlast) rlast_n <= rlast_n + 1;
      if (rlast != (rsp_n == 7)) begin
        $display("FAIL AXI RLAST beat=%0d rlast=%0d", rsp_n, rlast);
        errs <= errs + 1;
      end
      rsp_n <= rsp_n + 1;
    end
  end

  int read_first_clocks, read_total_clocks;
  task automatic read_line;
    int begin_tick;
    begin_tick = tick;
    read_first_clocks = -1;
    cmd_n = 0; rsp_n = 0; rlast_n = 0;
    araddr = (40'(line_base) + 40'(start_word)) << 2;
    arvalid = 1'b1;
    @(posedge clk);
    if (!arready) $fatal(1, "AXI AR was not accepted from idle");
    @(negedge clk); arvalid = 1'b0;
    for (int guard = 0; guard < 1024 && rsp_n != 8; guard++) begin
      @(negedge clk);
      if (rsp_n != 0 && read_first_clocks < 0) read_first_clocks = tick - begin_tick;
    end
    read_total_clocks = tick - begin_tick;
    repeat (2) @(negedge clk);
    if (cmd_n != ((start_word == 0) ? 1 : 2)) $fatal(1, "Avalon command count %0d", cmd_n);
    if (rsp_n != 8 || rlast_n != 1) $fatal(1, "AXI response counts %0d/%0d", rsp_n, rlast_n);
  endtask

  task automatic write_word(input int address_word, input logic [3:0] mask,
                            input logic [31:0] value);
    @(negedge clk);
    awaddr = 40'(address_word) << 2; awid = mask;
    awsize = 3'd2; awburst = 2'b01; awvalid = 1'b1;
    bready = 1'b0;
    @(posedge clk);
    if (!awready) $fatal(1, "write address not accepted from idle");
    @(negedge clk); awvalid = 1'b0;
    // Independent AW and W timing; the bridge must retain the address/ID.
    repeat (3) @(negedge clk);
    wdata = value; wstrb = mask; wlast = 1'b1; wvalid = 1'b1;
    begin
      bit accepted;
      accepted = 0;
      for (int guard = 0; guard < 32 && !accepted; guard++) begin
        @(posedge clk); accepted = wready;
      end
      if (!accepted) $fatal(1, "write data timeout");
    end
    @(negedge clk); wvalid = 1'b0;
    repeat (4) begin
      if (!bvalid || bid != mask || bresp != 0) $fatal(1, "lost/stale write response");
`ifdef VEN_AXI2AVL_BPIPE
      if (arready || avm_write) $fatal(1, "read/command escaped held B response");
`else
      if (arready || awready || avm_write) $fatal(1, "ownership released before B handshake");
`endif
      @(negedge clk);
    end
    bready = 1'b1;
    @(negedge clk);
    for (int lane = 0; lane < 4; lane++)
      if (mask[lane]) expected_memory[address_word][8*lane+:8] = value[8*lane+:8];
  endtask

  task automatic write_quad(input int address_word, input logic [31:0] low_word,
                            input logic [31:0] high_word);
    @(negedge clk);
    awaddr = 40'(address_word) << 2; awid = 4'ha;
    awlen = 8'd1; awsize = 3'd2; awburst = 2'b01;
    awvalid = 1'b1; bready = 1'b0;
    @(posedge clk);
    if (!awready) $fatal(1, "quad AW not accepted");
    @(negedge clk); awvalid = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      wdata = (beat == 0) ? low_word : high_word;
      wstrb = 4'hf; wlast = (beat == 1); wvalid = 1'b1;
      begin
        bit accepted = 0;
        for (int guard = 0; guard < 64 && !accepted; guard++) begin
          @(posedge clk); accepted = wready;
        end
        if (!accepted) $fatal(1, "quad W timeout beat=%0d", beat);
      end
      @(negedge clk);
      wvalid = 1'b0;
      if (beat == 0 && bvalid) $fatal(1, "B before final quad W");
      // A gap between W beats also tests that the bridge retains its address
      // and does not release AW ownership after the first Avalon dword.
      repeat (2) @(negedge clk);
    end
    for (int guard = 0; guard < 64 && !bvalid; guard++) @(negedge clk);
    if (!bvalid || bid != 4'ha || bresp != 0) $fatal(1, "quad B missing/wrong");
    bready = 1'b1;
    @(negedge clk);
    awlen = 8'd0;
    expected_memory[address_word] = low_word;
    expected_memory[address_word+1] = high_word;
  endtask

  initial begin
    for (int i = 0; i < 1024; i++) begin
      memory[i] = 32'hCAFE_0000 | 32'(i);
      expected_memory[i] = 32'hCAFE_0000 | 32'(i);
    end
    repeat (4) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
`ifdef VEN_BRIDGE_REAL_L2
    repeat (160) @(negedge clk);
`endif
    // No reset between transactions: changed IDs and line addresses catch stale
    // response ownership as well as every critical-word split. Jitter exercises
    // held Avalon commands and bubbles in both fragments, not AXI backpressure
    // (the production master promises RREADY throughout the burst).
    for (int mode = 0; mode < 2; mode++) begin
      for (int half_line = 0; half_line < 2; half_line++) begin
      for (int word_index = 0; word_index < 8; word_index++) begin
        @(negedge clk);
        jitter = (mode != 0);
        start_word = word_index;
        line_base = (mode * 16 + half_line * 8 + word_index) * 32 + half_line * 8;
        arid = 4'(mode * 8 + word_index);
        read_line();
        $display("WRAP-LATENCY mode=%0d half=%0d word=%0d first=%0d total=%0d",
                 mode, half_line, word_index, read_first_clocks, read_total_clocks);
      end
      end
    end
    $display("AXI2AVALON coverage: 32 consecutive WRAP8 transactions, all offsets, both 64-byte halves, command/data jitter");
    line_base = 512;
    for (int mask = 0; mask < 16; mask++) begin
      start_word = mask % 8;
      write_word(line_base + start_word, 4'(mask), 32'h1234_5678 ^ (32'(mask) * 32'h0101_0101));
      read_line();
    end
    $display("AXI2AVALON coverage: all 16 write strobes, delayed W, held B, immediate single-read visibility");
    jitter = 1;
    write_quad(520, 32'h2468_ace0, 32'h1357_9bdf);
    line_base = 520; start_word = 0;
    read_line();
    $display("AXI2AVALON coverage: two-beat quadword write, W gap, one B, Avalon waitrequest");
`ifdef VEN_BRIDGE_WRITE_PERF
    // A fixed stream of independent aligned stores uses ordinary AXI
    // handshakes and drains all B responses. This reports bridge throughput,
    // not CPU/gameplay IPC; both profiles perform the same visible writes.
    begin
      int begin_tick, begin_b, guard;
      bit got_aw, got_w;
      jitter = 0; bready = 1;
      repeat (2) @(negedge clk);
      begin_tick = tick; begin_b = b_seen_total;
      for (int i = 0; i < 16; i++) begin
        awid = 4'(i); awaddr = (40'(800) + 40'(i)) << 2; awlen = 0;
        awsize = 3'd2; awburst = 2'b01; awvalid = 1;
        wdata = 32'h5555_0000 | 32'(i); wstrb = 4'hf;
        wlast = 1; wvalid = 1;
        got_aw = 0; got_w = 0; guard = 0;
        while (!got_aw || !got_w) begin
          @(posedge clk);
          if (awvalid && awready) got_aw = 1;
          if (wvalid && wready) got_w = 1;
          @(negedge clk);
          if (got_aw) awvalid = 0;
          if (got_w) wvalid = 0;
          if (++guard > 128) $fatal(1, "stream write %0d stalled", i);
        end
        expected_memory[800+i] = 32'h5555_0000 | 32'(i);
      end
      guard = 0;
      while (b_seen_total != begin_b + 16) begin
        @(negedge clk);
        if (++guard > 128) $fatal(1, "stream B responses stalled");
      end
      $display("AXI2AVALON-WRITE-PERF clocks=%0d stores=16", tick-begin_tick);
      line_base = 800; start_word = 0; read_line();
      line_base = 808; start_word = 0; read_line();
    end
`endif
`ifdef VEN_AXI2AVL_BPIPE
    // Hold the first B response while a second AW/W completes.  The first BID
    // must not change when the bridge captures the younger AWID; two pending
    // responses consume both bounded slots, then drain in exact FIFO order.
    jitter = 0;
    repeat (2) @(negedge clk);
    bready = 0;
    awid = 4'h1; awaddr = 40'(600 * 4); awlen = 0;
    awsize = 3'd2; awburst = 2'b01; awvalid = 1;
    @(posedge clk); if (!awready) $fatal(1, "first pipelined AW rejected");
    @(negedge clk); awvalid = 0; wdata = 32'h1111_aaaa;
    wstrb = 4'hf; wlast = 1; wvalid = 1;
    @(posedge clk); if (!wready) $fatal(1, "first pipelined W rejected");
    @(negedge clk); wvalid = 0;
    if (!bvalid || bid != 4'h1 || !awready || arready)
      $fatal(1, "first held B did not free ordered AW issue");
    awid = 4'h2; awaddr = 40'(601 * 4); awvalid = 1;
    @(posedge clk); if (!awready || bid != 4'h1)
      $fatal(1, "second AW did not overlap held first B");
    @(negedge clk); awvalid = 0; wdata = 32'h2222_bbbb; wvalid = 1;
    @(posedge clk); if (!wready || bid != 4'h1)
      $fatal(1, "second W changed older BID");
    @(negedge clk); wvalid = 0;
    if (!bvalid || bid != 4'h1 || awready || arready)
      $fatal(1, "full B queue did not retain ordered responses");
    bready = 1;
    @(posedge clk); if (!bvalid || bid != 4'h1)
      $fatal(1, "first B drain order wrong");
    @(negedge clk);
    if (!bvalid || bid != 4'h2)
      $fatal(1, "second B drain order wrong");
    @(posedge clk);
    @(negedge clk);
    if (bvalid || memory[600] != 32'h1111_aaaa || memory[601] != 32'h2222_bbbb)
      $fatal(1, "B queue or Avalon writes did not drain exactly");
    expected_memory[600] = 32'h1111_aaaa;
    expected_memory[601] = 32'h2222_bbbb;
    line_base = 600; start_word = 0;
    read_line();
    // A reset cancels queued responses, even when the Avalon write already
    // reached memory. It must not leak an old BID into the next guest epoch.
    @(negedge clk);
    bready = 0; awid = 4'h3; awaddr = 40'(602 * 4); awvalid = 1;
    @(posedge clk); if (!awready) $fatal(1, "reset probe AW rejected");
    @(negedge clk); awvalid = 0; wdata = 32'h3333_cccc; wvalid = 1;
    @(posedge clk); if (!wready) $fatal(1, "reset probe W rejected");
    @(negedge clk); wvalid = 0;
    if (!bvalid || bid != 4'h3) $fatal(1, "reset probe B not queued");
    rst_n = 0;
    repeat (2) @(negedge clk);
    if (bvalid) $fatal(1, "queued B survived reset");
    rst_n = 1; bready = 1;
`ifdef VEN_BRIDGE_REAL_L2
    // l2_cache walks its tag RAM after reset; the next read must not start
    // until that platform-specific recovery has finished.
    repeat (160) @(negedge clk);
`endif
    $display("AXI2AVALON-BPIPE-GATE-OK (two held ordered B responses; reset cancellation)");
`endif
`ifdef VEN_BRIDGE_REAL_L2
    // Invalidate a resident line after two words of an eight-word cache-hit
    // response. The miss/refill must continue at the remaining-word cursor.
    // Restarting a streaming response from the original command duplicates
    // words and corrupts RLAST/ownership even though RAM itself did not change.
    line_base = 544; start_word = 0; jitter = 1;
    read_line();
    wait (!avm_waitrequest);
    @(negedge clk);
    invalidation_reads_before = ddr_reads;
    fork
      read_line();
      begin
        wait (rsp_n == 2);
        @(negedge clk);
        cache_inv_addr = 25'(line_base >> 1);
        cache_inv = 1;
        @(negedge clk); cache_inv = 0;
      end
    join
    if (ddr_reads != invalidation_reads_before + 1)
      $fatal(1, "mid-hit invalidation did not trigger exactly one refill: before=%0d after=%0d",
             invalidation_reads_before, ddr_reads);
    $display("AXI2AVALON coverage: mid-hit-burst invalidation preserves remaining-word order");
`endif
    // Shared-reset contract: both bridge and Avalon responder cancel pending
    // work. This deliberately does NOT claim protection against a backend
    // surviving reset and later returning stale data (which carries no ID).
    for (int cut = 0; cut < 8; cut++) begin
      @(negedge clk);
      start_word = 5; line_base = 640; arid = 4'(cut);
      cmd_n = 0; rsp_n = 0; rlast_n = 0;
      araddr = (40'(line_base) + 40'(start_word)) << 2;
      arvalid = 1'b1;
      @(posedge clk);
      if (!arready) $fatal(1, "reset probe AR not accepted");
      @(negedge clk); arvalid = 1'b0;
      for (int guard = 0; guard < 160 && rsp_n < cut; guard++) @(negedge clk);
      if (rsp_n != cut) $fatal(1, "reset probe response count");
      rst_n = 1'b0;
      repeat (2) @(negedge clk);
      if (rvalid || bvalid || avm_read || avm_write) $fatal(1, "reset failed to cancel bridge transaction");
      rst_n = 1'b1;
`ifdef VEN_BRIDGE_REAL_L2
      repeat (160) @(negedge clk);
`endif
      arid = 4'(15-cut); line_base = 768;
      read_line();
    end
    $display("AXI2AVALON coverage: shared reset before/after each partial response length, clean reuse");
`ifdef VEN_BRIDGE_REAL_L2
    for (int slow = 0; slow < 2; slow++) begin
      @(negedge clk);
      // Streaming can finish AXI before the previous DDR tail. Drain that
      // unrelated transaction before identifying the new reset victim.
      for (int guard = 0; guard < 512 && av_active; guard++) @(negedge clk);
      if (av_active) $fatal(1, "previous DDR tail did not drain");
      forced_ddr_gap = slow != 0 ? 40 : 3;
      start_word = 0; line_base = 896; arid = 4'hd;
      cmd_n = 0; rsp_n = 0; rlast_n = 0;
      araddr = 40'(line_base) << 2; arvalid = 1;
      @(posedge clk);
      if (!arready) $fatal(1, "in-flight reset AR not accepted");
      @(negedge clk); arvalid = 0;
      for (int guard = 0; guard < 128 && !av_active; guard++) @(negedge clk);
      if (!av_active || ddr_left != 8) $fatal(1, "reset missed active DDR burst");
      rst_n = 0;
      repeat (4) @(negedge clk);
      rst_n = 1;
      repeat (160) begin
        @(negedge clk);
        if (rvalid || bvalid) $fatal(1, "old DDR response escaped after reset");
      end
      if (slow != 0 && !av_active) $fatal(1, "slow DDR witness failed to outlive cache startup");
      line_base = 960; arid = 4'he;
      read_line();
      forced_ddr_gap = 0;
    end
    $display("AXI2AVALON coverage: real cache, old DDR burst survives reset/startup, fresh single read exact");
`endif
    if (errs == 0) $display("AXI2AVALON-WRAP-GATE-OK");
    else           $display("AXI2AVALON-WRAP-GATE-FAIL errs=%0d", errs);
    $finish;
  end
endmodule
