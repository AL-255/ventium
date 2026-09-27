// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// l2_cache lower-half streaming fill regression.  This uses a deliberately
// delayed tail: all eight requested dwords must be returned from the first
// four beats of ONE line read, before beat four is made available.  It also
// proves a same-line invalidation while filling cannot publish the new tag.

module tb_l2_stream_cwf;
  logic clk = 0;
  always #5 clk = ~clk;

  // A stuck phase wait must fail the gate rather than occupy a build forever.
  initial begin
    #1000000;
    $fatal(1, "L2 streaming regression watchdog expired");
  end

  logic reset = 0;
  logic cache_disable = 0;
  logic l2_inv_pulse = 0;
  logic [24:0] l2_inv_addr = 0;
  logic [29:0] cpu_addr = 0;
  logic [31:0] cpu_din = 0;
  wire  [31:0] cpu_dout;
  wire         cpu_dout_ready;
  logic  [3:0] cpu_be = 4'hf;
  logic  [3:0] cpu_burstcnt = 0;
  wire         cpu_busy;
  logic        cpu_rd = 0;
  logic        cpu_we = 0;

  wire [24:0] ddram_addr;
  wire [63:0] ddram_din;
  logic[63:0] ddram_dout = 0;
  wire  [7:0] ddram_be;
  wire  [7:0] ddram_burstcnt;
  logic       ddram_busy = 0;
  wire        ddram_rd;
  wire        ddram_we;
  logic       ddram_dout_ready = 0;

  wire [16:0] vga_addr;
  logic [7:0] vga_din = 0;
  wire [7:0] vga_dout;
  logic [2:0] vga_mode = 0;
  wire vga_rd, vga_we;
  logic [5:0] vga_wr_seg = 0, vga_rd_seg = 0;
  logic vga_fb_en = 0, uma_ram = 0;

  l2_cache #(.ADDRBITS(24)) dut (
    .CLK(clk), .RESET(reset), .DISABLE(cache_disable),
    .l2_inv_pulse(l2_inv_pulse), .l2_inv_addr(l2_inv_addr),
    .CPU_ADDR(cpu_addr), .CPU_DIN(cpu_din), .CPU_DOUT(cpu_dout),
    .CPU_DOUT_READY(cpu_dout_ready), .CPU_BE(cpu_be),
    .CPU_BURSTCNT(cpu_burstcnt), .CPU_BUSY(cpu_busy), .CPU_RD(cpu_rd),
    .CPU_WE(cpu_we), .DDRAM_ADDR(ddram_addr), .DDRAM_DIN(ddram_din),
    .DDRAM_DOUT(ddram_dout), .DDRAM_DOUT_READY(ddram_dout_ready),
    .DDRAM_BE(ddram_be), .DDRAM_BURSTCNT(ddram_burstcnt),
    .DDRAM_BUSY(ddram_busy), .DDRAM_RD(ddram_rd), .DDRAM_WE(ddram_we),
    .VGA_ADDR(vga_addr), .VGA_DIN(vga_din), .VGA_DOUT(vga_dout),
    .VGA_MODE(vga_mode), .VGA_RD(vga_rd), .VGA_WE(vga_we),
    .VGA_WR_SEG(vga_wr_seg), .VGA_RD_SEG(vga_rd_seg), .VGA_FB_EN(vga_fb_en),
    .uma_ram(uma_ram)
  );

  int cycle = 0;
  int commands = 0;
  int ddr_sent = 0;
  int next_beat = 0;
  int next_cycle = 0;
  int ddr_gap = 2;
  int tail_gap = 20;
  logic ddr_active = 0;
  logic [24:0] command_base = 0;

  function automatic [63:0] ddr_word(input int beat);
    ddr_word = {32'hcafe0000 + beat, 32'hface0000 + beat};
  endfunction

  // DDR model: beats 0..3 arrive at a normal two-cycle cadence.  The tail is
  // deliberately held back, so a correct lower-half bypass has ample time to
  // emit all eight requested dwords before any tail data exists.
  always @(posedge clk) begin
    cycle <= cycle + 1;
    ddram_dout_ready <= 1'b0;
    if (ddram_rd && !ddr_active) begin
      if (ddram_burstcnt !== 8) $fatal(1, "expected one eight-beat line command");
      commands     <= commands + 1;
      ddr_active   <= 1'b1;
      command_base <= ddram_addr;
      next_beat    <= 0;
      next_cycle   <= cycle + 3;
    end
    if (ddr_active && (cycle >= next_cycle)) begin
      ddram_dout       <= ddr_word(next_beat);
      ddram_dout_ready <= 1'b1;
      ddr_sent         <= ddr_sent + 1;
      if (next_beat == 7) begin
        ddr_active <= 1'b0;
      end else begin
        next_beat  <= next_beat + 1;
        // Delay tail beats 4..7.  A streamed lower half must not depend on
        // them, whereas an accidental normal-path fallback will time out.
        next_cycle <= cycle + ((next_beat == 3) ? tail_gap : ddr_gap);
      end
    end
  end

  int fails = 0;
  int response_n = 0;
  int response_phase = 0;
  int fill_start_ddr_sent = 0;
  logic early_only = 0;

  function automatic [31:0] expected_dword(input int n);
    expected_dword = n[0] ? (32'hcafe0000 + (n >> 1)) :
                             (32'hface0000 + (n >> 1));
  endfunction

  always @(posedge clk) begin
    if (cpu_dout_ready) begin
      if (cpu_dout !== expected_dword(response_n)) begin
        $display("FAIL phase=%0d word=%0d got=%08x expected=%08x",
                 response_phase, response_n, cpu_dout, expected_dword(response_n));
        fails <= fails + 1;
      end
      if (early_only && (ddr_sent > 4)) begin
        $display("FAIL lower-half response depended on delayed tail (ddr_sent=%0d)", ddr_sent);
        fails <= fails + 1;
      end
      response_n <= response_n + 1;
    end
  end

  task automatic begin_read(input logic [29:0] a);
    begin
      while (dut.state != 1) @(negedge clk);
      @(negedge clk);
      cpu_addr = a;
      cpu_burstcnt = 4'd8;
      cpu_rd = 1'b1;
      @(negedge clk);
      cpu_rd = 1'b0;
    end
  endtask

  task automatic wait_responses(input int n, input int lim);
    int deadline;
    begin
      deadline = cycle + lim;
      while ((response_n < n) && (cycle < deadline)) @(negedge clk);
      if (response_n != n) begin
        $display("FAIL timed out waiting for %0d response(s), got %0d", n, response_n);
        fails = fails + 1;
      end
    end
  endtask

  initial begin
    // l2_cache deliberately detects RESET after its two-register delay, so
    // begin low and give it an actual reset assertion edge.
    repeat (2) @(negedge clk);
    reset = 1;
    repeat (5) @(negedge clk);
    reset = 0;
    repeat (160) @(negedge clk);
    if (dut.state != 1) $fatal(1, "L2 failed reset/startup: state=%0d", dut.state);

    $display("== L2 stream-CWF: one command, early lower half, delayed tag ==");
    response_phase = 1;
    response_n = 0;
    early_only = 1'b1;
    begin_read(30'h0000040);       // byte 0x100, lower half of a 64-byte line
    wait_responses(8, 100);
    early_only = 1'b0;
    if (commands != 1) begin
      $display("FAIL first miss issued %0d DDR command(s), expected one", commands);
      fails = fails + 1;
    end
    if (!cpu_busy) begin
      $display("FAIL cache accepted a following request before tail/tag completion");
      fails = fails + 1;
    end
    while (dut.state != 1) @(negedge clk);

    // Once published, an ordinary hit must return the exact same sequence and
    // must not create a DDR command.
    response_phase = 2;
    response_n = 0;
    begin_read(30'h0000040);
    wait_responses(8, 100);
    if (commands != 1) begin
      $display("FAIL filled line did not hit (commands=%0d)", commands);
      fails = fails + 1;
    end
    while (dut.state != 1) @(negedge clk);

    // With a contiguous DDR response there are only seven cycles between the
    // first captured beat and the final beat.  This catches an implementation
    // that exits the stream FSM on the final fill beat before it has emitted
    // the eighth dword (the whole-PC FPGA-style bridge then waits forever).
    response_phase = 3;
    response_n = 0;
    ddr_gap = 1;
    tail_gap = 1;
    begin_read(30'h0000060);
    wait_responses(8, 100);
    if (commands != 2) begin
      $display("FAIL contiguous-tail miss issued %0d DDR command(s), expected two", commands);
      fails = fails + 1;
    end
    while (dut.state != 1) @(negedge clk);
    ddr_gap = 2;
    tail_gap = 20;

    // Invalidate a different lower-half line while its fill is still live.
    // The tag must stay dirty; the next read must fetch a new line.
    response_phase = 4;
    response_n = 0;
    fill_start_ddr_sent = ddr_sent;
    begin_read(30'h0000050);       // byte 0x140, another 64-byte line
    while (dut.state != 10) @(negedge clk);
    // Prior phases now issue two DDR bursts. A fixed threshold of nine
    // already passed before this miss, so it no longer meant mid-fill.
    while (ddr_sent <= fill_start_ddr_sent) @(negedge clk);
    @(negedge clk);
    l2_inv_addr = 25'h0000028;     // 64-bit beat address for byte 0x140
    l2_inv_pulse = 1'b1;
    @(negedge clk);
    l2_inv_pulse = 1'b0;
    wait_responses(8, 100);
    while (dut.state != 1) @(negedge clk);

    response_phase = 5;
    response_n = 0;
    begin_read(30'h0000050);
    wait_responses(8, 100);
    if (commands != 4) begin
      $display("FAIL fill-time invalidation was published as a hit (commands=%0d)", commands);
      fails = fails + 1;
    end

    // Sweep producer cadence independently of the tail boundary. In
    // particular, DDR may finish before, with, or after response word seven.
    // Each miss must emit exactly eight words and install a reusable line.
    for (int gap = 1; gap <= 4; gap++) begin
      for (int tail = 1; tail <= 4; tail++) begin
        automatic int before_commands;
        automatic logic [29:0] sweep_addr;
        while (dut.state != 1) @(negedge clk);
        before_commands = commands;
        sweep_addr = 30'h100 + 16 * ((gap-1)*4 + tail-1);
        ddr_gap = gap;
        tail_gap = tail;
        response_phase = 100 + gap*10 + tail;
        response_n = 0;
        begin_read(sweep_addr);
        wait_responses(8, 150);
        while (dut.state != 1) @(negedge clk);
        repeat (3) @(negedge clk);
        if (response_n != 8 || commands != before_commands + 1)
          $fatal(1, "cadence %0d/%0d: miss burst count mismatch", gap, tail);
        response_n = 0;
        begin_read(sweep_addr);
        wait_responses(8, 100);
        while (dut.state != 1) @(negedge clk);
        repeat (3) @(negedge clk);
        if (response_n != 8 || commands != before_commands + 1)
          $fatal(1, "cadence %0d/%0d: installed line did not hit", gap, tail);
      end
    end

`ifdef VEN_L2_PERF
    if (dut.l2p_stream_beats == 0 || dut.l2p_stream_cycles == 0)
      $fatal(1, "streamed fills missing from performance counters");
    if ((dut.l2p_stream_beats + dut.l2p_fill_beats) != ddr_sent)
      $fatal(1, "performance DDR beat count disagrees with independent producer");
`endif
    if (fails == 0) $display("L2-STREAM-CWF-GATE-OK");
    else            $display("L2-STREAM-CWF-GATE-FAIL (%0d failure(s))", fails);
    $finish;
  end
endmodule
