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
  // KEN# / snoop (Phase A): default cacheable, no snoop — groups [9]/[10] drive them.
  logic        cacheable = 1'b1;
  logic        snoop_inv_valid = 1'b0;
  logic [31:0] snoop_inv_addr  = 32'd0;

  ven_l1d dut (.clk, .rst_n, .flush_all(1'b0), .golden(1'b0),
               .cacheable, .snoop_inv_valid, .snoop_inv_addr,
               .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb, .c_rdata, .c_ack,
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

  // back-to-back reads with c_req HELD (mimics the core's S_FETCH 4-word burst): advance
  // c_addr on each c_ack, NEVER dropping c_req. do_read drops c_req between reads, so it
  // misses the read-after-read protocol — exactly where a pipelined/1-cycle read FSM can
  // mis-handle the addr advance vs the ack. Also covers the first word missing (fill) then
  // the rest hitting, all in one held burst.
  task automatic do_read_b2b(input logic [31:0] base, input int n);
    int guard; int i;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_wstrb<=4'd0; c_addr<=base;
    i=0; guard=0;
    forever begin
      @(posedge clk); #1;
      if (c_ack) begin
        // expected = the 4 backing bytes at the (possibly UNALIGNED) byte address — covers
        // unaligned + cross-line (xline) reads the aligned (addr^A5A5) formula can't express.
        automatic logic [31:0] a = base + 32'(i)*4;
        automatic logic [31:0] exp = {mem[a+3], mem[a+2], mem[a+1], mem[a+0]};
        chk($sformatf("b2b w%0d @%08x", i, a), c_rdata, exp);
        i++; if (i==n) break;
        c_addr <= base + 32'(i)*4;            // advance; c_req STAYS high
      end
      if (++guard > 300) begin $display("  FAIL b2b: no ack at w%0d", i); errors++; break; end
    end
    @(negedge clk); c_req<=1'b0;
  endtask

  // pulse a one-clock snoop invalidate for the line containing `a`.
  task automatic do_snoop(input logic [31:0] a);
    @(negedge clk); snoop_inv_valid<=1'b1; snoop_inv_addr<=a;
    @(negedge clk); snoop_inv_valid<=1'b0;
  endtask
  // direct backing write (simulates a DMA master writing DRAM behind the L1's back).
  task automatic dma_poke(input logic [31:0] a, input logic [31:0] v);
    for (int b=0;b<4;b++) mem[a+b] = v[b*8 +: 8];
  endtask

  logic [31:0] d;
  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    // seed the backing with a recognizable pattern: word at addr A = A ^ 0xA5A5_0000
    for (int i=0;i<(1<<20);i++) mem[i] = 8'h00;
    for (logic [31:0] a=0; a<32'h4400; a+=4)
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

    $display("[5] BACK-TO-BACK reads, c_req held (S_FETCH-style burst): word0 miss+fill, rest hit");
    do_read_b2b(32'h0000_1840, 8);   // fresh line 0x1840: first word fills, then 7 held hits
    $display("[6] BACK-TO-BACK reads on an ALREADY-resident line (all hits, held c_req)");
    do_read_b2b(32'h0000_1840, 8);   // now fully resident -> 8 held hits in a row

    $display("[7] BACK-TO-BACK UNALIGNED reads, held c_req (S_FETCH at an unaligned eip):");
    $display("    boff=26,30,... -> includes a CROSS-LINE (xline) word @boff=30 mid-burst");
    do_read_b2b(32'h0000_1c1a, 6);   // 0x1c1a unaligned: words at boff 26,30(xline),2,6,10,14
    $display("[8] same burst over a COLD next line (xline fills L+1 mid-burst)");
    do_read_b2b(32'h0000_201a, 6);   // 0x201a: line 0x2000 + crosses into cold 0x2020 @boff=30

    // ----- NEW Phase A behavior: KEN# bypass + snoop invalidate ---------------
    $display("[9] NON-CACHEABLE read (cacheable=0): no allocate, fresh data each time");
    cacheable = 1'b0;
    do_read(32'h0000_0500, d); chk("nc read 0x500", d, 32'h0500 ^ 32'hA5A5_0000);
    dma_poke(32'h0000_0500, 32'hCAFE_F00D);             // backing changes underneath
    do_read(32'h0000_0500, d); chk("nc re-read sees new", d, 32'hCAFE_F00D); // proves not cached
    $display("[9b] NON-CACHEABLE write (cacheable=0): straight write-through, no allocate");
    do_write(32'h0000_0600, 32'h1234_5678);
    chk("nc write hit backing", rd32(32'h0000_0600), 32'h1234_5678);
    cacheable = 1'b1;
    do_read(32'h0000_0600, d); chk("cacheable read-back", d, 32'h1234_5678);
    // the non-cacheable accesses must NOT have polluted/evicted resident lines:
    do_read(32'h0000_1004, d); chk("resident line intact", d, 32'h1004 ^ 32'hA5A5_0000);

    $display("[10] SNOOP invalidate: DMA write + snoop -> next read refills new data");
    do_read(32'h0000_4000, d); chk("cache line@4000", d, 32'h4000 ^ 32'hA5A5_0000); // now resident
    dma_poke(32'h0000_4000, 32'h0BAD_C0DE);             // DMA overwrites it in DRAM
    do_read(32'h0000_4000, d); chk("stale hit pre-snoop", d, 32'h4000 ^ 32'hA5A5_0000); // still cached (stale)
    do_snoop(32'h0000_4000);                            // northbridge invalidates the line
    do_read(32'h0000_4000, d); chk("post-snoop refill",  d, 32'h0BAD_C0DE);            // miss -> fresh data

    // ----- COVERAGE sweep: walk data/address across every set, way and tag so
    // the cache DATA array (rd_line/bp_line), VALID/LRU bits (dc_val/dc_lru) and
    // TAGs toggle. No chk() -> pure toggle stimulus, cannot fail the gate. -------
    $display("[11] COVERAGE sweep: walking data/addr across sets/ways/tags");
    for (int i=0;i<128;i++) begin
      automatic logic [31:0] s = 32'(i) * 32'h20;          // one line per set (addr[11:5])
      do_write(s,             32'h1 << (i%32));            // way A, walking data
      do_write(s + 32'h1000,  ~(32'h1 << (i%32)));         // way B (same set), complement
      do_read (s + 32'h2000, d);                            // 3rd tag -> LRU eviction
      do_read (s + 32'h8000, d);                            // 4th tag (high addr bit) -> tag toggle
      do_read (s,            d);                             // refill the evicted way A
    end
    for (int i=0;i<32;i++) do_write(32'h0000_0040 + 32'(i)*4, 32'h1 << i);  // walking data in a line
    for (int i=0;i<32;i++) do_read (32'h0000_0040 + 32'(i)*4, d);
    for (int i=0;i<16;i++) do_read (32'(i)*32'h10000, d);   // walking-bit TAGs (64 KiB stride)
    do_snoop(32'h0000_2000); do_snoop(32'h0000_8000); do_snoop(32'h0001_0000);

    if (errors==0) $display("L1D-GATE-OK (all checks pass)");
    else           $display("L1D-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #200000; $display("L1D-GATE-FAIL (timeout)"); $finish; end
endmodule
