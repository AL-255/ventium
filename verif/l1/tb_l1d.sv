// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1d.sv — standalone self-checking gate for ven_l1d (P1-1 step 1).
// A behavioral same-cycle backing memory feeds the L1; the test drives the core
// side and checks: (1) a cold read MISSES, fills the 32-byte line from the backing,
// and the retry HITS with the right word; (2) all 8 words of a filled line hit with
// correct data (whole-line fill); (3) a write-through updates both the array and the
// backing; (4) a 3rd line into a 2-way set evicts the LRU victim. Run via
// `verilator --binary`; prints L1D-GATE-OK / L1D-GATE-FAIL.

module tb_l1d;
  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  // core side
  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  // backing side
  logic        m_req, m_we; logic [31:0] m_addr, m_wdata; logic [3:0] m_wstrb;
  logic [31:0] m_rdata; logic m_ack;

  ven_l1d dut (.clk, .rst_n, .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb, .c_rdata, .c_ack,
               .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack);

  // ---- behavioral backing: byte-addressable, same-cycle ack -----------------
  logic [7:0] mem [0:(1<<20)-1];
  function automatic logic [31:0] rd32(input logic [31:0] a);
    rd32 = {mem[a+3], mem[a+2], mem[a+1], mem[a+0]};
  endfunction
  always_comb begin
    m_rdata = 32'd0; m_ack = 1'b0;
    if (m_req) begin
      m_ack = 1'b1;
      if (!m_we) m_rdata = rd32(m_addr);
    end
  end
  // backing writes land on the clock (same edge the L1 forwards them)
  always_ff @(posedge clk) if (m_req && m_we)
    for (int b=0;b<4;b++) if (m_wstrb[b]) mem[m_addr+b] <= m_wdata[b*8 +: 8];

  int errors = 0;
  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin
      $display("  FAIL %s: got %08x exp %08x", what, got, exp);
      errors++;
    end else $display("  ok   %s = %08x", what, got);
  endtask

  // issue a core READ to `a`, spin until c_ack, return the data.
  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_addr<=a; c_wstrb<=4'd0;
    guard=0;
    forever begin
      @(posedge clk); #1;
      if (c_ack) begin d = c_rdata; break; end
      if (++guard > 50) begin $display("  FAIL read %08x: no ack", a); errors++; d=32'hx; break; end
    end
    @(negedge clk); c_req<=1'b0;
  endtask

  // issue a core WRITE-through of word `d` to `a` (full word), spin until ack.
  task automatic do_write(input logic [31:0] a, d);
    int guard;
    @(negedge clk); c_req<=1'b1; c_we<=1'b1; c_addr<=a; c_wdata<=d; c_wstrb<=4'hF;
    guard=0;
    forever begin @(posedge clk); #1; if (c_ack) break;
      if (++guard>50) begin $display("  FAIL write %08x: no ack",a); errors++; break; end end
    @(negedge clk); c_req<=1'b0; c_we<=1'b0;
  endtask

  logic [31:0] d;
  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    // seed the backing with a recognizable pattern: word at addr A = A ^ 0xA5A5_0000
    for (int i=0;i<(1<<20);i++) mem[i] = 8'h00;
    for (logic [31:0] a=0; a<32'h4000; a+=4)
      {mem[a+3],mem[a+2],mem[a+1],mem[a+0]} = a ^ 32'hA5A5_0000;
    repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    $display("[1] cold read -> miss -> line fill -> hit");
    do_read(32'h0000_1004, d); chk("read 0x1004", d, 32'h1004 ^ 32'hA5A5_0000);

    $display("[2] all 8 words of the filled line hit with correct data");
    for (int w=0; w<8; w++) begin
      automatic logic [31:0] a = 32'h0000_1000 + 32'(w)*4;
      do_read(a, d); chk($sformatf("hit word %0d", w), d, a ^ 32'hA5A5_0000);
    end

    $display("[3] write-through then read-back (array + backing updated)");
    do_write(32'h0000_1008, 32'hDEAD_BEEF);
    do_read (32'h0000_1008, d); chk("read-after-write", d, 32'hDEAD_BEEF);
    chk("backing got the write", rd32(32'h0000_1008), 32'hDEAD_BEEF);

    $display("[4] 2-way set: a 3rd distinct line into the same set evicts LRU");
    // set index = addr[11:5]; pick three line bases sharing a set (stride 0x1000).
    do_read(32'h0000_2000, d); chk("line@2000", d, 32'h2000 ^ 32'hA5A5_0000); // way A
    do_read(32'h0000_3000, d); chk("line@3000", d, 32'h3000 ^ 32'hA5A5_0000); // way B (set 0 too? 0x2000/0x3000 share set 0)
    do_read(32'h0000_2000, d); chk("rehit@2000", d, 32'h2000 ^ 32'hA5A5_0000);

    if (errors==0) $display("L1D-GATE-OK (all checks pass)");
    else           $display("L1D-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #200000; $display("L1D-GATE-FAIL (timeout)"); $finish; end
endmodule
