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
  parameter int TB_L1_SETS = 128;   // REVIEW2 M-04: overridden by the gate script
  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  // core side
  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  // backing side
  logic        m_req, m_we; logic [31:0] m_addr, m_wdata; logic [3:0] m_wstrb;
  logic [31:0] m_rdata; logic m_ack;
  logic        m_rd_narrow; logic [1:0] m_rd_size;
  // REVIEW2_aug2 H-11: count backing READ beats, so a non-cacheable access can be
  // asserted to cost ONE (or two, unaligned) instead of a full 8-beat line.
  int          rbeats;
  always_ff @(posedge clk) if (rst_n && m_req && !m_we) rbeats <= rbeats + 1;
  // KEN# / snoop (Phase A): default cacheable, no snoop — groups [9]/[10] drive them.
  logic        cacheable = 1'b1;
  logic        snoop_inv_valid = 1'b0;
  logic [31:0] snoop_inv_addr  = 32'd0;

  // REVIEW Aug-1 M-17: this instantiation had gone stale against the module -- the
  // dbg_serve output added for load-serve forensics was never connected, and because
  // the gate runs warning-fatal it FAILED AT BUILD TIME. Every other L1 gate passed,
  // so the most important cache block was being silently skipped while the suite as a
  // whole still looked healthy.
  // REVIEW2 M-04: the geometry is now a TB parameter so the gate can be run at more
  // than one L1_SETS. The module used to hard-code a 7-bit set index and a 20-bit tag
  // regardless of L1_SETS, so any override silently indexed past the arrays and split
  // the address at the wrong bit. run-l1d-gate.sh runs this at 128 AND at 64; the
  // second run is what actually proves the split follows the parameter.
  ven_l1d #(.L1_SETS(TB_L1_SETS)) dut (.clk, .rst_n, .flush_all(1'b0), .golden(1'b0),
               .cacheable, .snoop_inv_valid, .snoop_inv_addr,
               .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb, .c_rdata, .c_ack,
               .dbg_serve(),                       // M-17: diagnostic only

               .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack,
               // REVIEW2_aug2 H-11: the narrow-read request shape. This TB has no AXI
               // master, so it does not consume these -- but counting backing beats
               // (below) is how the fix is MEASURED, and leaving the pins unconnected
               // is what made this gate fail warning-fatal at build time.
               // REVIEW1_Aug3 R2-H01: m_rd_size is the per-piece ARSIZE.
               .m_rd_narrow, .m_rd_size);

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

  // A delayed response belongs to the request that launched it, not merely to
  // whatever request happens to be live when the response is served.  The core
  // can advance c_addr while an earlier response indication is still visible
  // (the registered cache-hit path has rd_addr_q/rd_match for exactly this
  // reason).  Exercise the same contract on the non-cacheable L1_BYP path:
  // abandon A after its backing beat has completed, present B with c_req held,
  // and require A's buffered response to be discarded rather than acknowledged
  // as B.  B must then retry normally and receive B's own data.
  task automatic do_nc_read_retarget(input logic [31:0] a, b,
                                     output logic [31:0] d);
    int guard;
    @(negedge clk);
    c_req = 1'b1; c_we = 1'b0; c_addr = a; c_wstrb = 4'd0;
    // L1_BYP is enum value 3.  Wait until A's private buffer is ready, then
    // retarget within that serve clock before sampling the response.
    wait (dut.st == 2'd3);
    #1; c_addr = b;
    #1;
    if (c_ack) begin
      $display("  FAIL bypass response for A was acknowledged as request B");
      errors++;
    end else begin
      $display("  ok   bypass response ownership rejects retargeted request");
    end
    guard = 0;
    forever begin
      @(posedge clk); #1;
      if (c_ack) begin d = c_rdata; break; end
      if (++guard > 50) begin
        $display("  FAIL retargeted read %08x: no retry ack", b);
        errors++; d = 32'hx; break;
      end
    end
    @(negedge clk); c_req = 1'b0;
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

    // ----- REVIEW1_Aug2 H-07: a non-cacheable read of a RESIDENT line -------------
    // Group [9] above reads addresses that were never cached, so it cannot see this:
    // rd_hit is computed from the array regardless of `cacheable`, so a line that is
    // STILL RESIDENT when CD is set served CACHED data -- stale pre-CD RAM, and a
    // suppressed read side effect for a cache-mapped MMIO region. Under
    // VEN_L1_HONOR_CD the bypass-read FSM is disabled, so nothing else caught it.
    //
    // Make a line resident, change the backing underneath, then read it with
    // cacheable=0. It must return the NEW value. The default build reaches that via
    // the bypass path and the HONOR_CD build via a forced miss + allocating fill, so
    // this check is valid for BOTH configurations.
    $display("[9c] NON-CACHEABLE read of a RESIDENT line must not serve stale data");
    cacheable = 1'b1;
    do_read(32'h0000_4200, d); chk("prime resident", d, 32'h4200 ^ 32'hA5A5_0000);
    dma_poke(32'h0000_4200, 32'hDEAD_BEEF);   // backing changes, no snoop issued
    cacheable = 1'b0;                          // CD asserted with the line still resident
    do_read(32'h0000_4200, d);
    chk("nc read of resident line is FRESH", d, 32'hDEAD_BEEF);
    cacheable = 1'b1;

    // ----- FPGA reset-state regression: L1_BYP response ownership ----------------
    // The focused nested-IRQ ROM reproduced this in source-matched Verilator:
    // an instruction-fetch response (bytes 06 c7 26 ...) was acknowledged as the
    // subsequent IVT read at physical 0x20, replacing the expected f000:024d
    // vector and escaping to CS=06c7.  This small case isolates that protocol
    // failure without depending on the BIOS or interrupt engine.
    $display("[9d] NON-CACHEABLE response must not be acknowledged after c_addr retargets");
    dma_poke(32'h0000_4300, 32'h06C7_2600);  // old request A / recognizable code bytes
    dma_poke(32'h0000_0020, 32'hF000_024D);  // new request B / expected IVT8 entry
    cacheable = 1'b0;
    do_nc_read_retarget(32'h0000_4300, 32'h0000_0020, d);
    chk("retargeted request receives its own IVT data", d, 32'hF000_024D);
    cacheable = 1'b1;

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

    // ---- [11c] REVIEW2_aug2 C-09: a CROSS-LINE uncacheable read must not corrupt a
    // resident victim. The ninth (high-word) beat used to fall through to the array
    // write with fw still 7, so it overwrote victim word 7 of {fset,fway} with NO tag
    // or valid update -- a valid unrelated line silently corrupted beneath its own tag.
    //
    // The sentinel is what makes this detectable: prime a line, remember a word of it,
    // then do the cross-line bypass read that targets the SAME set, then re-read the
    // sentinel. Without the fix the sentinel word comes back as bypass data.
    // *** THIS CASE DOES NOT YET DISCRIMINATE. *** Measured: with the fix REVERTED it
    // still passes. The bypass fill targets fway = ~dc_lru[set_c] -- the LRU VICTIM way
    // -- while the sentinel below sits in whichever way the prime used, so the
    // corruption lands in a different way than the one checked. To discriminate it must
    // prime BOTH ways of the set and then touch one so the sentinel's way is provably
    // the LRU victim. Kept as a non-regression check, labelled so the green line is not
    // mistaken for evidence.
    $display("[11c] cross-line uncacheable read must not corrupt a resident victim");
    $display("      (NOTE: does not yet discriminate -- see the comment above)");
    cacheable = 1'b1;
    do_write(32'h0000_6000 + 32'd28, 32'hA1C7_0007);   // word 7 of the line at 0x6000
    do_read (32'h0000_6000 + 32'd28, d);
    chk("victim word 7 primed", d, 32'hA1C7_0007);
    cacheable = 1'b0;
    do_read (32'h0000_6000 + 32'd30, d);   // offset 30 > 28 -> crosses, takes the 9th beat
    cacheable = 1'b1;
    do_read (32'h0000_6000 + 32'd28, d);
    chk("victim word 7 SURVIVED the cross-line bypass", d, 32'hA1C7_0007);

    // ---- [11e] REVIEW2_aug2 H-11: A NON-CACHEABLE READ COSTS ONE BEAT ------------
    // The finding: a non-cacheable read reused the FILL burst, so ONE architectural
    // read became a 32-byte eight-beat request (sixteen when it crossed a line end).
    // For MMIO that is a CORRECTNESS bug, not a performance one -- read-to-clear
    // registers are cleared eight times over, FIFOs pop repeatedly, and seven
    // neighbouring addresses with unrelated side effects are touched.
    //
    // This counts BACKING READ BEATS across a single non-cacheable read, which is the
    // only thing that actually distinguishes the fix from the bug. The data checks
    // above all passed WITH the amplification -- serving the right word was never the
    // problem, so no data assertion can see this.
    //
    // MEASURED, by forcing the old line-shaped fetch back on with the new ports left
    // in place, so these are counts from a real run and not read off the old source:
    //   aligned    8 beats -> 1
    //   unaligned  8 beats -> 2   (at offset 2; a line-CROSSING access cost 8 + an
    //                              extra 8-beat request, which is the [11c] case)
    // The H-19 cross-line special case disappears here: once the fetch is word-shaped
    // instead of line-shaped, two contiguous words are just two contiguous words, and
    // whether a 32-byte boundary falls between them stops mattering.
    cacheable = 1'b1;
    do_write(32'h0000_7000, 32'h1111_2222);
    do_write(32'h0000_7004, 32'h3333_4444);
    cacheable = 1'b0;
    rbeats = 0;
    do_read (32'h0000_7000, d);
    chk("H-11 aligned non-cacheable data", d, 32'h1111_2222);
    if (rbeats != 1) begin
      $display("  FAIL H-11: aligned non-cacheable read took %0d backing beats, want 1", rbeats);
      errors++;
    end else $display("  ok   H-11 aligned non-cacheable read = 1 backing beat (was 8)");

    // unaligned: spans two words, so exactly TWO beats -- not one, and not eight.
    rbeats = 0;
    do_read (32'h0000_7002, d);
    // Also check the DATA: the serve now indexes a 2-word window by c_addr[1:0]
    // instead of indexing the whole line by c_addr[4:0], and that is new logic.
    // bytes @7002..7005 = 11 11 44 44 -> 0x44441111
    chk("H-11 unaligned non-cacheable data (2-word window)", d, 32'h4444_1111);
    if (rbeats != 2) begin
      $display("  FAIL H-11: unaligned non-cacheable read took %0d backing beats, want 2", rbeats);
      errors++;
    end else $display("  ok   H-11 unaligned non-cacheable read = 2 backing beats (was 8)");

    cacheable = 1'b1;

    // ---- [11d] REVIEW2_aug2 C-09 (second half): a cacheable miss issued IMMEDIATELY
    // after a cross-line uncacheable read must get ITS OWN data, every word.
    //
    // The high-word request is a single word to ven_l1d but an EIGHT-BEAT line burst on
    // the backing seam -- ven_axi_master cannot request one word -- and the seam has no
    // transaction ID. Taking beat 0 and leaving to serve left SEVEN beats outstanding,
    // so the very next L1_FILL could consume the old burst's residual data AS ITS OWN
    // LINE, under a tag that says it is correct.
    //
    // This is the review's own suggested shape: cross-line uncacheable read, then a
    // cacheable miss, checking EVERY returned word rather than one.
    //
    // *** IT DOES NOT DISCRIMINATE IN THIS HARNESS, AND CANNOT. *** Measured: with the
    // drain reverted it still passes, all eight words. The reason is structural rather
    // than a flaw in the case -- THIS testbench drives m_ack directly, one word per
    // request, so an eight-beat burst with seven residual beats does not exist here.
    // The hazard lives on the ven_axi_master seam, which tb_l1d does not instantiate.
    //
    // To actually catch it the case has to run against the real burst master, i.e. in
    // the tb_l1_axi family, issuing the cross-line uncacheable read and the following
    // cacheable miss back to back with no idle gap. Kept here as a non-regression check
    // of the data path, labelled so the green line is not mistaken for evidence -- the
    // same reason [11c] above carries its own label.
    $display("[11d] a cacheable miss right after a cross-line bypass gets its own data");
    $display("      (NOTE: does not discriminate in this TB -- see the comment above)");
    cacheable = 1'b1;
    for (int w = 0; w < 8; w++)
      do_write(32'h0000_8000 + w*4, 32'hC090_0000 + w);   // 8 distinct words, write-through
    cacheable = 1'b0;
    do_read (32'h0000_6000 + 32'd30, d);   // cross-line bypass: takes the high request
    cacheable = 1'b1;
    for (int w = 0; w < 8; w++) begin
      do_read(32'h0000_8000 + w*4, d);
      chk($sformatf("word %0d of the line filled after the bypass", w),
          d, 32'hC090_0000 + w);
    end

    // [12] NON-CACHEABLE bypass sweep: walking data/addr through the bypass-line
    // buffer (bp_line) which only the cacheable=0 path loads.
    cacheable = 1'b0;
    for (int i=0;i<64;i++) begin
      do_write(32'h0000_5000 + 32'(i)*4, 32'h1 << (i%32));
      do_read (32'h0000_5000 + 32'(i)*4, d);
      do_read ((32'(i)<<8) ^ 32'h0009_1100, d);            // diverse nc addresses (m_addr/c_addr)
    end
    cacheable = 1'b1;
    // [13] more cacheable line fills over diverse tags to flip the rest of dc_val
    for (int i=0;i<64;i++) begin
      do_read (32'h0008_0000 + 32'(i)*32'h20, d);          // a fresh region, all sets
      do_write(32'h0008_0000 + 32'(i)*32'h20, ~(32'h2 << (i%30)));
    end
    do_snoop(32'h0004_0000); do_snoop(32'h0008_0000); do_snoop(32'h000F_0000);

    // [14] fill EVERY set x both ways (valid 0->1) then snoop-invalidate every
    // one (valid 1->0) so dc_val toggles both directions across the whole array.
    for (int i=0;i<128;i++) begin
      do_read(32'(i)*32'h20,             d);   // set i, tag 0 -> way A
      do_read(32'(i)*32'h20 + 32'h1000,  d);   // set i, tag 1 -> way B
    end
    for (int i=0;i<128;i++) begin
      do_snoop(32'(i)*32'h20);                  // invalidate way A
      do_snoop(32'(i)*32'h20 + 32'h1000);       // invalidate way B
    end

    // [15] walking-bit ADDRESS sweeps to toggle the high address-register bits
    // (m_addr/c_addr/fbase/rd_addr_q) + the bypass buffer + snoop-invalidate addr.
    cacheable = 1'b0;
    for (int i=2;i<20;i++) begin                 // bit 2..19 within the 1 MiB backing
      do_read (32'h1 << i, d);                    // nc read -> bypass + c_addr/m_addr bit i
      do_write(32'h1 << i, 32'hF0F0_0F0F);
    end
    cacheable = 1'b1;
    for (int i=5;i<27;i++) do_snoop(32'h1 << i);  // walking-bit snoop-invalidate addresses

    if (errors==0) $display("L1D-GATE-OK (all checks pass)");
    else           $display("L1D-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #200000; $display("L1D-GATE-FAIL (timeout)"); $finish; end
endmodule
