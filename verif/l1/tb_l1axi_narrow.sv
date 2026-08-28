// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_narrow.sv — REVIEW_Aug3 C-01: H-11 narrow (non-cacheable, MMIO)
// reads must survive the WHOLE path: ven_l1d -> (ven_axi_cdc) -> ven_axi_master ->
// AXI slave. Modeled on tb_l1axi_cdc: the real ventium_l1_axi (EN_L2=0, default
// params — the deployed configuration) + axi_slave_bfm, per clock ratio.
//
// The device region needs NO defines: C-01's D-side ven_cachemap (u_cmap_dc) marks
// the VGA aperture 0xA0000-0xBFFFF non-cacheable in the DEFAULT build, so reads
// there take ven_l1d's bypass -> a 1- or 2-beat narrow AXI burst. The BFM models
// the aperture as READ-TO-CLEAR (RTC window), so a DUPLICATED device access is
// observable in the returned data, and counts AR handshakes / R beats so the TB can
// assert the exact transaction shape. Per architectural read it checks:
//   * exactly ONE AR (a fill CONTROL below costs two — priming retained for fills);
//   * exact ARADDR (the requested WORD, not a line base), ARLEN (0 or 1), ARSIZE=4B;
//   * the R beat count (1 aligned / 2 straddling) and RLAST acceptance (a
//     mis-validated RLAST sets the master's sticky rlast_err -> bus_err, checked at
//     the end; the rlast_align/ar_align/ar_4k SVAs run under --assert);
//   * the served little-endian dword window at the byte address;
//   * RTC: a seeded word returns the seed on the FIRST read (before the C-01 priming
//     fix the discarded priming burst consumed the seed and the delivered burst
//     returned 0) and 0 on the SECOND architectural read (cleared; no stale L1 copy —
//     a narrow read allocates nothing, so the second read is a fresh AR).
// Before C-01 this failed three ways: rlast_err on the first compliant 1-beat
// response (sticky bus_err), two ARs per narrow read (priming), and — under
// VEN_AXI_CDC — a beat-count deadlock / unsynchronized narrow metadata.
//
// Builds: (a) direct single-clock (run-l1axi-narrow-gate.sh, no defines — one
// equal-clock harness; without the CDC the master runs IN core_clk, so skewed clocks
// would be meaningless); (b) +VEN_AXI_CDC, the four ratios of the CDC gate.
// Prints L1AXINARROW-GATE-OK / L1AXINARROW-GATE-FAIL.

