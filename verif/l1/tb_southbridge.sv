// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_southbridge.sv — Phase D.2 gate: the ven_southbridge wrapper shell. Drives
// its three interfaces standalone and proves the bridge logic:
//   * PCI config via port-I/O (0xCF8/0xCFC) → host-bridge cfg → cfg_* outputs;
//   * MMIO slave → the VGA-aperture framebuffer (write/read-back);
//   * DMA: program the engine via the 0x00C0 control block → it bus-masters a device→mem
//     transfer on the dma_* master (a backing memory captures it).
// Prints SOUTHBRIDGE-GATE-OK / -FAIL. Run via verif/l1/run-southbridge-gate.sh.

module tb_southbridge;
  logic clk=0, rst_n=0; always #5 clk=~clk;

  logic        io_req, io_we; logic [15:0] io_addr; logic [31:0] io_wdata, io_rdata; logic io_ack;
  logic        mmio_req, mmio_we; logic [31:0] mmio_addr, mmio_wdata; logic [3:0] mmio_wstrb;
  logic [31:0] mmio_rdata; logic mmio_ack;
  logic        dma_req, dma_we; logic [31:0] dma_addr, dma_wdata; logic [3:0] dma_wstrb;
  logic [31:0] dma_rdata; logic dma_ack;
  logic        dev_rd, dev_wr; logic [31:0] dev_rdata, dev_wdata; logic dma_busy, dma_tc;
  logic [55:0] cfg_pam; logic [7:0] cfg_dramc, cfg_cc, cfg_tom_mb4, cfg_smram;

  ven_southbridge u_sb (
      .clk(clk), .rst_n(rst_n),
      .mmio_req(mmio_req), .mmio_we(mmio_we), .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
      .mmio_wstrb(mmio_wstrb), .mmio_rdata(mmio_rdata), .mmio_ack(mmio_ack),
      .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_wdata(io_wdata),
      .io_rdata(io_rdata), .io_ack(io_ack),
      .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
      .dma_wstrb(dma_wstrb), .dma_rdata(dma_rdata), .dma_ack(dma_ack),
      .dev_rd(dev_rd), .dev_rdata(dev_rdata), .dev_wr(dev_wr), .dev_wdata(dev_wdata),
      .dma_busy(dma_busy), .dma_tc(dma_tc),
      .cfg_pam(cfg_pam), .cfg_dramc(cfg_dramc), .cfg_cc(cfg_cc),
      .cfg_tom_mb4(cfg_tom_mb4), .cfg_smram(cfg_smram));

  // ---- backing memory on the DMA master (the system DRAM behind the northbridge) -
  logic [7:0] mem [0:(1<<16)-1];
  always_comb begin
    dma_ack = dma_req;
    dma_rdata = (dma_req && !dma_we) ? {mem[dma_addr[15:0]+3],mem[dma_addr[15:0]+2],
                                        mem[dma_addr[15:0]+1],mem[dma_addr[15:0]+0]} : 32'd0;
  end
  always_ff @(posedge clk) if (dma_req && dma_we)
    for (int b=0;b<4;b++) if (dma_wstrb[b]) mem[dma_addr[15:0]+b] <= dma_wdata[b*8 +: 8];

  // ---- the DMA device (a disk supplying a pattern on dev_rd) ------------------
  int devidx; logic [31:0] devpat [0:63];
  assign dev_rdata = devpat[devidx[5:0]];
  always_ff @(posedge clk) if (dev_rd) devidx <= devidx + 1;

  int errors=0;
  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got!==exp) begin $display("  FAIL %s: got %08x exp %08x", what, got, exp); errors++; end
    else $display("  ok   %s = %08x", what, got);
  endtask
  task automatic io_w(input [15:0] a, input [31:0] d);
    @(negedge clk); io_req<=1; io_we<=1; io_addr<=a; io_wdata<=d; @(negedge clk); io_req<=0; io_we<=0;
  endtask
  task automatic io_r(input [15:0] a, output [31:0] d);
    @(negedge clk); io_req<=1; io_we<=0; io_addr<=a; #1; d=io_rdata; @(negedge clk); io_req<=0;
  endtask
  task automatic mmio_w(input [31:0] a, input [31:0] d);
    @(negedge clk); mmio_req<=1; mmio_we<=1; mmio_addr<=a; mmio_wdata<=d; mmio_wstrb<=4'hF;
    @(negedge clk); mmio_req<=0; mmio_we<=0;
  endtask
  task automatic mmio_r(input [31:0] a, output [31:0] d);
    @(negedge clk); mmio_req<=1; mmio_we<=0; mmio_addr<=a; #1; d=mmio_rdata; @(negedge clk); mmio_req<=0;
  endtask

  logic [31:0] d;
  initial begin
    io_req=0; io_we=0; io_addr=0; io_wdata=0; mmio_req=0; mmio_we=0; mmio_addr=0; mmio_wdata=0; mmio_wstrb=0;
    devidx=0; for (int i=0;i<64;i++) devpat[i]=32'hDA7A_0000+i;
    for (int i=0;i<(1<<16);i++) mem[i]=8'h00;
    repeat(3) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    $display("[1] PCI config via port-I/O (0xCF8/0xCFC) → host-bridge CC register");
    io_w(16'h0CF8, 32'h8000_0050);            // CONFIG_ADDRESS: bus0 dev0 func0 reg dword 0x50
    io_w(16'h0CFC, 32'h0041_0000);            // CONFIG_DATA: byte 2 (0x52=CC) = 0x41
    @(posedge clk); #1;
    chk("cfg_cc reflects the config write", {24'd0, cfg_cc}, 32'h0000_0041);
    io_r(16'h0CFC, d); chk("config read-back (CC at byte 2)", d & 32'h00FF_0000, 32'h0041_0000);
    io_r(16'h0CF8, d); chk("CONFIG_ADDRESS read-back", d, 32'h8000_0050);

    $display("[2] MMIO framebuffer (VGA aperture) write/read-back");
    mmio_w(32'h000A_0000, 32'hCAFE_BABE);
    mmio_r(32'h000A_0000, d); chk("framebuffer read-back", d, 32'hCAFE_BABE);
    mmio_w(32'h000B_8000, 32'h1234_5678);
    mmio_r(32'h000B_8000, d); chk("framebuffer @B8000", d, 32'h1234_5678);

    $display("[3] DMA via the REAL 8237 registers: program channel 0 → device→mem");
    devidx = 0;
    io_w(16'h000C, 32'h00);                   // clear byte-pointer flip-flop
    io_w(16'h0000, 32'h00);                   // ch0 addr LSB = 0x00
    io_w(16'h0000, 32'h70);                   // ch0 addr MSB = 0x70  → 0x7000
    io_w(16'h0001, 32'h07);                   // ch0 count LSB = 7 (8257 N-1; transfer 8)
    io_w(16'h0001, 32'h00);                   // ch0 count MSB = 0
    io_w(16'h0087, 32'h00);                   // ch0 page = 0
    io_w(16'h000B, 32'h44);                   // ch0 mode: single, WRITE (device→mem)
    io_w(16'h000A, 32'h00);                   // single-mask: unmask ch0
    io_w(16'h0009, 32'h04);                   // request register: set request, ch0 → GO
    begin int g; g=0; forever begin @(posedge clk); #1; if (dma_tc) break;
      if (++g>2000) begin $display("  FAIL DMA never completed"); errors++; break; end end end
    for (int w=0; w<8; w++)
      chk($sformatf("DMA wrote mem[0x7000+%0d]", w),
          {mem[16'h7000+w*4+3],mem[16'h7000+w*4+2],mem[16'h7000+w*4+1],mem[16'h7000+w*4+0]},
          32'hDA7A_0000 + w);

    $display("[4] 4-channel arbiter: program ch0(→0x7000) + ch2(→0x8000), request both");
    devidx = 0;
    io_w(16'h000C, 32'h00);                               // clear FF
    io_w(16'h0000, 32'h00); io_w(16'h0000, 32'h70);       // ch0 addr 0x7000
    io_w(16'h0001, 32'h07); io_w(16'h0001, 32'h00);       // ch0 count 7
    io_w(16'h0087, 32'h00); io_w(16'h000B, 32'h44); io_w(16'h000A, 32'h00); // page/mode/unmask ch0
    io_w(16'h000C, 32'h00);                               // clear FF
    io_w(16'h0004, 32'h00); io_w(16'h0004, 32'h80);       // ch2 addr 0x8000 (ports 0x04/0x05)
    io_w(16'h0005, 32'h07); io_w(16'h0005, 32'h00);       // ch2 count 7
    io_w(16'h0081, 32'h00); io_w(16'h000B, 32'h46); io_w(16'h000A, 32'h02); // page(0x81)/mode/unmask ch2
    io_w(16'h0009, 32'h04);                               // request ch0 (higher priority → first)
    io_w(16'h0009, 32'h06);                               // request ch2
    begin int g; g=0; forever begin @(posedge clk); #1;
      if (!dma_busy && devidx>=16) break;
      if (++g>4000) begin $display("  FAIL 2-ch DMA stuck (devidx=%0d)", devidx); errors++; break; end end end
    for (int w=0; w<8; w++) chk($sformatf("ch0→mem[0x7000+%0d]", w),
        {mem[16'h7000+w*4+3],mem[16'h7000+w*4+2],mem[16'h7000+w*4+1],mem[16'h7000+w*4+0]}, 32'hDA7A_0000+w);
    for (int w=0; w<8; w++) chk($sformatf("ch2→mem[0x8000+%0d]", w),
        {mem[16'h8000+w*4+3],mem[16'h8000+w*4+2],mem[16'h8000+w*4+1],mem[16'h8000+w*4+0]}, 32'hDA7A_0008+w);

    if (errors==0) $display("SOUTHBRIDGE-GATE-OK (all checks pass)");
    else           $display("SOUTHBRIDGE-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #200000; $display("SOUTHBRIDGE-GATE-FAIL (timeout)"); $finish; end
endmodule
