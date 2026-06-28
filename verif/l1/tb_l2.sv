// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l2.sv — standalone self-checking gate for ven_l2 (the UltraRAM L2).
//
// A latency-injecting backing model plays the role of the PS-DDR (it speaks the
// DOWNSTREAM backing protocol ven_axi_master would consume) and COUNTS its accesses,
// so the test can PROVE the latency-hiding behaviour, not just functional correctness:
//   * an L2 HIT performs ZERO DDR reads;
//   * a write HIT / write-allocate performs ZERO DDR writes (write-back);
//   * a DIRTY eviction writes the line back to DDR exactly once, byte-correct;
//   * a CLEAN eviction performs no writeback.
// The upstream driver mimics ven_l1d's master EXACTLY (a fill holds u_req and walks 8
// word addresses consuming one ack each; a write holds a byte store until one ack).
// Built with `verilator --binary`; prints L2-GATE-OK / L2-GATE-FAIL. A small L2
// (1 KiB, 2-way) is instantiated so init + evictions are quick; the URAM tiling is a
// synth-time property of the default 2 MiB config (see fpga/scripts/probe_l2_uram.tcl).

module tb_l2;
  // small config for fast sim: 1 KiB, 2-way → 32 lines, 16 sets, lines sharing a set
  // differ by 16*32 = 0x200. RAM_RD_LAT=2 (the URAM-recommended depth).
  localparam int CAP   = 1024;
  localparam int LINE  = 32;
  localparam int WAYS  = 2;
  localparam int RDLAT = 2;

  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  // ---- DUT ports -------------------------------------------------------------
  logic        ready;
  logic        u_req, u_we; logic [31:0] u_addr, u_wdata; logic [3:0] u_wstrb;
  logic [31:0] u_rdata; logic u_ack;
  logic        d_req, d_we; logic [31:0] d_addr, d_wdata; logic [3:0] d_wstrb;
  logic [31:0] d_rdata; logic d_ack;

  ven_l2 #(.L2_CAP_BYTES(CAP), .L2_LINE(LINE), .L2_WAYS(WAYS), .RAM_RD_LAT(RDLAT)) dut (
      .clk, .rst_n, .ready,
      .u_req, .u_we, .u_addr, .u_wdata, .u_wstrb, .u_rdata, .u_ack,
      .d_req, .d_we, .d_addr, .d_wdata, .d_wstrb, .d_rdata, .d_ack);

  // ---- downstream backing model (the "PS-DDR") -------------------------------
  // byte-addressable; DLY wait-states per word; combinational ack (== ven_axi_master
  // m_ack timing). Counts read/write acks so the test can assert DDR traffic.
  int DLY = 0;                       // per-word downstream latency (knob)
  bit VERBOSE = 0;                   // log every DDR access (debug)
  logic [7:0] dmem [0:(1<<16)-1];
  int ddr_rd = 0, ddr_wr = 0;
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
        ddr_wr <= ddr_wr + 1;
        if (VERBOSE) $display("    DDR WR @%08x t=%0t", d_addr, $time);
      end else begin
        ddr_rd <= ddr_rd + 1;
        if (VERBOSE) $display("    DDR RD @%08x t=%0t", d_addr, $time);
      end
    end
  end

  // ---- checkers --------------------------------------------------------------
  int errors = 0;
  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %08x exp %08x", what, got, exp); errors++; end
    else $display("  ok   %s = %08x", what, got);
  endtask
  task automatic chk_int(input string what, input int got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %0d exp %0d", what, got, exp); errors++; end
    else $display("  ok   %s = %0d", what, got);
  endtask

  // wait until the downstream (DDR) bus has been idle for a few clocks, so every DDR
  // access a just-finished transaction issued is fully TALLIED before the next
  // snapshot. (forward-during-fill drives u_rdata/u_ack one delta ahead of the BFM's
  // clocked read tally, so an l2_read returns ~1 cycle before its last DDR beat is
  // counted; without this the stray count would straddle into the next test's delta.)
  task automatic dquiesce();
    int idle; idle=0;
    while (idle < 3) begin @(posedge clk); #1; if (d_req) idle=0; else idle++; end
  endtask

  // ---- upstream driver: faithful ven_l1d master ------------------------------
  // FILL: hold u_req, walk 8 line-aligned word addresses, capture one word per ack.
  task automatic l2_read(input logic [31:0] addr, output logic [31:0] w [8]);
    logic [31:0] base; int fw, guard;
    base = addr & ~32'h1F;
    @(negedge clk); u_req<=1'b1; u_we<=1'b0; u_wstrb<=4'd0; u_addr<=base;
    fw=0; guard=0;
    forever begin
      @(posedge clk); #1;
      if (u_ack) begin
        if (VERBOSE) $display("    drv cap w%0d=%08x t=%0t", fw, u_rdata, $time);
        w[fw] = u_rdata; fw++;
        if (fw==8) break;
        u_addr <= base + 32'(fw)*4;        // advance, u_req STAYS high
      end
      if (++guard>400) begin $display("  FAIL read %08x: only %0d words", addr, fw); errors++; break; end
    end
    @(negedge clk); u_req<=1'b0;
    dquiesce();                                   // let the last DDR beat tally
  endtask

  // WRITE-through: present a byte store, hold until the single ack.
  task automatic l2_write(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb);
    int guard;
    @(negedge clk); u_req<=1'b1; u_we<=1'b1; u_addr<=addr; u_wdata<=data; u_wstrb<=strb;
    guard=0;
    forever begin @(posedge clk); #1; if (u_ack) break;
      if (++guard>400) begin $display("  FAIL write %08x: no ack", addr); errors++; break; end end
    @(negedge clk); u_req<=1'b0; u_we<=1'b0;
    dquiesce();                                   // let any writeback/fill beat tally
  endtask

  // read a whole line and check all 8 words against the seeded backing pattern.
  task automatic rd_check_line(input string tag, input logic [31:0] base, input logic [31:0] xorpat);
    logic [31:0] w [8];
    l2_read(base, w);
    for (int i=0;i<8;i++)
      chk($sformatf("%s w%0d", tag, i), w[i], (base + 32'(i)*4) ^ xorpat);
  endtask

  logic [31:0] w [8];
  int r0, w0;
  initial begin
    u_req=0; u_we=0; u_addr=0; u_wdata=0; u_wstrb=0;
    // seed the backing: word at addr A = A ^ 0xC0DE_0000.
    for (int i=0;i<(1<<16);i++) dmem[i]=8'h00;
    for (logic [31:0] a=0; a<32'h2000; a+=4)
      {dmem[a+3],dmem[a+2],dmem[a+1],dmem[a+0]} = a ^ 32'hC0DE_0000;
    repeat(4) @(posedge clk); rst_n<=1'b1;
    // wait out the post-reset valid-clear init walk.
    wait (ready===1'b1); @(posedge clk);
    $display("[init] L2 ready after valid-clear walk");

    // ------------------------------------------------------------------ [1]
    $display("[1] cold read -> MISS -> fill from DDR (forward-during-fill), 8 words");
    r0=ddr_rd; rd_check_line("cold@0x40", 32'h0000_0040, 32'hC0DE_0000);
    chk_int("DDR reads for a cold fill", ddr_rd-r0, 8);

    // ------------------------------------------------------------------ [2]
    $display("[2] re-read the SAME line -> L2 HIT -> ZERO DDR reads");
    r0=ddr_rd; rd_check_line("hit@0x40", 32'h0000_0040, 32'hC0DE_0000);
    chk_int("DDR reads for an L2 hit", ddr_rd-r0, 0);

    // ------------------------------------------------------------------ [3]
    $display("[3] write HIT (resident line) -> write-back: ZERO DDR writes, line dirty");
    w0=ddr_wr;
    l2_write(32'h0000_0048, 32'hDEAD_BEEF, 4'hF);     // word at 0x48 (in the 0x40 line)
    chk_int("DDR writes for a write hit", ddr_wr-w0, 0);
    l2_read(32'h0000_0040, w);
    chk("read-after-write @0x48", w[2], 32'hDEAD_BEEF);   // 0x48 is word index 2
    chk("DDR still has OLD @0x48 (write-back)", drd32(32'h48), 32'h48 ^ 32'hC0DE_0000);

    // ------------------------------------------------------------------ [4]
    $display("[4] CLEAN eviction: fill set to capacity then a 3rd line -> evict, NO writeback");
    // set index = addr[8:5] (16 sets); lines 0x600/0x800/0xA00 all map to set 0.
    rd_check_line("A@0x600", 32'h0000_0600, 32'hC0DE_0000);   // way A (clean)
    rd_check_line("B@0x800", 32'h0000_0800, 32'hC0DE_0000);   // way B (clean) -> set full
    w0=ddr_wr; r0=ddr_rd;
    rd_check_line("C@0xA00", 32'h0000_0A00, 32'hC0DE_0000);   // evicts LRU (clean)
    chk_int("DDR writes on a CLEAN eviction", ddr_wr-w0, 0);
    chk_int("DDR reads to fill the new line", ddr_rd-r0, 8);

    // ------------------------------------------------------------------ [5]
    $display("[5] DIRTY eviction: dirty a line, force it out -> byte-correct writeback");
    // make set 1 (lines 0x620/0x820/0xA20). dirty 0x620, then evict via 0x820 + 0xA20.
    rd_check_line("D@0x620", 32'h0000_0620, 32'hC0DE_0000);   // resident, clean
    l2_write(32'h0000_0620, 32'h1234_5678, 4'hF);             // dirty word 0 of 0x620
    rd_check_line("E@0x820", 32'h0000_0820, 32'hC0DE_0000);   // way B
    w0=ddr_wr;
    rd_check_line("F@0xA20", 32'h0000_0A20, 32'hC0DE_0000);   // evicts LRU == 0x620 (dirty)
    chk_int("DDR writes on a DIRTY eviction (one line = 8 words)", ddr_wr-w0, 8);
    chk("writeback landed in DDR @0x620", drd32(32'h620), 32'h1234_5678);
    chk("writeback left the rest of the line intact @0x624", drd32(32'h624), 32'h624 ^ 32'hC0DE_0000);

    // ------------------------------------------------------------------ [6]
    $display("[6] write-allocate on a write MISS -> fill+merge, read-back hit, no DDR write");
    w0=ddr_wr; r0=ddr_rd;
    l2_write(32'h0000_0C04, 32'hCAFE_F00D, 4'hF);            // 0xC04 not resident -> allocate
    chk_int("DDR reads to allocate on write miss", ddr_rd-r0, 8);
    chk_int("DDR writes on write-allocate (deferred)", ddr_wr-w0, 0);
    l2_read(32'h0000_0C00, w);
    chk("write-allocate read-back @0xC04", w[1], 32'hCAFE_F00D);
    chk("untouched word in the allocated line @0xC00", w[0], 32'hC00 ^ 32'hC0DE_0000);

    // ------------------------------------------------------------------ [7]
    $display("[7] sub-word / unaligned stores merge correctly");
    l2_read(32'h0000_0040, w);                               // resident
    l2_write(32'h0000_0041, 32'h0000_00AB, 4'h1);            // 1 byte at line-byte 1
    l2_write(32'h0000_0046, 32'h0000_CDEF, 4'h3);            // 2 bytes at line-byte 6..7
    l2_read(32'h0000_0040, w);
    chk("byte store @0x41", w[0][15:8], 8'hAB);
    chk("byte0 of word0 untouched", w[0][7:0], 8'h40 ^ 8'h00);   // 0x40^0x00 low byte = 0x40
    chk("half store @0x46", w[1][31:16], 16'hCDEF);

    // ------------------------------------------------------------------ [8]
    $display("[8] CROSS-LINE straddle store -> two-line split (phase0 + phase1)");
    rd_check_line("pre L @0xE00", 32'h0000_0E00, 32'hC0DE_0000);
    rd_check_line("pre L+1 @0xE20", 32'h0000_0E20, 32'hC0DE_0000);
    l2_write(32'h0000_0E1E, 32'h4433_2211, 4'hF);            // line-byte 30: bytes 30,31 | 32,33
    l2_read(32'h0000_0E00, w);
    chk("straddle low half in L word7 byte30:31", w[7][31:16], 16'h2211);
    l2_read(32'h0000_0E20, w);
    chk("straddle high half in L+1 word0 byte0:1", w[0][15:0], 16'h4433);
    chk("L+1 word0 byte2:3 untouched", w[0][31:16], 16'(((32'h0E20)^32'hC0DE_0000) >> 16));

    // ------------------------------------------------------------------ [9]
    $display("[9] same flows with downstream LATENCY (DLY=3): FSM tolerates DDR latency");
    DLY = 3;
    r0=ddr_rd; rd_check_line("lat cold@0x1040", 32'h0000_1040, 32'hC0DE_0000);
    chk_int("DDR reads (latency fill)", ddr_rd-r0, 8);
    r0=ddr_rd; rd_check_line("lat hit@0x1040", 32'h0000_1040, 32'hC0DE_0000);
    chk_int("DDR reads (latency hit == 0)", ddr_rd-r0, 0);
    l2_write(32'h0000_1044, 32'hA5A5_5A5A, 4'hF);
    l2_read(32'h0000_1040, w);
    chk("latency write-hit read-back", w[1], 32'hA5A5_5A5A);
    DLY = 0;

    // ------------------------------------------------------------------ [10]
    $display("[10] single-outstanding: a u_req HELD past its ack runs exactly ONCE");
    l2_read(32'h0000_0040, w);                       // make 0x40 resident (write will hit)
    begin
      int acks, guard;
      @(negedge clk); u_req<=1'b1; u_we<=1'b1; u_addr<=32'h0000_0044;
                      u_wdata<=32'h1111_2222; u_wstrb<=4'hF;
      acks=0; guard=0;
      forever begin                                   // HOLD u_req high for 20 clocks
        @(posedge clk); #1;
        if (u_ack) acks++;
        if (++guard >= 20) break;
      end
      @(negedge clk); u_req<=1'b0; u_we<=1'b0;
      chk_int("held-req write acked exactly once (not re-executed)", acks, 1);
    end
    dquiesce();
    l2_read(32'h0000_0040, w); chk("held-req store landed once @0x44", w[1], 32'h1111_2222);

    // ------------------------------------------------------------------ [11]
    $display("[11] empty phase-0 straddle store: line L stays CLEAN (dirty == modified)");
    // store at line-byte 31 with byte0 UNstrobed → every strobed byte spills into L+1,
    // so line L must NOT be allocated/dirtied (else evicting it spuriously writes back).
    rd_check_line("L@0x100", 32'h0000_0100, 32'hC0DE_0000);   // set 8, way A, clean
    l2_write(32'h0000_011F, 32'h4433_2211, 4'b1110);          // bytes 1..3 → 0x120 (L+1)
    l2_read(32'h0000_0120, w);                                // L+1 got the spilled bytes
    chk("spill -> 0x120 byte0", w[0][7:0],   8'h22);
    chk("spill -> 0x120 byte1", w[0][15:8],  8'h33);
    chk("spill -> 0x120 byte2", w[0][23:16], 8'h44);
    w0=ddr_wr;
    rd_check_line("M@0x300", 32'h0000_0300, 32'hC0DE_0000);   // set 8, way B
    rd_check_line("N@0x500", 32'h0000_0500, 32'hC0DE_0000);   // evicts LRU == 0x100
    chk_int("NO writeback evicting the untouched line L (dirty==modified)", ddr_wr-w0, 0);

    // COVERAGE sweep: walk data / byte-strobe / address through the L2 data
    // buffers (wd1/nwd1/be1/nbe1 store path, fill_buf on miss, wb_buf on dirty
    // eviction). l2_read/l2_write don't check values -> pure toggle stimulus.
    $display("[COV] L2 buffer sweep: walking data/strb/addr + dirty evictions");
    for (int i=0;i<64;i++) begin
      automatic logic [31:0] s = 32'(i) * 32'h20;
      l2_write(s,            32'h1 << (i%32),       4'hF);                 // wd1 walking data
      l2_write(s + 32'h4,    ~(32'h1 << (i%32)),    4'((1 << (i%4)) | 1));// nwd1 + varied byte strobe (be1/nbe1)
      l2_read (s + 32'h2000, w);                                          // 2nd tag -> fill_buf
      l2_read (s + 32'h4000, w);                                          // 3rd tag -> evict DIRTY -> wb_buf
      l2_read (s,            w);                                          // refill
    end
    for (int i=0;i<32;i++) l2_write(32'h0000_0040 + 32'(i)*4, 32'h1 << i, 4'hF);  // walking data in a line
    for (int i=5;i<16;i++) l2_read (32'h1 << i, w);                       // walking-bit tag addresses

    // [COV] cross-line straddle stores with diverse data + spill amounts (offsets
    //       29/30/31 -> 3/2/1 bytes into L+1) so the second-line write path
    //       (wd1/be1/nwd1/nbe1, the spilled bytes) toggles. Placed last (no later
    //       check) since these leave straddled lines dirty -- pure toggle stimulus.
    for (int ln=0; ln<24; ln++)
      for (int off=29; off<32; off++)
        l2_write(32'h0000_2000 + 32'(ln)*32 + 32'(off),
                 (32'h0101_0101 << (ln & 7)) ^ 32'(ln*32'h0204_0801), 4'hF);

    if (errors==0) $display("L2-GATE-OK (all checks pass)");
    else           $display("L2-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #2000000; $display("L2-GATE-FAIL (timeout)"); $finish; end
endmodule
