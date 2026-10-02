// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Real bridge -> real L2 byte sequencer -> real VGA plane RAM/latches.
// All setup/checking uses device I/O and AXI memory transactions, never force
// or hierarchical RAM initialization. This is a storage test, not scanout.
module tb_axivgalanes_planar;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin #2000000; $fatal(1, "AXIVGALANES-PLANAR watchdog"); end

  logic [3:0] awid = 1, bid, arid = 6, rid;
  logic [39:0] awaddr = 0, araddr = 0;
  logic [7:0] awlen = 0, arlen = 0;
  logic [2:0] awsize = 2, arsize = 0;
  logic [1:0] awburst = 1, arburst = 1, bresp, rresp;
  logic awvalid = 0, awready, wvalid = 0, wready, bvalid;
  logic arvalid = 0, arready, rvalid, rlast;
  logic [31:0] wdata = 0, rdata;
  logic [3:0] wstrb = 0;
  wire [29:0] avaddr;
  wire [31:0] avwdata, avrdata;
  wire [3:0] avbe, avcount;
  wire avwrite, avread, avbusy, avvalid;
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
  wire [7:0] vga_to_cpu, vga_from_cpu;
  wire vga_rd, vga_we;
  wire [2:0] vga_mode;
  wire [5:0] vga_wr_seg, vga_rd_seg;
  wire [24:0] ddr_addr;
  wire [63:0] ddr_data;
  wire [7:0] ddr_be, ddr_count;
  wire ddr_rd, ddr_we;
