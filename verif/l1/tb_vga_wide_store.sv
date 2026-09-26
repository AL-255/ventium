// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Compare the actual four VGA plane RAMs after legacy and wide cache writes.
module tb_vga_wide_store;
  logic clk = 0;
  always #5 clk = ~clk;
  initial begin #1000000; $fatal(1, "VGA wide-store watchdog"); end

  logic reset = 0, cpu_we = 0, fast_enable = 0;
  logic [29:0] cpu_addr = 0;
  logic [31:0] cpu_data = 0;
  logic [3:0] cpu_be = 0;
  wire cpu_busy, vga_rd, vga_we, vga_wide_we, vga_ready;
  wire [16:0] vga_addr;
  wire [7:0] vga_data, vga_read_data;
  wire [31:0] vga_wide_data;
  wire [2:0] vga_mode;
  wire [5:0] vga_wr_seg, vga_rd_seg;

  l2_cache #(.ADDRBITS(24)) cache (
    .CLK(clk), .RESET(reset), .DISABLE(1'b0),
    .l2_inv_pulse(1'b0), .l2_inv_addr(25'd0),
    .CPU_ADDR(cpu_addr), .CPU_DIN(cpu_data), .CPU_DOUT(),
    .CPU_DOUT_READY(), .CPU_BE(cpu_be), .CPU_BURSTCNT(4'd1),
    .CPU_BUSY(cpu_busy), .CPU_RD(1'b0), .CPU_WE(cpu_we),
    .DDRAM_ADDR(), .DDRAM_DIN(), .DDRAM_BE(), .DDRAM_BURSTCNT(),
    .DDRAM_RD(), .DDRAM_WE(), .DDRAM_DOUT(64'd0),
    .DDRAM_DOUT_READY(1'b0), .DDRAM_BUSY(1'b0),
    .VGA_ADDR(vga_addr), .VGA_DIN(vga_read_data), .VGA_DOUT(vga_data),
    .VGA_MODE(vga_mode), .VGA_RD(vga_rd), .VGA_WE(vga_we),
    .VGA_WIDE_READY(vga_ready && fast_enable),
    .VGA_WIDE_WE(vga_wide_we), .VGA_WIDE_DOUT(vga_wide_data),
    .VGA_WR_SEG(vga_wr_seg), .VGA_RD_SEG(vga_rd_seg),
    .VGA_FB_EN(1'b0), .uma_ram(1'b0)
  );
  vga video (
    .clk_sys(clk), .rst_n(~reset),
    .io_address(4'd0), .io_read(1'b0), .io_readdata(),
    .io_write(1'b0), .io_writedata(8'd0),
    .io_b_cs(1'b0), .io_c_cs(1'b0), .io_d_cs(1'b0),
    .mem_address(vga_addr), .mem_read(vga_rd),
    .mem_readdata(vga_read_data), .mem_write(vga_we),
    .mem_writedata(vga_data), .mem_write_wide(vga_wide_we),
    .mem_writedata_wide(vga_wide_data), .mem_wide_ready(vga_ready),
    .irq(), .clk_vga(clk), .clock_rate_vga(28'd25000000),
    .vga_ce(), .vga_f60(1'b1), .vga_memmode(vga_mode),
    .vga_blank_n(), .vga_off(), .vga_horiz_sync(), .vga_vert_sync(),
    .vga_r(), .vga_g(), .vga_b(), .vga_pal_d(), .vga_pal_a(), .vga_pal_we(),
    .vga_start_addr(), .vga_wr_seg(vga_wr_seg), .vga_rd_seg(vga_rd_seg),
    .vga_width(), .vga_stride(), .vga_height(), .vga_flags(),
    .vga_lores(1'b0), .vga_border(1'b0)
  );

  int cycle = 0, legacy_count = 0, wide_count = 0, checked = 0;
  int first_wide_cycle = -1, last_write_cycle = -1;
  logic [31:0] control [0:7];
  bit reset_quiet = 0;
  always @(posedge clk) begin
    cycle++;
    if (vga_rd) $fatal(1, "unexpected VGA read");
    if (vga_we && vga_wide_we) $fatal(1, "double VGA write");
    if (reset_quiet && (vga_we || vga_wide_we))
      $fatal(1, "VGA write after effective reset");
    if (vga_we) begin legacy_count++; last_write_cycle=cycle; end
    if (vga_wide_we) begin
      wide_count++;
      first_wide_cycle=cycle;
      last_write_cycle=cycle;
      if (vga_addr[1:0] != 0 || !vga_ready)
        $fatal(1, "unqualified or unaligned wide store");
    end
  end

  task automatic configure(input int variant, input logic [3:0] map_mask,
                            input logic [1:0] bank);
    @(negedge clk);
    video.general_enable_ram = 1;
    video.graph_system_memory = 2'd1;
    video.seq_access_chain4 = (variant != 5);
    video.seq_access_odd_even_disabled = (variant != 4);
    video.graph_write_mode = (variant == 1) ? 2'd1 : 2'd0;
    video.graph_write_rotate = (variant == 2) ? 3'd1 : 3'd0;
    video.graph_write_function = 2'd0;
    video.graph_write_mask = (variant == 3) ? 8'h0f : 8'hff;
    video.graph_write_enable_map = 4'd0;
    video.seq_map_write_enable = map_mask;
    video.seg_wr = {4'd0, bank};
    repeat (3) @(negedge clk);
  endtask

  task automatic init_planes;
    for (int i=0; i<8; i++) begin
      video.plane_ram_0.mem[16'h100+i] = 8'(8'h10+i);
      video.plane_ram_1.mem[16'h100+i] = 8'(8'h30+i);
      video.plane_ram_2.mem[16'h100+i] = 8'(8'h50+i);
      video.plane_ram_3.mem[16'h100+i] = 8'(8'h70+i);
    end
  endtask
  function automatic logic [31:0] plane_word(input int addr);
    return {video.plane_ram_3.mem[addr], video.plane_ram_2.mem[addr],
            video.plane_ram_1.mem[addr], video.plane_ram_0.mem[addr]};
  endfunction

  task automatic run_store(input bit fast, input logic [3:0] be,
                           input bit change_mode, output int latency,
                           output int old_writes, output int wide_writes);
    int started, old0, wide0;
    while (cache.state != 1 || cpu_busy) @(negedge clk);
    fast_enable = fast;
    cpu_addr = 32'ha0100 >> 2;
    cpu_data = 32'hb47ac931;
    cpu_be = be;
    cpu_we = 1;
    old0=legacy_count; wide0=wide_count;
    @(negedge clk);
    cpu_we = 0;
    started = cycle;
    if (change_mode) video.graph_write_mode = 2'd1;
    while (cache.state != 1) @(negedge clk);
    latency = cycle - started;
    old_writes = legacy_count-old0;
    wide_writes = wide_count-wide0;
    if (cpu_busy) $fatal(1, "cache busy after store completion");
    repeat (2) @(negedge clk);
  endtask

  task automatic check_case(input int variant, input logic [3:0] map_mask,
                            input logic [1:0] bank, input logic [3:0] be,
                            input bit change_mode);
    int base_latency, fast_latency, base_old, base_wide, fast_old, fast_wide;
    configure(variant,map_mask,bank);
    init_planes();
    run_store(0,be,change_mode,base_latency,base_old,base_wide);
    for (int i=0; i<8; i++) control[i] = plane_word(16'h100+i);
    configure(variant,map_mask,bank);
    init_planes();
    run_store(1,be,change_mode,fast_latency,fast_old,fast_wide);
    for (int i=0; i<8; i++)
      if (plane_word(16'h100+i) !== control[i])
        $fatal(1,"plane mismatch variant=%0d bank=%0d be=%h addr=%h old=%h new=%h",
               variant,bank,be,16'h100+i,control[i],plane_word(16'h100+i));
    if (base_wide != 0 || base_old != $countones(be))
      $fatal(1,"bad legacy write count");
    if (variant == 0 && be == 15 && !change_mode) begin
      if (fast_wide != 1 || fast_old != 0 || !(fast_latency < base_latency))
        $fatal(1,"wide mode did not save clocks");
    end else if (fast_wide != 0 || fast_old != base_old)
      $fatal(1,"fallback changed legacy write count");
    checked++;
    $display("CASE variant=%0d map=%h bank=%0d be=%h change=%0d base=%0d fast=%0d bytes=%0d wide=%0d",
             variant,map_mask,bank,be,change_mode,base_latency,fast_latency,fast_old,fast_wide);
  endtask

  initial begin
    reset = 1;
    repeat (5) @(negedge clk);
    reset = 0;
    repeat (160) @(negedge clk);
    if (cache.state != 1 || cpu_busy) $fatal(1,"cache did not initialize");
    for (int bank=0; bank<4; bank++) begin
      check_case(0,4'hf,2'(bank),4'hf,0);
      check_case(0,4'h5,2'(bank),4'hf,0);
      check_case(0,4'hf,2'(bank),4'b0101,0);
    end
    for (int variant=1; variant<=5; variant++)
      check_case(variant,4'hf,2'd2,4'hf,0);
    check_case(0,4'hf,2'd1,4'hf,1);
    // Interrupt an armed wide transaction. The effective reset edge must
    // silence both ports throughout tag initialization.
    configure(0,4'hf,2'd0);
    init_planes();
    while (cache.state != 1 || cpu_busy) @(negedge clk);
    fast_enable=1; cpu_addr=32'ha0100 >> 2; cpu_data=32'hbadcfe12;
    cpu_be=15; cpu_we=1;
    @(negedge clk);
    cpu_we=0; reset=1;
    while (!(cache.RESET_1 && !cache.RESET_2)) @(negedge clk);
    @(negedge clk);
    if (vga_we || vga_wide_we) $fatal(1,"write survived reset edge");
    reset_quiet=1;
    repeat (5) @(negedge clk);
    reset=0;
    repeat (160) @(negedge clk);
    if (cache.state != 1 || cpu_busy) $fatal(1,"reset did not quiesce cache");
    $display("VGA-WIDE-STORE-OK cases=%0d",checked);
    $finish;
  end
endmodule
