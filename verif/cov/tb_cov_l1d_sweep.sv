// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/cov/tb_cov_l1d_sweep.sv — BREADTH coverage stress for ven_l1d.
//
// The directed tb_l1d gate proves correctness on a few lines; this companion
// drives EVERY one of the 128 sets through both ways + a 3rd-tag LRU eviction +
// a write-through + a final flush_all, so the set-index decode, the per-way
// valid/tag arrays, the LRU age bits and the fill FSM all TOGGLE across their
// full range. It is also self-checking (read-back equals what was filled), so a
// coverage build that quietly mis-fills still fails. Prints L1DSWEEP-OK / -FAIL.
//
// Geometry (matches ven_l1d): 8 KiB, 2-way, 32-byte line => 128 sets,
//   addr = { tag[31:12], idx[11:5], off[4:0] }.
module tb_cov_l1d_sweep;
  localparam int SETS = 128, LINE = 32, WAYS = 2;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        m_req, m_we; logic [31:0] m_addr, m_wdata; logic [3:0] m_wstrb;
  logic [31:0] m_rdata; logic m_ack;
  logic        flush_all;

  ven_l1d dut(.clk, .rst_n, .flush_all, .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb,
              .c_rdata, .c_ack, .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack);

  // ---- behavioral byte-addressable backing (same-cycle ack) ----------------
  logic [7:0] mem [0:(1<<24)-1];
  function automatic logic [31:0] rd32(input logic [31:0] a);
    rd32 = {mem[a+3], mem[a+2], mem[a+1], mem[a+0]};
  endfunction
  always_comb begin
    m_rdata = 32'd0; m_ack = 1'b0;
    if (m_req) begin m_ack = 1'b1; if (!m_we) m_rdata = rd32(m_addr); end
  end
  always_ff @(posedge clk) if (m_req && m_we)
    for (int b = 0; b < 4; b++) if (m_wstrb[b]) mem[m_addr+b] <= m_wdata[b*8 +: 8];

  int errors = 0;
  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    int guard = 0;
    @(negedge clk); c_req <= 1'b1; c_we <= 1'b0; c_addr <= a; c_wstrb <= 4'd0;
    forever begin
      @(posedge clk); #1;
      if (c_ack) begin d = c_rdata; break; end
      if (++guard > 80) begin $display("  FAIL read %08x: no ack", a); errors++; d = 32'hx; break; end
    end
    @(negedge clk); c_req <= 1'b0;
  endtask
  task automatic do_write(input logic [31:0] a, input logic [31:0] d);
    int guard = 0;
    @(negedge clk); c_req <= 1'b1; c_we <= 1'b1; c_addr <= a; c_wdata <= d; c_wstrb <= 4'hF;
    forever begin
      @(posedge clk); #1;
      if (c_ack) break;
      if (++guard > 80) begin $display("  FAIL write %08x: no ack", a); errors++; break; end
    end
    @(negedge clk); c_req <= 1'b0; c_we <= 1'b0;
  endtask
  task automatic chk(input logic [31:0] got, exp, input string what);
    if (got !== exp) begin $display("  FAIL %s: got %08x exp %08x", what, got, exp); errors++; end
  endtask

  // Build an address from {tag, set, word}.  off = word*4 inside the 32B line.
  function automatic logic [31:0] mk(input int tag, set, word);
    mk = (tag << 12) | (set << 5) | (word << 2);
  endfunction

  logic [31:0] d;
  initial begin
    flush_all = 0; c_req = 0; c_we = 0; c_addr = 0; c_wdata = 0; c_wstrb = 0;
    // seed the backing so every line has a deterministic, distinct pattern
    for (int s = 0; s < SETS; s++)
      for (int t = 1; t <= 3; t++)
        for (int w = 0; w < LINE/4; w++) begin
          logic [31:0] a = mk(t, s, w);
          {mem[a+3], mem[a+2], mem[a+1], mem[a+0]} <= (32'hA5A5_0000 | (t<<8) | (s & 8'hFF)) ^ (w*32'h0101_0101);
        end
    repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

    // 1) cold-fill way 0 of EVERY set (tag 1), read all 8 words back.
    for (int s = 0; s < SETS; s++)
      for (int w = 0; w < LINE/4; w++) begin
        do_read(mk(1, s, w), d); chk(d, rd32(mk(1, s, w)), $sformatf("fill w0 set %0d w %0d", s, w));
      end
    // 2) cold-fill way 1 of every set (tag 2) -> both ways now valid.
    for (int s = 0; s < SETS; s++)
      do_read(mk(2, s, 0), d);
    // 3) hit way 0 again (re-references it -> LRU now points at way 1).
    for (int s = 0; s < SETS; s++)
      do_read(mk(1, s, 0), d);
    // 4) 3rd tag into the full 2-way set -> evicts the LRU victim (way 1).
    for (int s = 0; s < SETS; s++) begin
      do_read(mk(3, s, 0), d); chk(d, rd32(mk(3, s, 0)), $sformatf("evict-fill set %0d", s));
    end
    // 5) write-through every set's way-0 line, confirm array + backing update.
    for (int s = 0; s < SETS; s++) begin
      logic [31:0] wa = mk(1, s, 1), wv = 32'hDEAD_0000 | s;
      do_write(wa, wv);
      do_read(wa, d);          chk(d, wv,       $sformatf("wt array set %0d", s));
      chk(rd32(wa), wv,                          $sformatf("wt backing set %0d", s));
    end
    // 6) flush everything, then a read must MISS and re-fill (exercises flush_all).
    @(negedge clk); flush_all = 1; @(posedge clk); @(negedge clk); flush_all = 0;
    do_read(mk(1, 0, 1), d);  chk(d, 32'hDEAD_0000, "post-flush refill set 0");

    if (errors == 0) $display("L1DSWEEP-OK (128 sets x 2 ways swept)");
    else             $display("L1DSWEEP-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #2_000_000; $display("L1DSWEEP-FAIL (timeout)"); $finish; end
endmodule