`ifdef VEN_VGA_WIDE_STORE
  wire vga_wide_ready, vga_wide_we;
  wire [31:0] vga_wide_data;
`endif
  l2_cache #(.ADDRBITS(24)) cache (
    .CLK(clk), .RESET(!rst_n), .DISABLE(1'b1),
    .l2_inv_pulse(1'b0), .l2_inv_addr(25'd0),
    .CPU_ADDR(avaddr), .CPU_DIN(avwdata), .CPU_DOUT(avrdata),
    .CPU_DOUT_READY(avvalid), .CPU_BE(avbe), .CPU_BURSTCNT(avcount),
    .CPU_BUSY(avbusy), .CPU_RD(avread), .CPU_WE(avwrite),
    .DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_data), .DDRAM_DOUT(64'd0),
    .DDRAM_DOUT_READY(1'b0), .DDRAM_BE(ddr_be), .DDRAM_BURSTCNT(ddr_count),
    .DDRAM_BUSY(1'b0), .DDRAM_RD(ddr_rd), .DDRAM_WE(ddr_we),
    .VGA_ADDR(vga_addr), .VGA_DIN(vga_to_cpu), .VGA_DOUT(vga_from_cpu),
    .VGA_MODE(vga_mode), .VGA_RD(vga_rd), .VGA_WE(vga_we),
`ifdef VEN_VGA_WIDE_STORE
    .VGA_WIDE_READY(vga_wide_ready), .VGA_WIDE_WE(vga_wide_we),
    .VGA_WIDE_DOUT(vga_wide_data),
`endif
    .VGA_WR_SEG(vga_wr_seg), .VGA_RD_SEG(vga_rd_seg),
    .VGA_FB_EN(1'b0), .uma_ram(1'b0)
  );

  logic [3:0] io_addr = 0;
  logic io_rd = 0, io_we = 0;
  logic [7:0] io_data = 0;
  wire [7:0] io_result;
  vga device (
    .clk_sys(clk), .rst_n, .io_address(io_addr), .io_read(io_rd),
    .io_readdata(io_result), .io_write(io_we), .io_writedata(io_data),
    .io_b_cs(1'b0), .io_c_cs(1'b1), .io_d_cs(1'b0),
    .mem_address(vga_addr), .mem_read(vga_rd), .mem_readdata(vga_to_cpu),
    .mem_write(vga_we), .mem_writedata(vga_from_cpu),
`ifdef VEN_VGA_WIDE_STORE
    .mem_write_wide(vga_wide_we), .mem_writedata_wide(vga_wide_data),
    .mem_wide_ready(vga_wide_ready),
`endif
    .irq(), .clk_vga(clk), .clock_rate_vga(28'd100000000),
    .vga_ce(), .vga_f60(1'b0), .vga_memmode(vga_mode),
    .vga_blank_n(), .vga_off(), .vga_horiz_sync(), .vga_vert_sync(),
    .vga_r(), .vga_g(), .vga_b(), .vga_pal_d(), .vga_pal_a(), .vga_pal_we(),
    .vga_start_addr(), .vga_wr_seg, .vga_rd_seg, .vga_width(),
    .vga_stride(), .vga_height(), .vga_flags(),
    .vga_lores(1'b0), .vga_border(1'b0)
  );

  localparam logic [39:0] SOURCE = 40'h00000a0200;
  localparam logic [39:0] PRIME = 40'h00000a0180;
  localparam logic [39:0] DEST = 40'h00000a0300;
  localparam logic [39:0] COPY = 40'h00000a0310;
  localparam logic [39:0] SCRATCH = 40'h00000a1000;
  int b_seen = 0, r_seen = 0, cases = 0, plane_checks = 0;
  int data_checks = 0, data_failures = 0, plane_failures = 0;
  int previous_mask = 0, source_lane = 0, source_size = 0;
  logic [31:0] last_rdata = 0;
  always @(posedge clk) if (rst_n) begin
    if (bvalid) begin
      if (bid != awid || bresp != 0) $fatal(1, "bad B response metadata");
      b_seen++;
    end
    if (rvalid) begin
      if (rid != arid || rresp != 0 || !rlast) $fatal(1, "bad R response metadata");
      last_rdata = rdata;
      r_seen++;
    end
    if (ddr_rd || ddr_we) $fatal(1, "VGA access unexpectedly routed to DDR");
`ifdef VEN_VGA_WIDE_STORE
    if (vga_wide_ready || vga_wide_we)
      $fatal(1, "planar/latch mode admitted an ineligible wide store");
`endif
  end

  // All sixteen source high nibbles are distinct across plane/address.
  // PRIME high nibbles differ from every source byte in the same plane.
  function automatic logic [7:0] source_byte(input int plane, input int lane);
    return 8'(((plane + 1) << 4) + (lane << 6) + plane);
  endfunction
  function automatic logic [7:0] prime_byte(input int plane);
    return 8'(8'h8d + (plane << 4));
  endfunction

  task automatic idle;
    bit ready;
    ready = 0;
    for (int guard = 0; guard < 2048 && !ready; guard++) begin
      @(negedge clk);
      ready = arready && !avbusy && !bvalid;
    end
    if (!ready) $fatal(1, "AXI/backend idle timeout");
  endtask

  task automatic write_word(input logic [39:0] address,
                            input logic [31:0] value, input logic [3:0] mask);
    bit aw_done, w_done;
    int before_b;
    idle();
    if (address[1:0] != 0) $fatal(1, "write address must be dword aligned");
    awaddr = address; wdata = value; wstrb = mask;
    awvalid = 1; wvalid = 1; aw_done = 0; w_done = 0; before_b = b_seen;
    for (int guard = 0; guard < 2048 && !(aw_done && w_done); guard++) begin
      @(posedge clk);
      if (awvalid && awready) aw_done = 1;
      if (wvalid && wready) w_done = 1;
      @(negedge clk);
      if (aw_done) awvalid = 0;
      if (w_done) wvalid = 0;
    end
    if (!(aw_done && w_done)) $fatal(1, "AW/W timeout");
    for (int guard = 0; guard < 2048 && b_seen == before_b; guard++) @(negedge clk);
    if (b_seen != before_b + 1) $fatal(1, "missing/duplicate B response");
    // B can precede completion of the backend VGA byte sequencer.
    idle();
  endtask

  task automatic read_piece(input logic [39:0] address, input logic [2:0] size,
                            output logic [31:0] value);
    bit accepted;
    int before_r;
    idle();
    if (size > 2 || (size == 1 && address[0]) || (size == 2 && address[1:0] != 0))
      $fatal(1, "only legal naturally aligned single-beat pieces are tested");
    araddr = address; arsize = size; arvalid = 1;
    accepted = 0; before_r = r_seen;
    for (int guard = 0; guard < 2048 && !accepted; guard++) begin
      @(posedge clk); accepted = arready;
    end
    if (!accepted) $fatal(1, "AR timeout");
    @(negedge clk); arvalid = 0;
    for (int guard = 0; guard < 2048 && r_seen == before_r; guard++) @(negedge clk);
    if (r_seen != before_r + 1) $fatal(1, "missing/duplicate R response");
    value = last_rdata;
    // Real RAM reads update in one edge; architectural latches in the next.
    // Completing the actual L2/AXI response and idle transition includes both.
    idle();
  endtask

  task automatic io_write(input logic [3:0] address, input logic [7:0] value);
    idle();
    io_addr = address; io_data = value; io_we = 1;
    @(negedge clk); io_we = 0;
    // Let both VGA registers and L2's registered aperture mode settle.
    repeat (2) @(negedge clk);
  endtask
  task automatic seq_write(input logic [2:0] index, input logic [7:0] value);
    io_write(4'h4, {5'd0, index}); io_write(4'h5, value);
  endtask
  task automatic graph_write(input logic [3:0] index, input logic [7:0] value);
    io_write(4'he, {4'd0, index}); io_write(4'hf, value);
  endtask

  task automatic check_data(input logic [31:0] value, input int plane,
                            input int first, input int bytes);
    for (int lane = first; lane < first + bytes; lane++) begin
      data_checks++;
      if (value[lane*8 +: 8] !== source_byte(plane, lane)) begin
        data_failures++;
        if (data_failures <= 12)
          $display("PLANAR-DATA-FAIL plane=%0d lane=%0d got=%h want=%h",
                   plane, lane, value[lane*8 +: 8], source_byte(plane, lane));
      end
    end
  endtask

  task automatic check_plane(input logic [7:0] got, input logic [7:0] expected,
                             input int plane, input bit copying);
    plane_checks++;
    if (got !== expected) begin
      plane_failures++;
      if (plane_failures <= 12)
        $display("PLANAR-LATCH-FAIL case=%0d previous_wstrb=%h source_lane=%0d size=%0d plane=%0d copy=%0b got=%h want=%h",
                 cases, previous_mask, source_lane, source_size, plane, copying, got, expected);
    end
  endtask

  task automatic one_case(input int mask, input int lane, input int size);
    logic [31:0] value;
    int owner;
    cases++; previous_mask = mask; source_lane = lane; source_size = size;
    owner = lane + (1 << size) - 1;
    graph_write(4'h5, 8'h00); graph_write(4'h8, 8'hff); graph_write(4'h4, 8'h00);
    // Prime is independent of the tested WSTRB; even the old adapter receives
    // a legitimate F preceding write and reads all four equal prime bytes.
    write_word(SCRATCH, 32'h10203040, 4'hf);
    read_piece(PRIME, 3'd2, value);
    if (value !== {4{prime_byte(0)}}) $fatal(1, "prime RAM initialization/read failed");
    // No memory read may intervene between this source read and both writes.
    write_word(SCRATCH, 32'h87654321, 4'(mask));
    read_piece(SOURCE + 40'(lane), 3'(size), value);
    check_data(value, 0, lane, 1 << size);
    graph_write(4'h8, 8'h0f);
    write_word(DEST, 32'h0000000b, 4'h1);
    // Mode 1 ignores host data/mask and copies all eight latch bits.
    graph_write(4'h5, 8'h01);
    write_word(COPY, 32'h0000007e, 4'h1);
    graph_write(4'h5, 8'h00); graph_write(4'h8, 8'hff);
    for (int plane = 0; plane < 4; plane++) begin
      graph_write(4'h4, 8'(plane));
      read_piece(DEST, 3'd0, value);
      check_plane(value[7:0], (source_byte(plane, owner) & 8'hf0) | 8'h0b, plane, 0);
      read_piece(COPY, 3'd0, value);
      check_plane(value[7:0], source_byte(plane, owner), plane, 1);
    end
  endtask

  initial begin
    logic [31:0] value, word_value;
    repeat (4) @(negedge clk); rst_n = 1;
    // Actual L2 reset walks 128 tag entries; no request is offered during it.
    repeat (200) @(negedge clk);
    io_write(4'h2, 8'h03); // misc: enable RAM, color I/O, clock select0
    seq_write(3'd0, 8'h03); seq_write(3'd1, 8'h21); // reset released, screen off
    seq_write(3'd3, 8'h00); seq_write(3'd4, 8'h06); // planar, odd/even off
    graph_write(4'h0, 8'h00); graph_write(4'h1, 8'h00);
    graph_write(4'h2, 8'h00); graph_write(4'h3, 8'h00);
    graph_write(4'h4, 8'h00); graph_write(4'h5, 8'h00);
    graph_write(4'h6, 8'h05); graph_write(4'h7, 8'h0f); graph_write(4'h8, 8'hff);
    for (int plane = 0; plane < 4; plane++) begin
      seq_write(3'd2, 8'(1 << plane));
      for (int lane = 0; lane < 4; lane++) word_value[lane*8 +: 8] = source_byte(plane, lane);
      write_word(SOURCE, word_value, 4'hf);
      write_word(PRIME, {4{prime_byte(plane)}}, 4'hf);
      write_word(DEST, 32'hefcdab89, 4'hf);
      write_word(COPY, 32'h76543210, 4'hf);
    end
    seq_write(3'd2, 8'h0f);
    for (int plane = 0; plane < 4; plane++) begin
      graph_write(4'h4, 8'(plane));
      read_piece(SOURCE, 3'd2, value);
      check_data(value, plane, 0, 4);
    end
    for (int mask = 0; mask < 16; mask++) begin
      for (int lane = 0; lane < 4; lane++) one_case(mask, lane, 0);
      one_case(mask, 0, 1); one_case(mask, 2, 1); one_case(mask, 0, 2);
    end
    if (cases != 112 || plane_checks != 896 || data_checks != 208)
      $fatal(1, "incomplete PLANAR corpus");
    $display("AXIVGALANES-PLANAR-SUMMARY cases=%0d plane_checks=%0d data_checks=%0d plane_failures=%0d data_failures=%0d",
             cases, plane_checks, data_checks, plane_failures, data_failures);
    if (plane_failures || data_failures) $fatal(1, "AXIVGALANES-PLANAR-GATE-FAIL");
    $display("AXIVGALANES-PLANAR-GATE-OK");
    $finish;
  end
endmodule
