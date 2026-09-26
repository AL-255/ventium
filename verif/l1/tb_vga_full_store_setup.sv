// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Actual l2_cache byte-port test: no VGA model supplies store completion.
module tb_vga_full_store_setup;
  logic clk = 0;
  always #5 clk = ~clk;
  initial begin #1000000; $fatal(1, "VGA setup watchdog"); end
  logic reset = 0, cpu_rd = 0, cpu_we = 0, ddr_busy = 0;
  logic [29:0] cpu_addr = 0;
  logic [31:0] cpu_data = 0;
  logic [3:0] cpu_be = 0, burst = 1;
  logic [2:0] mode = 5;
  logic [5:0] bank = 0;
  logic fb = 0;
  wire busy, ready, ddr_rd, ddr_we, vga_rd, vga_we;
  wire [31:0] cpu_out;
  wire [24:0] ddr_addr;
  wire [63:0] ddr_data;
  wire [7:0] ddr_be, ddr_burst, vga_data;
  wire [16:0] vga_addr;
  l2_cache #(.ADDRBITS(24)) dut (
    .CLK(clk), .RESET(reset), .DISABLE(1'b0),
    .l2_inv_pulse(1'b0), .l2_inv_addr(25'd0),
    .CPU_ADDR(cpu_addr), .CPU_DIN(cpu_data), .CPU_DOUT(cpu_out),
    .CPU_DOUT_READY(ready), .CPU_BE(cpu_be), .CPU_BURSTCNT(burst),
    .CPU_BUSY(busy), .CPU_RD(cpu_rd), .CPU_WE(cpu_we),
    .DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_data), .DDRAM_BE(ddr_be),
    .DDRAM_BURSTCNT(ddr_burst), .DDRAM_RD(ddr_rd), .DDRAM_WE(ddr_we),
    .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0), .DDRAM_BUSY(ddr_busy),
    .VGA_ADDR(vga_addr), .VGA_DIN(8'h3c), .VGA_DOUT(vga_data),
    .VGA_MODE(mode), .VGA_RD(vga_rd), .VGA_WE(vga_we),
    .VGA_WR_SEG(bank), .VGA_RD_SEG(bank), .VGA_FB_EN(fb), .uma_ram(1'b0)
  );
`ifdef VEN_VGA_FULL_STORE_SETUP
  localparam int ENABLED = 1;
`else
  localparam int ENABLED = 0;
`endif
  int cycle = 0, case_id = 0, next_lane = 0, byte_count = 0, ddr_count = 0;
  int checked = 0, reset_cases = 0, read_count = 0;
  bit active = 0, expect_vga = 0, expect_read = 0;
  bit resetting = 0, reset_quiet = 0;
  logic [16:0] expected_addr;
  logic [31:0] expected_data;
  logic [3:0] expected_be;
  logic [24:0] expected_ddr_addr;
  logic [7:0] expected_ddr_be;
  always @(posedge clk) begin
    cycle = cycle + 1;
    if (reset_quiet && (vga_we || vga_rd || dut.vga_wr || dut.vga_re ||
                        (dut.state != 1 && dut.vga_be != 0)))
      $fatal(1, "VGA strobe survived effective reset case=%0d", case_id);
    if (ddr_rd || (vga_rd && !expect_read))
      $fatal(1, "unexpected read while testing VGA writes");
    if (vga_rd) read_count++;
    if (vga_we) begin
      if (!active || !expect_vga) $fatal(1, "unexpected VGA write");
      while (next_lane < 4 && !expected_be[next_lane]) next_lane++;
      if (next_lane == 4 || vga_addr !== expected_addr + 17'(next_lane) ||
          vga_data !== expected_data[8*next_lane +: 8])
        $fatal(1, "byte mismatch case=%0d lane=%0d addr=%h data=%h", case_id, next_lane, vga_addr, vga_data);
      if (!resetting) $display("BYTE %0d %05x %02x", case_id, vga_addr, vga_data);
      next_lane++;
      byte_count++;
    end
    if (ddr_we) begin
      if (!active || expect_vga || ddr_addr !== expected_ddr_addr ||
          ddr_data !== {expected_data, expected_data} || ddr_be !== expected_ddr_be || ddr_burst !== 1)
        $fatal(1, "DDR passthrough mismatch case=%0d", case_id);
      ddr_count++;
      $display("DDR %0d %07x %016x %02x", case_id, ddr_addr, ddr_data, ddr_be);
    end
  end
  task automatic boot;
    reset = 0;
    repeat (3) @(negedge clk);
    reset = 1;
    repeat (5) @(negedge clk);
    reset = 0;
    repeat (160) @(negedge clk);
    if (dut.state != 1 || busy) $fatal(1, "startup failed");
    active = 0;
  endtask
  task automatic start_write(input logic [31:0] addr, input logic [3:0] be,
                             input bit is_vga);
    while (dut.state != 1 || busy) @(negedge clk);
    reset_quiet = 0;
    case_id++;
    cpu_addr = addr[31:2]; cpu_data = 32'hd3a7591b ^ (32'(case_id) * 32'h01010101);
    cpu_be = be; cpu_we = 1;
    expected_addr = addr[16:0]; expected_data = cpu_data; expected_be = be;
    expected_ddr_addr = addr[27:3];
    if (fb && is_vga == 0 && addr >= 32'ha0000 && addr < 32'hc0000)
      expected_ddr_addr[24:13] = {6'b111110, bank};
    expected_ddr_be = addr[2] ? {be,4'd0} : {4'd0,be};
    next_lane = 0; byte_count = 0; ddr_count = 0;
    active = 1; expect_vga = is_vga;
    @(negedge clk);
    cpu_we = 0;
  endtask
  task automatic write_one(input logic [31:0] addr, input logic [3:0] be,
                           input bit is_vga);
    int accepted, latency, first_lane, last_lane, expected_latency;
    start_write(addr,be,is_vga);
    accepted = cycle;
    while (dut.state != 1) @(negedge clk);
    latency = cycle - accepted;
    if (busy) $fatal(1, "busy not cleared at final byte");
    if (is_vga) begin
      first_lane = 3; last_lane = 3;
      if (be != 0) begin
        first_lane = 0; while (!be[first_lane]) first_lane++;
        last_lane = 3; while (!be[last_lane]) last_lane--;
      end
      expected_latency = 2 + last_lane - first_lane - ((be == 15) ? ENABLED : 0);
      if ($test$plusargs("require_saved") && be == 15) expected_latency = 4;
      if (byte_count != $countones(be) || ddr_count != 0 || latency != expected_latency)
        $fatal(1, "VGA completion mismatch case=%0d bytes=%0d latency=%0d expected=%0d",case_id,byte_count,latency,expected_latency);
    end else if (ddr_count != 1 || byte_count != 0 || latency != 1)
      $fatal(1, "RAM completion mismatch");
    $display("CASE %0d %0d %0d %0d %0d %0d",case_id,is_vga,be,latency,byte_count,ddr_count);
    active = 0; checked++;
  endtask
  task automatic reset_mid_read;
    while (dut.state != 1 || busy) @(negedge clk);
    case_id++;
    cpu_addr = 32'ha0380 >> 2;
    cpu_be = 4'b1111;
    cpu_rd = 1;
    expect_read = 1;
    resetting = 1;
    @(negedge clk);
    cpu_rd = 0;
    if (!vga_rd) $fatal(1, "VGA read did not start");
    reset = 1;
    while (!(dut.RESET_1 && !dut.RESET_2)) @(negedge clk);
    @(negedge clk);
    if (vga_we || vga_rd || dut.vga_wr || dut.vga_re || dut.vga_be != 0)
      $fatal(1, "VGA read survived effective reset");
    expect_read = 0;
    reset_quiet = 1;
    repeat (5) @(negedge clk);
    reset = 0;
    repeat (160) @(negedge clk);
    if (dut.state != 1 || busy || read_count == 0)
      $fatal(1, "reset did not quiesce VGA read");
    resetting = 0;
    reset_cases++;
    write_one(32'ha03c0,15,1);
  endtask
  initial begin
    boot();
    // Full/partial/zero strobes, aperture variants, bank passthrough, and
    // non-unit upstream burstcount (writes remain individual transactions).
    for (int m=4;m<8;m++) begin
      mode = 3'(m); repeat (2) @(negedge clk);
      for (int b=0;b<4;b++) begin
        bank = 6'(b*17);
        for (int be=0;be<16;be++) begin
          burst = 4'(1+(be%15));
          write_one((m<6 ? 32'ha0100 : (m==6 ? 32'hb0100 : 32'hb8100))+32'(be*4),4'(be),1);
          write_one(32'h2000+32'(be*4),4'(be),0);
        end
      end
    end
    // Linear-framebuffer path must continue routing to DDR, not byte VGA.
    mode = 5; fb = 1; repeat (2) @(negedge clk);
    for (int b=0;b<4;b++) begin
      bank=6'(b*17); write_one(32'ha0204,15,0);
    end
    fb = 0;
    // Hold command during backend backpressure; no premature VGA side effect.
    ddr_busy = 1; cpu_addr = 30'h28080; cpu_be=15; cpu_we=1;
    repeat (4) @(negedge clk);
    if (dut.state != 1 || vga_we) $fatal(1,"accepted while DDR busy");
    cpu_we=0; ddr_busy=0;
    write_one(32'ha0200,15,1);
    // Reset is coordinated, delayed, and NOT rollback. An already emitted
    // prefix may differ by one byte between profiles. Check every emitted byte
    // against its original owner, then require no post-reset ghost traffic.
    for (int prefix=0;prefix<=4;prefix++) begin
      resetting = 1;
      start_write(32'ha0300,15,1);
      while (byte_count < prefix) @(negedge clk);
      reset=1;
      // RESET_1 rising while RESET_2 is low identifies the edge on which
      // l2_cache will take its effective reset. Observe outputs immediately
      // after that edge, then keep checking throughout START and IDLE.
      while (!(dut.RESET_1 && !dut.RESET_2)) @(negedge clk);
      @(negedge clk);
      if (vga_we || vga_rd || dut.vga_wr || dut.vga_re || dut.vga_be != 0)
        $fatal(1, "VGA output survived effective reset case=%0d", case_id);
      reset_quiet = 1;
      repeat (5) @(negedge clk);
      reset=0;
      repeat (160) @(negedge clk);
      if (dut.state != 1 || busy || byte_count > 4) $fatal(1,"reset did not quiesce");
      active=0; resetting=0; reset_cases++;
      $display("RESET %0d %0d",prefix,byte_count);
      write_one(32'ha0340,15,1);
    end
    reset_mid_read();
    repeat (5) @(negedge clk);
    $display("VGA-FULL-STORE-SETUP-OK enabled=%0d cases=%0d resets=%0d",ENABLED,checked,reset_cases);
    $finish;
  end
endmodule
