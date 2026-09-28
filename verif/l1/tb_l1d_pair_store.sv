// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Focused banked-L1 dual-store admission check. The AXI queue's two-slot
// ordering and response ownership are checked by tb_axi_wbuf separately.
module tb_l1d_pair_store;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic c_req = 1'b0, c_we = 1'b0, c_pair_req = 1'b0;
  logic [31:0] c_addr = '0, c_wdata = '0, c_pair_addr = '0, c_pair_wdata = '0;
  logic [3:0] c_wstrb = '0, c_pair_wstrb = '0;
  logic [31:0] c_rdata;
  logic c_ack, c_pair_ready, c_pair_ack;
  logic snoop_inv_valid = 1'b0;
  logic [31:0] snoop_inv_addr = '0;
  logic m_req, m_we, m_pair_req, m_rd_narrow, m_ack, m_pair_ready, m_pair_ack;
  logic [31:0] m_addr, m_wdata, m_pair_addr, m_pair_wdata, m_rdata;
  logic [3:0] m_wstrb, m_pair_wstrb;
  logic [1:0] m_rd_size;
  logic block_pair = 1'b0;
  logic block_credit = 1'b0;
  assign m_pair_ready = !block_credit;
  logic [31:0] mem [0:63];
  int errors = 0, writes = 0;

  ven_l1d #(.L1_SETS(64)) dut (
      .clk, .rst_n, .flush_all(1'b0), .golden(1'b0), .cacheable(1'b1),
      .snoop_inv_valid, .snoop_inv_addr,
      .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb, .c_rdata, .c_ack,
      .c_pair_req, .c_pair_addr, .c_pair_wdata, .c_pair_wstrb,
      .c_pair_ready, .c_pair_ack, .dbg_serve(),
      .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack,
      .m_pair_req, .m_pair_addr, .m_pair_wdata, .m_pair_wstrb,
      .m_pair_ready, .m_pair_ack,
      .m_rd_narrow, .m_rd_size);

  always_comb begin
    m_rdata = mem[m_addr[7:2]];
    m_ack = m_req && (!m_we || !block_pair);
    m_pair_ack = m_req && m_we && m_pair_req && !block_pair;
  end
  always_ff @(posedge clk) begin
    if (rst_n && m_req && m_we && m_ack) begin
      for (int b = 0; b < 4; b++)
        if (m_wstrb[b]) mem[m_addr[7:2]][8*b +: 8] <= m_wdata[8*b +: 8];
      writes <= writes + 1;
    end
    if (rst_n && m_pair_req && m_pair_ack) begin
      for (int b = 0; b < 4; b++)
        if (m_pair_wstrb[b]) mem[m_pair_addr[7:2]][8*b +: 8] <= m_pair_wdata[8*b +: 8];
      writes <= writes + 2;
    end
  end

  task automatic fail(input string why);
    $display("  FAIL %s", why);
    errors++;
  endtask
  task automatic read_word(input logic [31:0] addr, expected);
    int guard;
    @(negedge clk);
    c_req <= 1'b1; c_we <= 1'b0; c_addr <= addr;
    guard = 0;
    while (!c_ack) begin
      @(posedge clk); #1;
      if (++guard > 40) begin fail("read timed out"); break; end
    end
    if (c_ack && c_rdata !== expected)
      fail($sformatf("read %08x got %08x expected %08x", addr, c_rdata, expected));
    @(negedge clk); c_req <= 1'b0;
  endtask

  initial begin
    for (int i = 0; i < 64; i++) mem[i] = 32'hbeef_0000 + 32'(i);
    repeat (5) @(negedge clk);
    rst_n <= 1'b1;
    read_word(32'h40, mem[16]);
    read_word(32'h44, mem[17]);

    $display("[pair] two resident same-line, distinct-bank stores admit together");
    @(negedge clk);
    c_req <= 1'b1; c_we <= 1'b1;
    c_addr <= 32'h40; c_wdata <= 32'h1111_1111; c_wstrb <= 4'hf;
    c_pair_req <= 1'b1;
    c_pair_addr <= 32'h44; c_pair_wdata <= 32'h2222_2222; c_pair_wstrb <= 4'hf;
    #1;
    if (!c_pair_ready || !c_ack || !c_pair_ack || !m_pair_req || !m_pair_ack)
      fail("resident distinct-bank pair was not admitted atomically");
    @(posedge clk);
    @(negedge clk); c_req <= 1'b0; c_we <= 1'b0; c_pair_req <= 1'b0;
    if (writes != 2 || mem[16] != 32'h1111_1111 || mem[17] != 32'h2222_2222)
      fail("pair did not produce two backing writes");
    read_word(32'h40, 32'h1111_1111);
    read_word(32'h44, 32'h2222_2222);

    $display("[pair] withdrawn backpressured request leaves both banks unchanged");
    @(negedge clk);
    block_pair <= 1'b1;
    c_req <= 1'b1; c_we <= 1'b1;
    c_addr <= 32'h50; c_wdata <= 32'h9999_9999; c_wstrb <= 4'hf;
    c_pair_req <= 1'b1;
    c_pair_addr <= 32'h54; c_pair_wdata <= 32'haaaa_aaaa; c_pair_wstrb <= 4'hf;
    repeat (3) @(posedge clk);
    if (!c_pair_ready || c_ack || c_pair_ack || writes != 2)
      fail("withdrawn pair changed acceptance state before backing was ready");
    @(negedge clk);
    c_req <= 1'b0; c_we <= 1'b0; c_pair_req <= 1'b0; block_pair <= 1'b0;
    read_word(32'h50, 32'hbeef_0014);
    read_word(32'h54, 32'hbeef_0015);
    if (mem[20] != 32'hbeef_0014 || mem[21] != 32'hbeef_0015 || writes != 2)
      fail("withdrawn pair changed backing state");

    $display("[pair] backpressure holds both cache and backing stores");
    @(negedge clk);
    block_pair <= 1'b1;
    c_req <= 1'b1; c_we <= 1'b1;
    c_addr <= 32'h48; c_wdata <= 32'h3333_3333; c_wstrb <= 4'hf;
    c_pair_req <= 1'b1;
    c_pair_addr <= 32'h4c; c_pair_wdata <= 32'h4444_4444; c_pair_wstrb <= 4'hf;
    repeat (3) @(posedge clk);
    if (!c_pair_ready || c_ack || c_pair_ack || writes != 2)
      fail("backpressured pair had an early acknowledgement or write");
    @(negedge clk); block_pair <= 1'b0;
    #1;
    if (!c_ack || !c_pair_ack) fail("pair did not resume together");
    @(posedge clk);
    @(negedge clk); c_req <= 1'b0; c_we <= 1'b0; c_pair_req <= 1'b0;
    if (writes != 4 || mem[18] != 32'h3333_3333 || mem[19] != 32'h4444_4444)
      fail("resumed pair did not write both words exactly once");
    read_word(32'h48, 32'h3333_3333);
    read_word(32'h4c, 32'h4444_4444);

    $display("[pair] snoop rejects both stores on its invalidation edge");
    @(negedge clk);
    c_req <= 1'b1; c_we <= 1'b1;
    c_addr <= 32'h50; c_wdata <= 32'h7777_7777; c_wstrb <= 4'hf;
    c_pair_req <= 1'b1;
    c_pair_addr <= 32'h54; c_pair_wdata <= 32'h8888_8888; c_pair_wstrb <= 4'hf;
    snoop_inv_valid <= 1'b1; snoop_inv_addr <= 32'h50;
    #1;
    if (c_pair_ready || c_ack || c_pair_ack || m_req || m_pair_req)
      fail("snoop edge admitted a pair that must be canceled");
    @(posedge clk);
    @(negedge clk);
    c_req <= 1'b0; c_we <= 1'b0; c_pair_req <= 1'b0;
    snoop_inv_valid <= 1'b0;
    if (writes != 4 || mem[20] != 32'hbeef_0014 || mem[21] != 32'hbeef_0015)
      fail("snoop-canceled pair changed backing memory");
    // Refill the snooped line before the fallback test below.
    read_word(32'h40, 32'h1111_1111);
    begin
      int guard;
      guard = 0;
      while (dut.st != 2'd0) begin
        @(posedge clk); #1;
        if (++guard > 20) begin fail("post-snoop fill did not drain"); break; end
      end
    end

    $display("[pair] same-bank/different-line V rejects U too, then U retries solo");
    @(negedge clk);
    c_req <= 1'b1; c_we <= 1'b1;
    c_addr <= 32'h40; c_wdata <= 32'h5555_5555; c_wstrb <= 4'hf;
    c_pair_req <= 1'b1;
    c_pair_addr <= 32'h60; c_pair_wdata <= 32'h6666_6666; c_pair_wstrb <= 4'hf;
    #1;
    if (c_pair_ready || c_ack || c_pair_ack || m_req || m_pair_req)
      fail("invalid pair allowed older U to escape alone");
    @(posedge clk);
    @(negedge clk); c_pair_req <= 1'b0;
    #1;
    if (!c_ack || !m_req || m_pair_req)
      fail($sformatf("U did not fall back to solo store: c_ack=%b m_ack=%b m_req=%b m_pair_req=%b c_pair_req=%b block=%b st=%0d stream=%b",
                     c_ack, m_ack, m_req, m_pair_req, c_pair_req, block_pair,
                     dut.st, dut.stream_path));
    @(posedge clk);
    @(negedge clk); c_req <= 1'b0; c_we <= 1'b0;
    if (writes != 5 || mem[16] != 32'h5555_5555 || mem[24] != 32'hbeef_0018)
      fail("fallback store changed the wrong backing word");

    $display("[pair] absent backing credit lets producer select a solo U store");
    @(negedge clk);
    block_credit <= 1'b1;
    c_req <= 1'b1; c_we <= 1'b1; c_pair_req <= 1'b0;
    c_addr <= 32'h44; c_wdata <= 32'h9999_9999; c_wstrb <= 4'hf;
    c_pair_addr <= 32'h48; c_pair_wstrb <= 4'hf;
    #1;
    if (c_pair_ready || !c_ack || !m_req || m_pair_req)
      fail("one-slot backing pressure stalled an otherwise available U store");
    @(posedge clk);
    @(negedge clk);
    c_req <= 1'b0; c_we <= 1'b0; block_credit <= 1'b0;
    if (writes != 6 || mem[17] != 32'h9999_9999 || mem[18] != 32'h3333_3333)
      fail("credit fallback changed younger data or omitted older write");

    if (errors == 0) $display("L1D-PAIR-STORE-GATE-OK");
    else             $display("L1D-PAIR-STORE-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "L1D pair-store test timed out");
  end
endmodule