// ----------------------------------------------------------------------------
// one ratio: clocks, DUT(+CDC when defined), RTC-capable slave, scenario.
// ----------------------------------------------------------------------------
module narrow_harness #(
    parameter int    CORE_HALF = 5,    // core_clk half-period
    parameter int    AXI_HALF  = 2,    // axi_clk  half-period
    parameter string TAG       = "?"
) (
    output logic       done,
    output int         errs
);
  logic ic_nocache_unused;   // REVIEW2_aug2 H-13
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;
  localparam int          ADDR_W     = 40;

  // the "device" aperture: the VGA window, non-cacheable by the DEFAULT D-side
  // cachemap (u_cmap_dc) — no defines required. DVGA = the same window DDR-side.
  localparam logic [31:0] VGA  = 32'h000A_0000;
  localparam logic [39:0] DVGA = REMAP_BASE + 40'h000A_0000;

  logic core_clk=0, axi_clk=0, core_rst_n=0, axi_rst_n=0;
  always #(CORE_HALF) core_clk = ~core_clk;
  always #(AXI_HALF)  axi_clk  = ~axi_clk;

  // core side
  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        bus_err; logic flush = 1'b0;

  // AXI master <-> slave
  logic [3:0]        awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]        awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]        awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0]       wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]        bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]        arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]        arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]        arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]        rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK)) dut (
      .core_clk(core_clk), .core_rst_n(core_rst_n), .axi_clk(axi_clk), .axi_rst_n(axi_rst_n),
      .flush_all(flush), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .smm_active(1'b0),
      .smbase(32'h0003_0000), .smm_flush_o(), .core_lock(1'b0), .core_lin(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack),
      .core_ic_nocache (ic_nocache_unused), .bus_err(bus_err), .cr0_cd(1'b0),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
      .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache),
      .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
      .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
      .m_axi_bready(bready), .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
      .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_rid(rid), .m_axi_rdata(rdata),
      .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  // the slave runs in the AXI clock domain. The RTC window makes the aperture
  // read-to-clear; ar_count/burst_beats are the transaction-shape monitor.
  logic [31:0] ar_count, burst_beats;
  axi_slave_bfm #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .RD_LAT(4), .WR_LAT(3),
                  .BUBBLE(1), .RTC_LO(VGA), .RTC_HI(32'h000B_FFFF)) slv (
      .clk(axi_clk), .rst_n(axi_rst_n),
      .ar_count(ar_count), .burst_beats(burst_beats),
      .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
      .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
      .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
      .arvalid(arvalid), .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp),
      .rlast(rlast), .rvalid(rvalid), .rready(rready)
  );

  // AR shape monitor: latch the payload of the last THREE AR handshakes. The DUT
  // is single-outstanding and the TB runs one architectural access at a time, so
  // after an access completes these describe ITS transactions (for a primed fill
  // the two ARs are identical, so the last one is representative). R2-H01: an
  // unaligned device read is up to THREE single-beat pieces.
  logic [ADDR_W-1:0] mon_araddr, mon_araddr2, mon_araddr3;
  logic [7:0]        mon_arlen;
  logic [2:0]        mon_arsize, mon_arsize2, mon_arsize3;
  always @(posedge axi_clk)
    if (arvalid && arready) begin
      mon_araddr3 <= mon_araddr2; mon_arsize3 <= mon_arsize2;
      mon_araddr2 <= mon_araddr;  mon_arsize2 <= mon_arsize;
      mon_araddr <= araddr; mon_arlen <= arlen; mon_arsize <= arsize;
    end

  task automatic chk(input string what, input logic [63:0] got, exp);
    if (got !== exp) begin $display("  FAIL [%s] %s: got %08x exp %08x", TAG, what, got, exp); errs++; end
  endtask

  // core READ to `a`, spin to c_ack (multi-cycle miss / narrow bypass), return data.
  // be = the byte enables the core presents (R2-H01: they size the narrow read).
  task automatic do_read(input logic [31:0] a, input logic [3:0] be, output logic [31:0] d);
    int guard;
    @(negedge core_clk); c_req<=1'b1; c_we<=1'b0; c_addr<=a; c_wstrb<=be;
    guard=0;
    forever begin
      @(posedge core_clk); #1;
      if (c_ack) begin d = c_rdata; break; end
      if (++guard > 5000) begin $display("  FAIL [%s] read %08x: no ack", TAG, a); errs++; d=32'hx; break; end
    end
    @(negedge core_clk); c_req<=1'b0; c_wstrb<=4'd0;
  endtask

  // ONE architectural read + the full transaction-shape contract: exact data, the
  // exact piece ARs (addresses + ARSIZE, each single-beat), and the AR count.
  // R2-H01 shapes: aligned dword = 1 piece (ARSIZE=2); byte/word = 1 piece
  // (ARSIZE 0/1); an unaligned dword = 2-3 aligned pieces.
  task automatic dev_read(input string what,
                          input logic [31:0] a, input logic [3:0] be,
                          input logic [31:0] exp_data,
                          input logic [39:0] exp_araddr,
                          input logic [2:0]  exp_arsize,
                          input int          exp_ar);
    logic [31:0] d; logic [31:0] ar0;
    ar0 = ar_count;
    do_read(a, be, d);
    chk({what, " data"},      64'(d),                      64'(exp_data));
    chk({what, " ARADDR"},    64'(mon_araddr),             64'(exp_araddr));
    chk({what, " ARLEN"},     64'(mon_arlen),              64'd0);   // every piece is single-beat
    chk({what, " ARSIZE"},    64'(mon_arsize),             64'(exp_arsize));
    chk({what, " R beats"},   64'(burst_beats),            64'd1);
    chk({what, " AR count"},  64'(ar_count - ar0),         64'(exp_ar));
  endtask

  // a THREE-piece read (unaligned dword): check all three piece ARs.
  task automatic dev_read3(input string what,
                           input logic [31:0] a,
                           input logic [31:0] exp_data,
                           input logic [39:0] a1, a2, a3,
                           input logic [2:0]  s1, s2, s3);
    logic [31:0] d; logic [31:0] ar0;
    ar0 = ar_count;
    do_read(a, 4'hF, d);
    chk({what, " data"},     64'(d),              64'(exp_data));
    chk({what, " AR count"}, 64'(ar_count - ar0), 64'd3);
    chk({what, " p1 ARADDR"}, 64'(mon_araddr3),   64'(a1));
    chk({what, " p1 ARSIZE"}, 64'(mon_arsize3),   64'(s1));
    chk({what, " p2 ARADDR"}, 64'(mon_araddr2),   64'(a2));
    chk({what, " p2 ARSIZE"}, 64'(mon_arsize2),   64'(s2));
    chk({what, " p3 ARADDR"}, 64'(mon_araddr),    64'(a3));
    chk({what, " p3 ARSIZE"}, 64'(mon_arsize),    64'(s3));
    chk({what, " p3 ARLEN"},  64'(mon_arlen),     64'd0);
  endtask

  // (re)seed the aperture's first four words — every preceding read in the RTC
  // window has cleared what it touched.
  task automatic seed_vga;
    slv.poke(VGA+32'h0, 32'h1122_3344);
    slv.poke(VGA+32'h4, 32'hC001_D00D);
    slv.poke(VGA+32'h8, 32'h5566_7788);
    slv.poke(VGA+32'hC, 32'h99AA_BBCC);
  endtask

  // (re)seed the 4 KiB-edge words: the last word of one page and the first of the
  // next (0xA0FFC / 0xA1000, both inside the non-cacheable aperture).
  task automatic seed_edge;
    slv.poke(VGA+32'hFFC,  32'hDEAD_BEEF);
    slv.poke(VGA+32'h1000, 32'hCAFE_F00D);
  endtask

  logic [31:0] d; logic [31:0] ar0;
  initial begin
    errs=0; done=1'b0;
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    mon_araddr='0; mon_arlen='0; mon_arsize='0;
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    // hold both raw resets low, release, then let the per-domain reset syncs settle.
    repeat(10) @(posedge core_clk);
    @(negedge core_clk); core_rst_n<=1'b1;
    @(negedge axi_clk);  axi_rst_n<=1'b1;
    repeat(8) @(posedge core_clk);

    // [1] ALIGNED dword device read, READ-TO-CLEAR: the FIRST read must return the
    //     seed (before the C-01 priming fix, the discarded priming burst consumed
    //     the seed and the DELIVERED burst returned 0) — exactly ONE AR, at the
    //     requested word, ARLEN=0. The word must be cleared afterwards, and the
    //     SECOND architectural read returns 0 through ANOTHER single AR (a narrow
    //     read allocates nothing — no stale L1 copy can serve it).
    seed_vga;
    dev_read("rtc dword @A0004", VGA+32'h4, 4'hF, 32'hC001_D00D,
             DVGA+40'h4, 3'd2, 1);
    chk("rtc cleared the word", 64'(slv.peek(VGA+32'h4)), 64'd0);
    dev_read("rtc re-read @A0004", VGA+32'h4, 4'hF, 32'h0000_0000,
             DVGA+40'h4, 3'd2, 1);

    // [2] REVIEW1_Aug3 R2-H01: EXACT-SIZE device reads. A byte or word read is ONE
    //     single-beat piece at its own ARSIZE (the adjacent word is never touched);
    //     an unaligned dword is aligned power-of-two pieces. The served window is
    //     the little-endian dword at the byte address, unpicked bytes zero.
    //       mem: A0000-3 = 44 33 22 11 ; A0004-7 = 0D D0 01 C0 ; A0008-B = 88 77 66 55
    //       (so byte @A0001 = 0x33, word @A0002 = 0x1122, dword @A0003 = 0x01D00D11)
    seed_vga;
    dev_read("byte @A0001", VGA+32'h1, 4'b0010, 32'h0000_0033, DVGA+40'h1, 3'd0, 1);
    seed_vga;
    dev_read("word @A0002", VGA+32'h2, 4'b1100, 32'h0000_1122, DVGA+40'h2, 3'd1, 1);
    seed_vga;
    dev_read3("dword @A0003", VGA+32'h3, 32'h01D0_0D11,
              DVGA+40'h3, DVGA+40'h4, DVGA+40'h6, 3'd0, 3'd1, 3'd0);

    // [2c] a WORD at an ODD byte offset (bytes 1-2, strobe 0110): a single 2B
    //      piece would sit at an odd address, which violates size alignment --
    //      the full-PC cosim's ar_align assertion caught exactly this on a
    //      VGA-ROM word read. It must be TWO single-byte pieces.
    //        mem: A0000-3 = 44 33 22 11  (word @A0001 = 0x2233)
    seed_vga;
    ar0 = ar_count;
    do_read(VGA+32'h1, 4'b0110, d);
    chk("odd word data",     64'(d),              64'h0000_2233);
    chk("odd word AR count", 64'(ar_count - ar0), 64'd2);
    chk("odd word p1 ARADDR", 64'(mon_araddr2),   64'(DVGA+40'h1));
    chk("odd word p1 ARSIZE", 64'(mon_arsize2),   64'd0);
    chk("odd word p2 ARADDR", 64'(mon_araddr),    64'(DVGA+40'h2));
    chk("odd word p2 ARSIZE", 64'(mon_arsize),    64'd0);

    // [2b] REVIEW1_Aug3 R2-H01, 4 KiB EDGE: the pieces are size-aligned and <=4
    //      bytes, so NO transaction ever crosses a 4 KiB boundary (AXI rule) --
    //      a dword at the last three bytes of a page is byte/word pieces whose
    //      last piece is its own AR on the next page. Every offset of the last
    //      word, plus the aligned control.
    //        mem: A0FFC-FFF = EF BE AD DE ; A1000-3 = 0D F0 FE CA
    seed_edge;
    dev_read3("edge dword @A0FFD", VGA+32'hFFD, 32'h0DDE_ADBE,
              DVGA+40'hFFD, DVGA+40'hFFE, DVGA+40'h1000, 3'd0, 3'd1, 3'd0);
    seed_edge;
    dev_read("edge dword @A0FFE", VGA+32'hFFE, 4'hF, 32'hF00D_DEAD,
             DVGA+40'h1000, 3'd1, 2);
    seed_edge;
    dev_read3("edge dword @A0FFF", VGA+32'hFFF, 32'hFEF0_0DDE,
              DVGA+40'hFFF, DVGA+40'h1000, DVGA+40'h1002, 3'd0, 3'd1, 3'd0);
    // control: the aligned last word is a SINGLE 4B piece.
    seed_edge;
    dev_read("edge aligned @A0FFC", VGA+32'hFFC, 4'hF, 32'hDEAD_BEEF,
             DVGA+40'hFFC, 3'd2, 1);

    // [3] CONTROL — a CACHEABLE fill (DOS region) is untouched by the narrow work:
    //     still exactly TWO ARs (the priming double-read is retained for fills),
    //     ARLEN=7, 32B-aligned base, 8 beats; and a re-read HITS with NO further AR.
    for (int w=0; w<8; w++)
      slv.poke(32'h0000_1000+32'(w)*4, (32'h0000_1000+32'(w)*4) ^ 32'hA5A5_0000);
    ar0 = ar_count;
    do_read(32'h0000_1004, 4'hF, d);
    chk("fill data", 64'(d), 64'hA5A5_1004);
    chk("fill ARs (priming pair)", 64'(ar_count - ar0), 64'd2);
    chk("fill ARADDR (line base)", 64'(mon_araddr), 64'(REMAP_BASE + 40'h0000_1000));
    chk("fill ARLEN", 64'(mon_arlen), 64'd7);
    chk("fill ARSIZE", 64'(mon_arsize), 64'd2);
    chk("fill R beats", 64'(burst_beats), 64'd8);
    ar0 = ar_count;
    do_read(32'h0000_1004, 4'hF, d);
    chk("fill re-hit data", 64'(d), 64'hA5A5_1004);
    chk("fill re-hit: no new AR", 64'(ar_count - ar0), 64'd0);

    // [4] no sticky fault may have fired anywhere above — before the C-01 RLAST fix,
    //     the FIRST compliant 1-beat response set rlast_err -> bus_err.
    chk("bus_err stays 0", 64'(bus_err), 64'd0);

    if (errs==0) $display("  ok  [%s] all narrow-read checks pass", TAG);
    done <= 1'b1;
  end
endmodule

// ----------------------------------------------------------------------------
// top: the deployed direct build runs ONE equal-clock harness; the CDC build runs
// the four clock ratios of tb_l1axi_cdc.
// ----------------------------------------------------------------------------
module tb_l1axi_narrow;
`ifdef VEN_AXI_CDC
  logic d0,d1,d2,d3; int e0,e1,e2,e3;
  // axi 2.5x faster than core (the intended MMCM case: slow core, fast PS-DDR link)
  narrow_harness #(.CORE_HALF(5), .AXI_HALF(2), .TAG("axi-fast 5:2"))  h0(.done(d0),.errs(e0));
  // axi slower than core (stress the other direction)
  narrow_harness #(.CORE_HALF(2), .AXI_HALF(5), .TAG("axi-slow 2:5"))  h1(.done(d1),.errs(e1));
  // equal rate (degenerate; must also hold)
  narrow_harness #(.CORE_HALF(4), .AXI_HALF(4), .TAG("equal 4:4"))     h2(.done(d2),.errs(e2));
  // coprime skew 5:3
  narrow_harness #(.CORE_HALF(5), .AXI_HALF(3), .TAG("coprime 5:3"))   h3(.done(d3),.errs(e3));

  initial begin
    wait (d0 && d1 && d2 && d3);
    if (e0+e1+e2+e3 == 0)
      $display("L1AXINARROW-GATE-OK (C-01 narrow reads exact across axi-fast/slow/equal/coprime)");
    else
      $display("L1AXINARROW-GATE-FAIL (%0d errors)", e0+e1+e2+e3);
    $finish;
  end
`else
  // without VEN_AXI_CDC the AXI master runs IN core_clk, so skewed clocks are not a
  // meaningful configuration — one equal-clock harness proves the direct path.
  logic d0; int e0;
  narrow_harness #(.CORE_HALF(5), .AXI_HALF(5), .TAG("direct 1:1")) h0(.done(d0),.errs(e0));

  initial begin
    wait (d0);
    if (e0 == 0) $display("L1AXINARROW-GATE-OK (C-01 narrow reads exact, direct single-clock)");
    else         $display("L1AXINARROW-GATE-FAIL (%0d errors)", e0);
    $finish;
  end
`endif
  initial begin #4000000; $display("L1AXINARROW-GATE-FAIL (timeout — hang)"); $finish; end
endmodule
