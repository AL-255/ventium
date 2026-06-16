// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l2_stress.sv — capacity-OVERRUN stress gate for ven_l2 + DDR-interaction
// capture. Deliberately drives a working set MANY times the L2 capacity so the cache
// thrashes: every phase forces conflict + capacity misses, dirty evictions, and
// write-back churn. A GOLDEN shadow memory tracks the architectural state; every read
// is checked against it (so a lost/stale line fails immediately), and at the end a cold
// sweep flushes ALL remaining dirty lines and the DDR backing is compared to the golden
// model word-for-word — proving no write survives only in the cache (no dirty data lost
// across the overrun). The downstream "DDR" logs every line-level transaction (fill /
// writeback) so the cache↔DDR interaction is visible, with per-phase + total stats.
//
// A tiny L2 (1 KiB, 2-way → 32 lines, 16 sets) makes overrun cheap: an 8× working set
// is only 256 lines. Built with `verilator --binary`; prints L2STRESS-GATE-OK/FAIL.

module tb_l2_stress;
  localparam int CAP=1024, LINE=32, WAYS=2, RDLAT=2;
  localparam int LINES = CAP/LINE;          // 32 resident lines max
  localparam logic [31:0] SEED = 32'hDDDD_0000;

  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  logic        ready;
  logic        u_req, u_we; logic [31:0] u_addr, u_wdata; logic [3:0] u_wstrb;
  logic [31:0] u_rdata; logic u_ack;
  logic        d_req, d_we; logic [31:0] d_addr, d_wdata; logic [3:0] d_wstrb;
  logic [31:0] d_rdata; logic d_ack;

  ven_l2 #(.L2_CAP_BYTES(CAP), .L2_LINE(LINE), .L2_WAYS(WAYS), .RAM_RD_LAT(RDLAT)) dut (
      .clk, .rst_n, .ready,
      .u_req, .u_we, .u_addr, .u_wdata, .u_wstrb, .u_rdata, .u_ack,
      .d_req, .d_we, .d_addr, .d_wdata, .d_wstrb, .d_rdata, .d_ack);

  // ---- downstream backing "DDR" (combinational ack; per-line trace + counters) ----
  int DLY = 0;
  bit TRACE = 0;            // log line-level DDR transactions
  int trace_budget = 40;   // cap the live trace so it stays readable
  logic [7:0] dmem [0:(1<<19)-1];
  int ddr_rd_w=0, ddr_wr_w=0;          // DDR words read (filled) / written (written back)
  function automatic logic [31:0] drd32(input logic [31:0] a);
    drd32 = {dmem[a+3], dmem[a+2], dmem[a+1], dmem[a+0]};
  endfunction
  logic [4:0] ws;
  wire ack_now = d_req && (ws == 5'(DLY));
  assign d_ack  = ack_now;
  assign d_rdata = (d_req && !d_we) ? drd32(d_addr) : 32'd0;
  always_ff @(posedge clk) begin
    if (!d_req || ack_now) ws <= 5'd0; else ws <= ws + 5'd1;
    if (ack_now) begin
      if (d_we) begin
        for (int b=0;b<4;b++) if (d_wstrb[b]) dmem[d_addr+b] <= d_wdata[b*8 +: 8];
        ddr_wr_w <= ddr_wr_w + 1;
        if (TRACE && d_addr[4:0]==0 && trace_budget>0) begin
          $display("    DDR  WB  line @%06x  (w0<=%08x)", d_addr, d_wdata); trace_budget--; end
      end else begin
        ddr_rd_w <= ddr_rd_w + 1;
        if (TRACE && d_addr[4:0]==0 && trace_budget>0) begin
          $display("    DDR FILL line @%06x", d_addr); trace_budget--; end
      end
    end
  end

  // ---- golden shadow memory (architectural truth) ----------------------------
  logic [31:0] gold [0:(1<<17)-1];     // word-indexed
  function automatic logic [31:0] gld(input logic [31:0] a); gld = gold[a>>2]; endfunction

  int errors = 0;
  task automatic fail(input string s); $display("  FAIL %s", s); errors++; endtask

  // ---- driver: faithful ven_l1d master ---------------------------------------
  task automatic dquiesce();
    int idle; idle=0;
    while (idle<3) begin @(posedge clk); #1; if (d_req) idle=0; else idle++; end
  endtask
  task automatic l2_read(input logic [31:0] addr, output logic [31:0] w [8]);
    logic [31:0] base; int fw, guard;
    base = addr & ~32'h1F;
    @(negedge clk); u_req<=1'b1; u_we<=1'b0; u_wstrb<=4'd0; u_addr<=base;
    fw=0; guard=0;
    forever begin @(posedge clk); #1;
      if (u_ack) begin w[fw]=u_rdata; fw++; if (fw==8) break; u_addr<=base+32'(fw)*4; end
      if (++guard>800) begin fail($sformatf("read %08x stalled", addr)); break; end
    end
    @(negedge clk); u_req<=1'b0; dquiesce();
  endtask
  task automatic l2_write(input logic [31:0] addr, input logic [31:0] data);
    int guard;
    @(negedge clk); u_req<=1'b1; u_we<=1'b1; u_addr<=addr; u_wdata<=data; u_wstrb<=4'hF;
    guard=0;
    forever begin @(posedge clk); #1; if (u_ack) break;
      if (++guard>800) begin fail($sformatf("write %08x stalled", addr)); break; end end
    @(negedge clk); u_req<=1'b0; u_we<=1'b0; dquiesce();
  endtask

  // word-granular helpers (full-word stores; sub-word merge is covered by tb_l2).
  task automatic wr_word(input logic [31:0] a, input logic [31:0] d);
    gold[a>>2] = d; l2_write(a, d);
  endtask
  task automatic rd_word_chk(input logic [31:0] a);
    logic [31:0] w [8];
    l2_read(a, w);
    if (w[a[4:2]] !== gld(a)) fail($sformatf("read %08x got %08x exp %08x", a, w[a[4:2]], gld(a)));
  endtask

  int r0, w0;
  task automatic phase_stats(input string tag, input int rd0, input int wr0);
    $display("    [%s] DDR fills=%0d lines (%0d words), writebacks=%0d lines (%0d words)",
             tag, (ddr_rd_w-rd0)/8, ddr_rd_w-rd0, (ddr_wr_w-wr0)/8, ddr_wr_w-wr0);
  endtask

  int seed = 32'h1234_5678;
  function automatic int rnd(); rnd = $random(seed); endfunction

  logic [31:0] w [8];
  initial begin
    u_req=0; u_we=0; u_addr=0; u_wdata=0; u_wstrb=0;
    // seed DDR + golden identically over the whole touched range.
    for (int i=0;i<(1<<19);i++) dmem[i]=8'h00;
    for (logic [31:0] a=0; a<32'h6_0000; a+=4) begin
      automatic logic [31:0] v = a ^ SEED;
      {dmem[a+3],dmem[a+2],dmem[a+1],dmem[a+0]} = v;
      gold[a>>2] = v;
    end
    repeat(4) @(posedge clk); rst_n<=1'b1;
    wait (ready===1'b1); @(posedge clk);
    $display("[init] L2 ready. capacity = %0d lines (%0d sets x %0d ways)", LINES, LINES/WAYS, WAYS);

    // ============================================================ [1]
    $display("\n[1] SEQUENTIAL WRITE overrun: write %0d distinct lines = %0dx capacity",
             8*LINES, 8);
    $display("    (every fresh line write-allocates a fill; displaced DIRTY lines write back)");
    TRACE=1; r0=ddr_rd_w; w0=ddr_wr_w;
    for (int i=0;i<8*LINES;i++) wr_word(32'(i)*LINE, 32'hD0000000 | 32'(i));   // word0 of line i
    TRACE=0;
    phase_stats("seq-write", r0, w0);
    if ((ddr_wr_w-w0) == 0) fail("overrun produced NO writebacks (dirty path not exercised)");

    // ============================================================ [2]
    $display("\n[2] SEQUENTIAL READ-back of all %0d lines: each missed line refills from DDR;",
             8*LINES);
    $display("    the written value must survive eviction→DDR→refill (no dirty data lost)");
    r0=ddr_rd_w; w0=ddr_wr_w;
    for (int i=0;i<8*LINES;i++) rd_word_chk(32'(i)*LINE);
    phase_stats("seq-read", r0, w0);

    // ============================================================ [3]
    $display("\n[3] CONFLICT THRASH: hammer %0d lines mapping to ONE set (stride=%0d) -> every",
             WAYS+2, (LINES/WAYS)*LINE);
    $display("    access evicts a way; alternate write/read so eviction churns DIRTY lines");
    TRACE=1; trace_budget=24; r0=ddr_rd_w; w0=ddr_wr_w;
    begin
      automatic logic [31:0] sbase = 32'h0004_0000;            // set 0 of a fresh region
      automatic int stride = (LINES/WAYS)*LINE;                // same-set stride
      for (int it=0; it<8; it++)
        for (int k=0; k<WAYS+2; k++) begin                     // WAYS+2 lines => guaranteed evictions
          automatic logic [31:0] a = sbase + 32'(k)*stride;
          if ((it+k) % 2 == 0) wr_word(a, 32'hC0000000 | (32'(it)<<8) | 32'(k));
          else                 rd_word_chk(a);
        end
    end
    TRACE=0;
    phase_stats("thrash", r0, w0);

    // ============================================================ [4]
    $display("\n[4] RANDOM mixed read/write over a %0dx-capacity range (golden-checked)", 16);
    r0=ddr_rd_w; w0=ddr_wr_w;
    for (int n=0; n<800; n++) begin
      automatic logic [31:0] a = (32'(rnd()) % (16*LINES)) * LINE + (32'(rnd())%8)*4;
      if (rnd() & 1) wr_word(a, 32'hA0000000 | 32'(n));
      else           rd_word_chk(a);
    end
    phase_stats("random", r0, w0);

    // ============================================================ [5]
    $display("\n[5] COLD-SWEEP FLUSH then DDR==GOLDEN: read enough fresh lines to evict every");
    $display("    resident (dirty) line, then verify the DDR backing matches the golden model");
    $display("    word-for-word over the whole touched range (proves zero lost writes).");
    r0=ddr_rd_w; w0=ddr_wr_w;
    // sweep 4x capacity of pristine cold lines from a far region -> flushes the cache.
    for (int i=0;i<4*LINES;i++) begin l2_read(32'h0008_0000 + 32'(i)*LINE, w); end
    phase_stats("flush-sweep", r0, w0);
    begin
      int mism; mism=0;
      // check every word the test could have written (ranges touched in [1]-[4]).
      for (logic [31:0] a=0; a<32'h0005_0000; a+=4)
        if (drd32(a) !== gld(a)) begin
          if (mism<8) $display("  FAIL DDR!=GOLD @%06x: ddr=%08x gold=%08x", a, drd32(a), gld(a));
          mism++;
        end
      if (mism==0) $display("    DDR backing == golden model across the whole range (no lost writes)");
      else fail($sformatf("%0d words differ between DDR and golden after flush", mism));
    end

    $display("\n[totals] DDR fills=%0d lines, writebacks=%0d lines, words moved=%0d (%0d KiB)",
             ddr_rd_w/8, ddr_wr_w/8, ddr_rd_w+ddr_wr_w, (ddr_rd_w+ddr_wr_w)*4/1024);

    if (errors==0) $display("\nL2STRESS-GATE-OK (overrun survived, no dirty data lost)");
    else           $display("\nL2STRESS-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #20000000; $display("L2STRESS-GATE-FAIL (timeout)"); $finish; end
endmodule
