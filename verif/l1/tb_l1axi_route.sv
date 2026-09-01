// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l1axi_route.sv — REVIEW1_Aug3 R2-H02 / R2-H03 / R2-H12 unit gate,
// extended 2026-08-04 for REVIEW_Aug4 A4-M01 (the WINDOWED R_PCI contract).
//
// The three no-L2 memory-contract properties, each in its own harness:
//
//   R2-H02 (harness EXTENT, default params): cacheability is classified from the
//     access EXTENT, not its first byte. A dword at 0x9FFD ends inside the VGA
//     aperture (0xA0000), so it must take the NARROW path (no line fill, no
//     allocation) even though it starts in cacheable DOS RAM. An aligned dword at
//     0x9FF8 (entirely DOS) is the cacheable-fill control. All cachemap region
//     boundaries are 32B-aligned, so fills never straddle; accesses can.
//
//   R2-H03 (harness ROUTER, NB_DRAMC=0x40 -> HEN=01, the 0x80000-0x9FFFF hole):
//     an access to a non-DRAM, non-platform-override region with no device fabric
//     must NOT reach DDR: no AR at all, a local ack (no hang), rdata=0, and the
//     sticky route_err drives bus_err. DOS keeps working (the router is not a
//     blanket). (The old "R_PCI >=TOM is ALWAYS DDR" expectation was RETIRED by
//     A4-M01: region 6 is DDR only inside the declared RAM window or the BIOS
//     shadow -- the R6WIN harness below carries the reconciled cases.)
//
//   R2-H12 (harness CDEFF, cr0_cd=1): with CR0.CD set, a read of CACHEABLE DOS RAM
//     is a narrow 1-beat access (NO line fill / allocation), and a SECOND read of
//     the same word costs ANOTHER AR (nothing was cached). cr0_cd=0 behavior is
//     the harness-EXTENT control above.
//
//   A4-M01 (harnesses R6WIN / R6KV, the windowed R_PCI contract): region 6
//     (>= TOM) routes to DDR ONLY inside ((addr & ~ADDR_MASK) == 0) -- the
//     declared RAM window -- or the top-of-4G BIOS shadow (>= 0xFFFE_0000);
//     anything else in region 6 takes the loud route_err path (suppressed, no
//     DDR transaction, sticky route_err -> bus_err). R6WIN runs the TB's stock
//     1 GiB mask (ADDR_MASK=0x3FFF_FFFF, TOM = 255*4 MiB = 0x3FC0_0000): below-
//     TOM DOS control, in-window region-6, BOTH shadow pages, a fully-inside
//     straddle at 0x3FFF_FFFC (DDR), an out-of-window region-6 access at
//     0x5000_0004 (loud), a straddle OUT of the window at 0x3FFF_FFFE (loud --
//     the extent check classifies by the LAST byte), and the RECONCILED old
//     case at 0x4000_0004 (was "inside the fold mask -> must NOT route_err"
//     under the retired always-DDR contract; above the 1 GiB mask and outside
//     the shadow it is now correctly LOUD). R6KV mimics the KV260 fold
//     (ADDR_MASK=0x0FFF_FFFF = 256 MiB, NB_TOM_MB4=60 so TOM=0x0F00_0000 puts
//     a region-6 band inside the carveout): in-carveout region-6 -> DDR,
//     above-carveout non-shadow region-6 -> loud, BIOS shadow -> DDR. These
//     two harnesses use an address-patterned mini read-slave (no backing
//     array: the region-6/shadow addresses sit far above axi_slave_bfm's 1 MiB
//     window).
//
// Byte/word endpoint coverage (added 2026-08-05): every cachemap policy boundary
// is exercised with 1-, 2-, and 4-byte accesses in four positions relative to
// the boundary B -- wholly below (last byte B-1), ending exactly at B-1,
// beginning exactly at B, and straddling B -- for BOTH reads and writes:
//   * extent harness: the VGA aperture edges (0xA0000, 0xC0000). A sub-word
//     access ending at B-1 touches no aperture byte, so it must take the
//     cacheable fill path (a fill + a hit re-read), not the narrow path; the
//     aperture side must be byte-exact narrow pieces, never allocated.
//   * router harness: the hole edges (0x80000, 0xA0000). Below/above sides
//     must be untouched by the hole; any access whose extent touches the hole
//     is denied as a whole (local ack, no bus transaction, sticky route_err).
//   * pardeny harness (NB_PAM with PAM1=0x07: 0xC0000-0xC3FFF enabled R/W/CE,
//     0xC4000-0xC7FFF disabled): a byte/word read ending at 0xC3FFF is wholly
//     inside the enabled window and must be an ordinary cacheable fill; the
//     disabled side denies by extent, like the hole.
//   * r6win/r6kv: TOM, the ADDR_MASK RAM-window edge, and the BIOS-shadow edge
//     with byte/word shapes, reads AND writes (the mini slave grows a write
//     channel for the AW/wstrb shape checks).
// Reads drive the compact size strobes the core produces (1=byte, 3=word,
// F=dword): the last touched byte is addr + highest_strobe, and a strobe'd
// access is classified by ITS OWN extent -- never by the 4-byte window its
// address happens to sit in (that window survives only for the legacy
// strobe-less read form). The L1's line-spill test uses the same real extent,
// so a byte/word ending exactly at B-1 (always 32B-line-aligned, so its own
// bytes never cross the line end) fills exactly ONE line -- it never pulls a
// denied region's line (the hole line, a disabled-PAM line) into the cache.
//
// Prints L1AXIROUTE-GATE-OK / FAIL. Build: run-l1axi-route-gate.sh (same style as
// run-l1axi-narrow-gate.sh; +define+AXI_BFM_MON for the AR monitor).

module route_harness #(
    parameter int          CORE_HALF = 5,
    parameter int          AXI_HALF  = 2,
    parameter string       TAG       = "?",
    parameter logic [7:0]  NB_DRAMC_P = 8'h01,   // 0x40 -> HEN=01 (hole 80000-9FFFF)
    parameter logic        CD_P       = 1'b0,
    // stock: every ROM window R/W + cacheable. pardeny: PAM1=0x07 -> the
    // 0xC0000-0xC3FFF window stays enabled, 0xC4000-0xC7FFF is disabled.
    parameter logic [55:0] NB_PAM_P   = 56'h77_7777_7777_7770
) (
    output logic       done,
    output int         errs
);
  logic ic_nocache_unused;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam logic [31:0] ADDR_MASK  = 32'h3FFF_FFFF;
  localparam int          ADDR_W     = 40;

  logic core_clk=0, axi_clk=0, core_rst_n=0, axi_rst_n=0;
  always #(CORE_HALF) core_clk = ~core_clk;
  always #(AXI_HALF)  axi_clk  = ~axi_clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        bus_err, m_idle; logic flush = 1'b0;

  logic [3:0]        awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]        awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]        awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0]       wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]        bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]        arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]        arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]        arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]        rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK),
                   .NB_DRAMC(NB_DRAMC_P), .NB_PAM(NB_PAM_P)) dut (
      .core_clk(core_clk), .core_rst_n(core_rst_n), .axi_clk(axi_clk), .axi_rst_n(axi_rst_n),
      .flush_all(flush), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(m_idle),
      .core_req(c_req), .core_we(c_we), .core_addr(c_addr), .smm_active(1'b0),
      .smbase(32'h0003_0000), .smm_flush_o(), .core_lock(1'b0), .core_lin(c_addr), .core_wdata(c_wdata),
      .core_wstrb(c_wstrb), .core_rdata(c_rdata), .core_ack(c_ack),
      .core_ic_nocache (ic_nocache_unused), .bus_err(bus_err), .cr0_cd(CD_P),
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

  logic [31:0] ar_count, burst_beats;
  axi_slave_bfm #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .RD_LAT(4), .WR_LAT(3),
                  .BUBBLE(1)) slv (
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
  // after an access completes these describe ITS transactions (a strobe'd narrow
  // read is up to three single-beat pieces; a fill's priming pair is identical).
  logic [ADDR_W-1:0] mon_araddr, mon_araddr2, mon_araddr3;
  logic [7:0]        mon_arlen;
  logic [2:0]        mon_arsize, mon_arsize2, mon_arsize3;
  always @(posedge axi_clk)
    if (arvalid && arready) begin
      mon_araddr3 <= mon_araddr2; mon_arsize3 <= mon_arsize2;
      mon_araddr2 <= mon_araddr;  mon_arsize2 <= mon_arsize;
      mon_araddr <= araddr; mon_arlen <= arlen; mon_arsize <= arsize;
    end

  // AW shape monitor: a core store is one single-beat write, or two when its
  // strobes straddle a word boundary. Latch the last two AW payloads and the
  // W strobes that accompanied them.
  logic [31:0]       aw_count;
  logic [ADDR_W-1:0] mon_awaddr, mon_awaddr2;
  logic [2:0]        mon_awsize;
  logic [3:0]        mon_wstrb, mon_wstrb2;
  always @(posedge axi_clk) begin
    if (!axi_rst_n) aw_count <= 32'd0;
    else if (awvalid && awready) begin
      aw_count <= aw_count + 32'd1;
      mon_awaddr2 <= mon_awaddr; mon_wstrb2 <= mon_wstrb;
      mon_awaddr <= awaddr; mon_awsize <= awsize;
    end
    if (wvalid && wready) mon_wstrb <= wstrb;
  end

  task automatic chk(input string what, input logic [63:0] got, exp);
    if (got !== exp) begin $display("  FAIL [%s] %s: got %08x exp %08x", TAG, what, got, exp); errs++; end
  endtask

  // core READ to `a` with byte-enable `be` (the compact size strobes the core
  // drives: 1=byte, 3=word, F=dword; 0 = the legacy whole-word form).
  task automatic do_read_be(input logic [31:0] a, input logic [3:0] be, output logic [31:0] d);
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

  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    do_read_be(a, 4'hF, d);
  endtask

  // core WRITE: wdata/wstrb are lane-0-justified at the byte address (the byte
  // at `a` is lane 0); a straddling store reaches the bus as two single beats.
  task automatic do_write(input logic [31:0] a, input logic [31:0] wdata, input logic [3:0] be);
    int guard;
    @(negedge core_clk); c_req<=1'b1; c_we<=1'b1; c_addr<=a; c_wdata<=wdata; c_wstrb<=be;
    guard=0;
    forever begin
      @(posedge core_clk); #1;
      if (c_ack) break;
      if (++guard > 5000) begin $display("  FAIL [%s] write %08x: no ack", TAG, a); errs++; break; end
    end
    @(negedge core_clk); c_req<=1'b0; c_we<=1'b0; c_wstrb<=4'd0;
  endtask

  // Stores are acknowledged at P54C queue admission, not at external AXI
  // completion. Wait for the exported drain signal before examining external
  // write effects; otherwise this test observes a previous posted store.
  task automatic wait_axi_drain(input string what);
    int guard;
    guard = 0;
    forever begin
      @(posedge core_clk); #1;
      if (m_idle) break;
      if (++guard > 5000) begin
        $display("  FAIL [%s] AXI write queue did not drain", TAG);
        errs++;
        break;
      end
    end
  endtask

  task automatic do_flush;
    @(negedge core_clk); flush<=1'b1;
    @(negedge core_clk); flush<=1'b0;
    repeat (2) @(posedge core_clk);
  endtask

  // ---- boundary-case helpers -------------------------------------------------
  // cacheable-side read: after a flush the access must MISS into a line fill
  // (the priming pair of 8-beat ARs at the line base), and the re-read must HIT
  // with no further AR. `msk` trims the served window for sub-word reads whose
  // upper bytes belong to the next line.
  task automatic rd_fill(input string what, input logic [31:0] a, input logic [3:0] be,
                         input logic [31:0] msk, input logic [31:0] exp_data,
                         input logic [39:0] exp_line);
    logic [31:0] ar0;
    do_flush;
    ar0 = ar_count;
    do_read_be(a, be, d);
    chk({what, " data"},               64'(d & msk),          64'(exp_data));
    chk({what, ": fill ARs"},          64'(ar_count - ar0),   64'd2);
    chk({what, ": fill ARLEN"},        64'(mon_arlen),        64'd7);
    chk({what, ": fill ARADDR (line)"},64'(mon_araddr),       64'(exp_line));
    ar0 = ar_count;
    do_read_be(a, be, d);
    chk({what, ": re-read data"},      64'(d & msk),          64'(exp_data));
    chk({what, ": re-read ARs (hit)"}, 64'(ar_count - ar0),   64'd0);
  endtask

  // non-cacheable-side read: exactly ONE single-beat piece AR at the byte
  // address and ARSIZE of the access, and NO allocation (the re-read costs
  // another AR).
  task automatic rd_narrow(input string what, input logic [31:0] a, input logic [3:0] be,
                           input logic [31:0] exp_data, input logic [39:0] exp_axi,
                           input logic [2:0] exp_size);
    logic [31:0] ar0;
    ar0 = ar_count;
    do_read_be(a, be, d);
    chk({what, " data"},                    64'(d),              64'(exp_data));
    chk({what, ": ONE piece AR"},           64'(ar_count - ar0), 64'd1);
    chk({what, ": piece ARLEN"},            64'(mon_arlen),      64'd0);
    chk({what, ": piece ARSIZE"},           64'(mon_arsize),     64'(exp_size));
    chk({what, ": piece ARADDR"},           64'(mon_araddr),     64'(exp_axi));
    ar0 = ar_count;
    do_read_be(a, be, d);
    chk({what, ": re-read ARs (not cached)"}, 64'(ar_count - ar0), 64'd1);
  endtask

  // denied read: local ack, rdata=0, NO AR at all, and the sticky route error
  // drives bus_err.
  task automatic rd_loud(input string what, input logic [31:0] a, input logic [3:0] be);
    logic [31:0] ar0;
    ar0 = ar_count;
    do_read_be(a, be, d);
    chk({what, ": local ack rdata=0"}, 64'(d),              64'd0);
    chk({what, ": NO AR"},            64'(ar_count - ar0), 64'd0);
    chk({what, ": route_err -> bus_err"}, 64'(bus_err),    64'd1);
  endtask

  // write that must reach the backing: exact AW count, and the byte-visible
  // result in the slave's store (phys = the word to peek).
  task automatic wr_ok(input string what, input logic [31:0] a, input logic [31:0] wdata,
                       input logic [3:0] be, input int exp_aw,
                       input logic [31:0] phys, input logic [31:0] exp_peek);
    logic [31:0] aw0;
    aw0 = aw_count;
    do_write(a, wdata, be);
    wait_axi_drain(what);
    chk({what, ": AW count"},      64'(aw_count - aw0), 64'(exp_aw));
    chk({what, ": backing bytes"}, 64'(slv.peek(phys)), 64'(exp_peek));
  endtask

  // denied write: no AW at all, the backing word is untouched, bus_err set.
  task automatic wr_loud(input string what, input logic [31:0] a, input logic [31:0] wdata,
                         input logic [3:0] be, input logic [31:0] phys, input logic [31:0] exp_peek);
    logic [31:0] aw0;
    aw0 = aw_count;
    do_write(a, wdata, be);
    wait_axi_drain(what);
    repeat (4) @(posedge axi_clk); #1;
    chk({what, ": NO AW"},              64'(aw_count - aw0), 64'd0);
    chk({what, ": backing untouched"},  64'(slv.peek(phys)), 64'(exp_peek));
    chk({what, ": route_err -> bus_err"}, 64'(bus_err),      64'd1);
  endtask

  logic [31:0] d; logic [31:0] ar0;
  initial begin
    errs=0; done=1'b0;
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    mon_araddr='0; mon_araddr2='0; mon_araddr3='0; mon_arlen='0;
    mon_arsize='0; mon_arsize2='0; mon_arsize3='0;
    mon_awaddr='0; mon_awaddr2='0; mon_awsize='0; mon_wstrb='0; mon_wstrb2='0;
    for (int i=0;i<(1<<20);i++) slv.mem[i] = 8'h00;
    for (logic [31:0] a=0; a<32'h100000; a+=4) slv.poke(a, a ^ 32'h5A5A_0000);
    repeat(10) @(posedge core_clk);
    @(negedge core_clk); core_rst_n<=1'b1;
    @(negedge axi_clk);  axi_rst_n<=1'b1;
    repeat(8) @(posedge core_clk);

    if (NB_DRAMC_P == 8'h40) begin
      // ---------------- R2-H03: the hole must NOT reach DDR ----------------
      // Good phase first (the route error is sticky): every access wholly
      // OUTSIDE the 0x80000-0x9FFFF hole must be untouched by it -- including
      // the byte/word shapes whose last byte is 0x7FFFF, which a 4-byte
      // classification window would push INTO the hole.
      do_read(32'h0000_1004, d); chk("DOS read below hole", 64'(d), 64'h5A5A1004);
      chk("pre-hole: no error", 64'(bus_err), 64'd0);
      // below-edge B=0x80000: byte/word ending at B-1 are cacheable DOS fills.
      // Their own extent never crosses their 32B line end, so the fill pulls
      // in exactly ONE line -- never the hole line above it.
      rd_fill  ("hole-lo byte  rd @7FFFF", 32'h0007_FFFF, 4'h1, 32'h0000_00FF, 32'h0000_005A, REMAP_BASE + 40'h7FFE0);
      ar0 = ar_count; do_read_be(32'h0007_FFFE, 4'h3, d);
      chk("hole-lo word  rd @7FFFE data", 64'(d & 32'hFFFF), 64'h5A5D);
      chk("hole-lo word  rd @7FFFE: hit, no AR", 64'(ar_count - ar0), 64'd0);
      ar0 = ar_count; do_read_be(32'h0007_FFFC, 4'hF, d);
      chk("hole-lo dword rd @7FFFC data", 64'(d), 64'h5A5D_FFFC);
      chk("hole-lo dword rd @7FFFC: hit, no AR", 64'(ar_count - ar0), 64'd0);
      // above-edge B=0xA0000: the aperture overrides to DDR, byte-exact narrow.
      rd_narrow("vga-hi  byte  rd @A0000", 32'h000A_0000, 4'h1, 32'h0000_0000, REMAP_BASE + 40'hA0000, 3'd0);
      rd_narrow("vga-hi  word  rd @A0000", 32'h000A_0000, 4'h3, 32'h0000_0000, REMAP_BASE + 40'hA0000, 3'd1);
      rd_narrow("vga-hi  dword rd @A0000", 32'h000A_0000, 4'hF, 32'h5A50_0000, REMAP_BASE + 40'hA0000, 3'd2);
      // writes below the hole and into the aperture all reach the backing.
      wr_ok("hole-lo byte  wr @7FFFF", 32'h0007_FFFF, 32'h0000_00A5, 4'h1, 1, 32'h0007_FFFC, 32'hA55D_FFFC);
      wr_ok("hole-lo word  wr @7FFFE", 32'h0007_FFFE, 32'h0000_C3C3, 4'h3, 1, 32'h0007_FFFC, 32'hC3C3_FFFC);
      wr_ok("hole-lo dword wr @7FFFC", 32'h0007_FFFC, 32'h1234_5678, 4'hF, 1, 32'h0007_FFFC, 32'h1234_5678);
      wr_ok("vga-hi  byte  wr @A0000", 32'h000A_0000, 32'h0000_00A5, 4'h1, 1, 32'h000A_0000, 32'h5A50_00A5);
      wr_ok("vga-hi  word  wr @A0000", 32'h000A_0000, 32'h0000_BEEF, 4'h3, 1, 32'h000A_0000, 32'h5A50_BEEF);
      wr_ok("vga-hi  dword wr @A0000", 32'h000A_0000, 32'hCAFE_CAFE, 4'hF, 1, 32'h000A_0000, 32'hCAFE_CAFE);
      chk("good phase: no error", 64'(bus_err), 64'd0);
      // Loud phase: any access whose extent TOUCHES the hole is denied as a
      // whole -- local ack (no hang), rdata=0, no bus transaction, route_err.
      rd_loud("hole    dword rd @80004", 32'h0008_0004, 4'hF);
      rd_loud("hole    byte  rd @80000", 32'h0008_0000, 4'h1);
      rd_loud("hole    word  rd @80000", 32'h0008_0000, 4'h3);
      rd_loud("hole    byte  rd @9FFFF", 32'h0009_FFFF, 4'h1);
      rd_loud("hole    word  rd @9FFFE", 32'h0009_FFFE, 4'h3);
      rd_loud("hole    dword rd @9FFFC", 32'h0009_FFFC, 4'hF);
      rd_loud("hole strad dword rd @7FFFD", 32'h0007_FFFD, 4'hF);
      rd_loud("hole strad dword rd @9FFFD", 32'h0009_FFFD, 4'hF);
      // a straddling store into the hole is suppressed on BOTH sides of B.
      wr_loud("hole strad word  wr @7FFFF", 32'h0007_FFFF, 32'h0000_E7E7, 4'h3, 32'h0008_0000, 32'h5A52_0000);
      chk("hole strad wr @7FFFF: below bytes untouched", 64'(slv.peek(32'h0007_FFFC)), 64'h1234_5678);
      wr_loud("hole    byte  wr @80000", 32'h0008_0000, 32'h0000_0066, 4'h1, 32'h0008_0000, 32'h5A52_0000);
      wr_loud("hole    dword wr @9FFFC",  32'h0009_FFFC, 32'hDEAD_BEEF, 4'hF, 32'h0009_FFFC, 32'h5A53_FFFC);
      wr_loud("hole strad dword wr @9FFFD", 32'h0009_FFFD, 32'hDEAD_BEEF, 4'hF, 32'h000A_0000, 32'hCAFE_CAFE);
      // a plain DOS access below the hole still works (the router is not a blanket)
      do_read(32'h0000_1004, d); chk("DOS read below hole (post-hole)", 64'(d), 64'h5A5A1004);
    end else if (CD_P) begin
      // ---------------- R2-H12: CR0.CD=1 -> no allocation -------------------
      ar0 = ar_count;
      do_read(32'h0000_1004, d);
      chk("CD=1 read data", 64'(d), 64'h5A5A1004);
      chk("CD=1: ONE narrow AR", 64'(ar_count - ar0), 64'd1);
      chk("CD=1: narrow ARLEN", 64'(mon_arlen), 64'd0);
      chk("CD=1: narrow ARADDR (word)", 64'(mon_araddr), 64'(REMAP_BASE + 40'h1004));
      ar0 = ar_count;
      do_read(32'h0000_1004, d);
      chk("CD=1 re-read data", 64'(d), 64'h5A5A1004);
      chk("CD=1 re-read: ANOTHER AR (nothing cached)", 64'(ar_count - ar0), 64'd1);
    end else if (NB_PAM_P != 56'h77_7777_7777_7770) begin
      // ---------------- the PAM window boundary at 0xC4000 -------------------
      // PAM1=0x07: 0xC0000-0xC3FFF is R/W + cacheable DRAM, 0xC4000-0xC7FFF is
      // disabled (reads AND writes route away from DRAM; with no device fabric
      // in this build that is the loud path). A byte/word access ending at
      // 0xC3FFF touches no disabled byte: it must be an ordinary cacheable
      // fill -- a 4-byte classification window would deny it.
      slv.poke(32'h000B_FFFC, 32'hB106_5678);
      slv.poke(32'h000C_0000, 32'hC001_2ACE);
      slv.poke(32'h000C_3FFC, 32'hC3FC_E000);
      slv.poke(32'h000C_4000, 32'hD15A_B1ED);
      // good phase: the enabled window, its byte/word endpoints, and the VGA
      // aperture just below the PAM region (DDR by platform override). A
      // byte/word read ending at 0xC3FFF never crosses its own 32B line end,
      // so its fill pulls in exactly ONE line -- never the disabled-window
      // line above it.
      rd_fill  ("pam-lo  byte  rd @C0000", 32'h000C_0000, 4'h1, 32'h0000_00FF, 32'h0000_00CE, REMAP_BASE + 40'hC0000);
      rd_fill  ("pam-en  byte  rd @C3FFF", 32'h000C_3FFF, 4'h1, 32'h0000_00FF, 32'h0000_00C3, REMAP_BASE + 40'hC3FE0);
      ar0 = ar_count; do_read_be(32'h000C_3FFE, 4'h3, d);
      chk("pam-en  word  rd @C3FFE data", 64'(d & 32'hFFFF), 64'hC3FC);
      chk("pam-en  word  rd @C3FFE: hit, no AR", 64'(ar_count - ar0), 64'd0);
      ar0 = ar_count; do_read_be(32'h000C_3FFC, 4'hF, d);
      chk("pam-en  dword rd @C3FFC data", 64'(d), 64'hC3FC_E000);
      chk("pam-en  dword rd @C3FFC: hit, no AR", 64'(ar_count - ar0), 64'd0);
      rd_narrow("vga     byte  rd @BFFFF", 32'h000B_FFFF, 4'h1, 32'h0000_00B1, REMAP_BASE + 40'hBFFFF, 3'd0);
      wr_ok("pam-en  byte  wr @C3FFF", 32'h000C_3FFF, 32'h0000_005A, 4'h1, 1, 32'h000C_3FFC, 32'h5AFC_E000);
      wr_ok("pam-en  word  wr @C3FFE", 32'h000C_3FFE, 32'h0000_C3C3, 4'h3, 1, 32'h000C_3FFC, 32'hC3C3_E000);
      wr_ok("pam-en  dword wr @C3FFC", 32'h000C_3FFC, 32'h1234_5678, 4'hF, 1, 32'h000C_3FFC, 32'h1234_5678);
      chk("good phase: no error", 64'(bus_err), 64'd0);
      // loud phase: the disabled window denies by EXTENT -- anything touching
      // 0xC4000-0xC7FFF, including straddles from the enabled side.
      rd_loud("pam-dis byte  rd @C4000", 32'h000C_4000, 4'h1);
      rd_loud("pam-dis word  rd @C4000", 32'h000C_4000, 4'h3);
      rd_loud("pam-dis dword rd @C4000", 32'h000C_4000, 4'hF);
      rd_loud("pam strad word  rd @C3FFF", 32'h000C_3FFF, 4'h3);
      rd_loud("pam strad dword rd @C3FFD",  32'h000C_3FFD, 4'hF);
      wr_loud("pam-dis byte  wr @C4000", 32'h000C_4000, 32'h0000_0066, 4'h1, 32'h000C_4000, 32'hD15A_B1ED);
      wr_loud("pam strad dword wr @C3FFD", 32'h000C_3FFD, 32'hDEAD_BEEF, 4'hF, 32'h000C_3FFC, 32'h1234_5678);
      chk("pam strad wr: disabled side untouched", 64'(slv.peek(32'h000C_4000)), 64'hD15A_B1ED);
      // the enabled window still works after the denied accesses (not a blanket)
      ar0 = ar_count; do_read_be(32'h000C_0000, 4'h1, d);
      chk("pam-lo  byte  rd @C0000 (post-deny) data", 64'(d & 32'hFF), 64'hCE);
    end else begin
      // ---------------- R2-H02: extent classification -----------------------
      // dword at 0x9FF8: entirely DOS -> a CACHEABLE fill (2 priming ARs, ARLEN=7).
      slv.poke(32'h0000_9FF8, 32'h1122_3344);
      slv.poke(32'h0009_FFFC, 32'hA0A1_A2A3);
      slv.poke(32'h000A_0000, 32'hB0B1_B2B3);
      ar0 = ar_count;
      do_read(32'h0000_9FF8, d);
      chk("aligned DOS dword data", 64'(d), 64'h11223344);
      chk("aligned DOS dword: fill ARs", 64'(ar_count - ar0), 64'd2);
      chk("aligned DOS dword: fill ARLEN", 64'(mon_arlen), 64'd7);
      // dword at 0x9FFFD: bytes 0x9FFFD..0xA0000 -- its LAST byte is in the VGA
      // aperture (0xA0000). First-byte classification took the cacheable xline
      // path and ALLOCATED the VGA line (the R2-H02 defect); the extent form must
      // take the NARROW path instead. R2-H01: the read is THREE byte-exact pieces
      // (byte@9FFFD, word@9FFFE, byte@A0000), each its own single-beat AR -- no
      // transaction crosses the 4 KiB edge, and no adjacent byte is touched.
      // NO allocation (the re-read re-fetches).
      ar0 = ar_count;
      do_read(32'h0009_FFFD, d);
      chk("boundary dword data", 64'(d), 64'hB3A0A1A2);
      chk("boundary dword: THREE piece ARs (R2-H01)", 64'(ar_count - ar0), 64'd3);
      chk("boundary dword: last piece ARLEN", 64'(mon_arlen), 64'd0);
      chk("boundary dword: last piece ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'hA0000));
      // control: the DOS line filled above still HITS (no new AR)...
      ar0 = ar_count;
      do_read(32'h0000_9FF8, d);
      chk("post-boundary re-read data", 64'(d), 64'h11223344);
      chk("post-boundary re-read: no new AR (line cached)", 64'(ar_count - ar0), 64'd0);
      // ...while the boundary dword was never allocated: another piece triple.
      do_read(32'h0009_FFFD, d);
      chk("boundary re-read data", 64'(d), 64'hB3A0A1A2);
      chk("boundary re-read: THREE piece ARs (not cached)", 64'(ar_count - ar0), 64'd3);
      chk("no route/bus error (VGA override)", 64'(bus_err), 64'd0);

      // ===== byte/word endpoints at the aperture edges, reads and writes ======
      // B = 0xA0000 (DOS RAM below, non-cacheable aperture at/above). A byte or
      // word access ending at B-1 touches no aperture byte: it must take the
      // CACHEABLE fill path like any other DOS access -- and its own extent
      // never crosses its 32B line end, so the fill pulls in exactly ONE line,
      // never the aperture line above it. The aperture side itself is
      // byte-exact narrow pieces, never allocated.
      rd_fill  ("vga-lo byte  rd @9FFFF", 32'h0009_FFFF, 4'h1, 32'h0000_00FF, 32'h0000_00A0, REMAP_BASE + 40'h9FFE0);
      ar0 = ar_count; do_read_be(32'h0009_FFFE, 4'h3, d);
      chk("vga-lo word  rd @9FFFE data", 64'(d & 32'hFFFF), 64'hA0A1);
      chk("vga-lo word  rd @9FFFE: hit, no AR", 64'(ar_count - ar0), 64'd0);
      ar0 = ar_count; do_read_be(32'h0009_FFFC, 4'hF, d);
      chk("vga-lo dword rd @9FFFC data", 64'(d), 64'hA0A1_A2A3);
      chk("vga-lo dword rd @9FFFC: hit, no AR", 64'(ar_count - ar0), 64'd0);
      rd_narrow("vga    byte  rd @A0000", 32'h000A_0000, 4'h1, 32'h0000_00B3, REMAP_BASE + 40'hA0000, 3'd0);
      rd_narrow("vga    word  rd @A0000", 32'h000A_0000, 4'h3, 32'h0000_B2B3, REMAP_BASE + 40'hA0000, 3'd1);
      rd_narrow("vga    dword rd @A0000", 32'h000A_0000, 4'hF, 32'hB0B1_B2B3, REMAP_BASE + 40'hA0000, 3'd2);
      // straddling reads: non-cacheable by EXTENT, served as aligned pieces on
      // BOTH sides of the boundary (the dword @9FFFD shape above is the third).
      ar0 = ar_count;
      do_read_be(32'h0009_FFFF, 4'h3, d);   // word: bytes 9FFFF + A0000
      chk("vga strad word  rd @9FFFF data", 64'(d), 64'h0000_B3A0);
      chk("vga strad word  rd @9FFFF: TWO piece ARs", 64'(ar_count - ar0), 64'd2);
      chk("vga strad word  rd @9FFFF: p1 ARADDR", 64'(mon_araddr2), 64'(REMAP_BASE + 40'h9FFFF));
      chk("vga strad word  rd @9FFFF: p1 ARSIZE", 64'(mon_arsize2), 64'd0);
      chk("vga strad word  rd @9FFFF: p2 ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'hA0000));
      chk("vga strad word  rd @9FFFF: p2 ARSIZE", 64'(mon_arsize), 64'd0);
      ar0 = ar_count;
      do_read_be(32'h0009_FFFE, 4'hF, d);   // dword: words 9FFFE + A0000
      chk("vga strad dword rd @9FFFE data", 64'(d), 64'hB2B3_A0A1);
      chk("vga strad dword rd @9FFFE: TWO piece ARs", 64'(ar_count - ar0), 64'd2);
      chk("vga strad dword rd @9FFFE: p1 ARADDR", 64'(mon_araddr2), 64'(REMAP_BASE + 40'h9FFFE));
      chk("vga strad dword rd @9FFFE: p1 ARSIZE", 64'(mon_arsize2), 64'd1);
      chk("vga strad dword rd @9FFFE: p2 ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'hA0000));
      chk("vga strad dword rd @9FFFE: p2 ARSIZE", 64'(mon_arsize), 64'd1);
      // writes at the same shapes all reach the backing (no hole in this
      // configuration); a straddling store is two single-beat writes.
      wr_ok("vga-lo byte  wr @9FFFF", 32'h0009_FFFF, 32'h0000_005A, 4'h1, 1, 32'h0009_FFFC, 32'h5AA1_A2A3);
      wr_ok("vga-lo word  wr @9FFFE", 32'h0009_FFFE, 32'h0000_C3C3, 4'h3, 1, 32'h0009_FFFC, 32'hC3C3_A2A3);
      wr_ok("vga-lo dword wr @9FFFC", 32'h0009_FFFC, 32'hD00D_9FFC, 4'hF, 1, 32'h0009_FFFC, 32'hD00D_9FFC);
      wr_ok("vga    byte  wr @A0000", 32'h000A_0000, 32'h0000_005A, 4'h1, 1, 32'h000A_0000, 32'hB0B1_B25A);
      wr_ok("vga    word  wr @A0000", 32'h000A_0000, 32'h0000_C3C3, 4'h3, 1, 32'h000A_0000, 32'hB0B1_C3C3);
      wr_ok("vga    dword wr @A0000", 32'h000A_0000, 32'hA000_0000, 4'hF, 1, 32'h000A_0000, 32'hA000_0000);
      wr_ok("vga strad word  wr @9FFFF", 32'h0009_FFFF, 32'h0000_E7E7, 4'h3, 2, 32'h0009_FFFC, 32'hE70D_9FFC);
      chk("vga strad word  wr @9FFFF: p2 byte", 64'(slv.peek(32'h000A_0000) & 32'hFF), 64'hE7);
      wr_ok("vga strad dword wr @9FFFD", 32'h0009_FFFD, 32'hAABB_CCDD, 4'hF, 2, 32'h0009_FFFC, 32'hBBCC_DDFC);
      chk("vga strad dword wr @9FFFD: p2 byte", 64'(slv.peek(32'h000A_0000) & 32'hFF), 64'hAA);

      // B = 0xC0000 (aperture below, the cacheable ROM window at/above).
      slv.poke(32'h000B_FFFC, 32'hB106_5678);
      slv.poke(32'h000C_0000, 32'hC001_2ACE);
      rd_narrow("vga-hi byte  rd @BFFFF", 32'h000B_FFFF, 4'h1, 32'h0000_00B1, REMAP_BASE + 40'hBFFFF, 3'd0);
      rd_narrow("vga-hi word  rd @BFFFE", 32'h000B_FFFE, 4'h3, 32'h0000_B106, REMAP_BASE + 40'hBFFFE, 3'd1);
      rd_narrow("vga-hi dword rd @BFFFC", 32'h000B_FFFC, 4'hF, 32'hB106_5678, REMAP_BASE + 40'hBFFFC, 3'd2);
      rd_fill  ("pam    byte  rd @C0000", 32'h000C_0000, 4'h1, 32'h0000_00FF, 32'h0000_00CE, REMAP_BASE + 40'hC0000);
      ar0 = ar_count; do_read_be(32'h000C_0000, 4'h3, d);
      chk("pam    word  rd @C0000 data", 64'(d & 32'hFFFF), 64'h2ACE);
      chk("pam    word  rd @C0000: hit, no AR", 64'(ar_count - ar0), 64'd0);
      ar0 = ar_count; do_read_be(32'h000C_0000, 4'hF, d);
      chk("pam    dword rd @C0000 data", 64'(d), 64'hC001_2ACE);
      chk("pam    dword rd @C0000: hit, no AR", 64'(ar_count - ar0), 64'd0);
      // straddling reads across 0xC0000 (three of the four dword offsets).
      ar0 = ar_count;
      do_read_be(32'h000B_FFFF, 4'h3, d);   // word: bytes BFFFF + C0000
      chk("pam strad word  rd @BFFFF data", 64'(d), 64'h0000_CEB1);
      chk("pam strad word  rd @BFFFF: TWO piece ARs", 64'(ar_count - ar0), 64'd2);
      chk("pam strad word  rd @BFFFF: p1 ARADDR", 64'(mon_araddr2), 64'(REMAP_BASE + 40'hBFFFF));
      chk("pam strad word  rd @BFFFF: p2 ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'hC0000));
      ar0 = ar_count;
      do_read_be(32'h000B_FFFD, 4'hF, d);   // dword: byte/word/byte pieces
      chk("pam strad dword rd @BFFFD data", 64'(d), 64'hCEB1_0656);
      chk("pam strad dword rd @BFFFD: THREE piece ARs", 64'(ar_count - ar0), 64'd3);
      chk("pam strad dword rd @BFFFD: p1 ARADDR", 64'(mon_araddr3), 64'(REMAP_BASE + 40'hBFFFD));
      chk("pam strad dword rd @BFFFD: p1 ARSIZE", 64'(mon_arsize3), 64'd0);
      chk("pam strad dword rd @BFFFD: p2 ARADDR", 64'(mon_araddr2), 64'(REMAP_BASE + 40'hBFFFE));
      chk("pam strad dword rd @BFFFD: p2 ARSIZE", 64'(mon_arsize2), 64'd1);
      chk("pam strad dword rd @BFFFD: p3 ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'hC0000));
      chk("pam strad dword rd @BFFFD: p3 ARSIZE", 64'(mon_arsize), 64'd0);
      ar0 = ar_count;
      do_read_be(32'h000B_FFFE, 4'hF, d);   // dword: two word pieces
      chk("pam strad dword rd @BFFFE data", 64'(d), 64'h2ACE_B106);
      chk("pam strad dword rd @BFFFE: TWO piece ARs", 64'(ar_count - ar0), 64'd2);
      // writes at the 0xC0000 edge.
      wr_ok("vga-hi byte  wr @BFFFF", 32'h000B_FFFF, 32'h0000_005A, 4'h1, 1, 32'h000B_FFFC, 32'h5A06_5678);
      wr_ok("vga-hi word  wr @BFFFE", 32'h000B_FFFE, 32'h0000_C3C3, 4'h3, 1, 32'h000B_FFFC, 32'hC3C3_5678);
      wr_ok("vga-hi dword wr @BFFFC", 32'h000B_FFFC, 32'h0BFF_C000, 4'hF, 1, 32'h000B_FFFC, 32'h0BFF_C000);
      wr_ok("pam    byte  wr @C0000", 32'h000C_0000, 32'h0000_005A, 4'h1, 1, 32'h000C_0000, 32'hC001_2A5A);
      wr_ok("pam    word  wr @C0000", 32'h000C_0000, 32'h0000_C3C3, 4'h3, 1, 32'h000C_0000, 32'hC001_C3C3);
      wr_ok("pam    dword wr @C0000", 32'h000C_0000, 32'h0C00_0000, 4'hF, 1, 32'h000C_0000, 32'h0C00_0000);
      wr_ok("pam strad word  wr @BFFFF", 32'h000B_FFFF, 32'h0000_E7E7, 4'h3, 2, 32'h000B_FFFC, 32'hE7FF_C000);
      chk("pam strad word  wr @BFFFF: p2 byte", 64'(slv.peek(32'h000C_0000) & 32'hFF), 64'hE7);
      wr_ok("pam strad dword wr @BFFFD", 32'h000B_FFFD, 32'hAABB_CCDD, 4'hF, 2, 32'h000B_FFFC, 32'hBBCC_DD00);
      chk("pam strad dword wr @BFFFD: p2 byte", 64'(slv.peek(32'h000C_0000) & 32'hFF), 64'hAA);
      chk("no route/bus error (byte/word endpoints)", 64'(bus_err), 64'd0);
    end

    if (errs==0) $display("  ok  [%s] route/extent/CD checks pass", TAG);
    done <= 1'b1;
  end
endmodule

// ============================================================================
// REVIEW_Aug4 A4-M01: the WINDOWED R_PCI contract (region 6 -> DDR only inside
// (addr & ~ADDR_MASK)==0 or the >= 0xFFFE_0000 BIOS shadow, else route_err).
// One harness, two configurations (see TAG/params): R6WIN = the TB's stock
// 1 GiB mask; R6KV = the KV260 256 MiB fold with a lowered TOM so a region-6
// band exists inside the carveout. The downstream is an address-patterned mini
// slave (no backing array -- the region-6/shadow addresses are far above
// axi_slave_bfm's 1 MiB window), which makes the AR/AW handshake + payload the
// graded DDR-side observables and returns rdata = word_addr ^ 0x5A5A_0000 (the
// repo's usual data convention) for the DDR-side data checks. The byte/word
// endpoint matrix at TOM, the RAM-window edge, and the shadow edge runs on
// both configurations, reads and writes.
// ============================================================================
module r6_harness #(
    parameter int          CORE_HALF    = 4,
    parameter int          AXI_HALF     = 4,
    parameter string       TAG          = "?",
    parameter logic [31:0] ADDR_MASK_P  = 32'h3FFF_FFFF,
    parameter logic [7:0]  NB_TOM_MB4_P = 8'd255,    // TOM = *4 MiB (255 -> 0x3FC0_0000)
    parameter logic [7:0]  NB_DRAMC_P   = 8'h01      // no memory hole
) (
    output logic       done,
    output int         errs
);
  logic ic_nocache_unused;
  localparam logic [39:0] REMAP_BASE = 40'h00_4000_0000;
  localparam int          ADDR_W     = 40;

  logic core_clk=0, axi_clk=0, core_rst_n=0, axi_rst_n=0;
  always #(CORE_HALF) core_clk = ~core_clk;
  always #(AXI_HALF)  axi_clk  = ~axi_clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        bus_err, m_idle; logic flush = 1'b0;

  logic [3:0]        awid;   logic [ADDR_W-1:0] awaddr; logic [7:0] awlen;
  logic [2:0]        awsize; logic [1:0] awburst; logic awlock; logic [3:0] awcache;
  logic [2:0]        awprot; logic [3:0] awqos; logic awvalid, awready;
  logic [31:0]       wdata;  logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0]        bid;    logic [1:0] bresp; logic bvalid, bready;
  logic [3:0]        arid;   logic [ADDR_W-1:0] araddr; logic [7:0] arlen;
  logic [2:0]        arsize; logic [1:0] arburst; logic arlock; logic [3:0] arcache;
  logic [2:0]        arprot; logic [3:0] arqos; logic arvalid, arready;
  logic [3:0]        rid;    logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;

  ventium_l1_axi #(.ADDR_W(ADDR_W), .REMAP_BASE(REMAP_BASE), .ADDR_MASK(ADDR_MASK_P),
                   .NB_DRAMC(NB_DRAMC_P), .NB_TOM_MB4(NB_TOM_MB4_P)) dut (
      .core_clk(core_clk), .core_rst_n(core_rst_n), .axi_clk(axi_clk), .axi_rst_n(axi_rst_n),
      .flush_all(flush), .golden_l1(1'b0), .shutdown(1'b0), .m_idle(m_idle),
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

  // ---- mini read/write slave -------------------------------------------------
  logic [31:0] ar_count;
  logic [ADDR_W-1:0] mon_araddr, mon_araddr2, mon_araddr3;
  logic [7:0] mon_arlen;
  logic [2:0] mon_arsize, mon_arsize2, mon_arsize3;
  typedef enum logic [0:0] {R_IDLE, R_BEAT} rstate_e;
  rstate_e rs; logic [7:0] beats; logic [ADDR_W-1:0] r_addr; logic [3:0] r_id;

  assign arready = (rs == R_IDLE);
  assign rvalid  = (rs == R_BEAT);
  assign rlast   = (rs == R_BEAT) && (beats == 8'd1);
  // the data pattern is a function of the WORD address, so a narrow piece at an
  // unaligned ARADDR returns its containing word -- the piece's bytes sit on
  // their own lanes, exactly like a real backing store (and identically to
  // before for the word-aligned beats every legacy case uses).
  assign rdata   = {r_addr[31:2], 2'b00} ^ 32'h5A5A_0000;
  assign rid     = r_id;
  assign rresp   = 2'b00;

  always_ff @(posedge axi_clk) begin
    if (!axi_rst_n) begin
      rs <= R_IDLE; beats <= 8'd0; r_addr <= '0; r_id <= '0;
      ar_count <= 32'd0; mon_araddr <= '0; mon_araddr2 <= '0; mon_araddr3 <= '0;
      mon_arlen <= '0; mon_arsize <= '0; mon_arsize2 <= '0; mon_arsize3 <= '0;
    end else begin
      case (rs)
        R_IDLE: if (arvalid) begin
          mon_araddr3 <= mon_araddr2; mon_arsize3 <= mon_arsize2;
          mon_araddr2 <= mon_araddr;  mon_arsize2 <= mon_arsize;
          mon_araddr <= araddr; mon_arlen <= arlen; mon_arsize <= arsize;
          ar_count   <= ar_count + 32'd1;
          r_addr     <= araddr; beats <= arlen + 8'd1; r_id <= arid;
          rs         <= R_BEAT;
        end
        R_BEAT: if (rready) begin
          if (beats == 8'd1) rs <= R_IDLE;
          beats  <= beats - 8'd1;
          r_addr <= r_addr + 40'd4;
        end
        default: rs <= R_IDLE;
      endcase
    end
  end

  // write channel: single-outstanding like the read side (the DUT never has
  // more than one transaction in flight). No backing array -- the graded
  // observables are the AW count/address and the W strobes of each beat.
  logic [31:0]       aw_count;
  logic [ADDR_W-1:0] mon_awaddr, mon_awaddr2;
  logic [2:0]        mon_awsize;
  logic [3:0]        mon_wstrb, mon_wstrb2;
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_e;
  wstate_e ws;

  assign awready = (ws == W_IDLE);
  assign wready  = (ws == W_DATA);
  assign bvalid  = (ws == W_RESP);
  assign bid     = '0;
  assign bresp   = 2'b00;

  always_ff @(posedge axi_clk) begin
    if (!axi_rst_n) begin
      ws <= W_IDLE; aw_count <= 32'd0;
      mon_awaddr <= '0; mon_awaddr2 <= '0; mon_awsize <= '0;
      mon_wstrb <= '0; mon_wstrb2 <= '0;
    end else begin
      case (ws)
        W_IDLE: if (awvalid) begin
                  aw_count <= aw_count + 32'd1;
                  mon_awaddr2 <= mon_awaddr; mon_wstrb2 <= mon_wstrb;
                  mon_awaddr <= awaddr; mon_awsize <= awsize;
                  ws <= W_DATA;
                end
        W_DATA: if (wvalid) begin
                  mon_wstrb <= wstrb;
                  if (wlast) ws <= W_RESP;
                end
        W_RESP: if (bready) ws <= W_IDLE;
        default: ws <= W_IDLE;
      endcase
    end
  end

  task automatic chk(input string what, input logic [63:0] got, exp);
    if (got !== exp) begin $display("  FAIL [%s] %s: got %08x exp %08x", TAG, what, got, exp); errs++; end
  endtask

  // core READ to `a` with the compact size strobes the core drives (1=byte,
  // 3=word, F=dword).
  task automatic do_read_be(input logic [31:0] a, input logic [3:0] be, output logic [31:0] d);
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

  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    do_read_be(a, 4'hF, d);
  endtask

  // core WRITE: wdata/wstrb are lane-0-justified at the byte address; a
  // straddling store reaches the bus as two single-beat writes.
  task automatic do_write(input logic [31:0] a, input logic [31:0] wdata, input logic [3:0] be);
    int guard;
    @(negedge core_clk); c_req<=1'b1; c_we<=1'b1; c_addr<=a; c_wdata<=wdata; c_wstrb<=be;
    guard=0;
    forever begin
      @(posedge core_clk); #1;
      if (c_ack) break;
      if (++guard > 5000) begin $display("  FAIL [%s] write %08x: no ack", TAG, a); errs++; break; end
    end
    @(negedge core_clk); c_req<=1'b0; c_we<=1'b0; c_wstrb<=4'd0;
  endtask

  // Stores are acknowledged at P54C queue admission, not at external AXI
  // completion. Wait for the exported drain signal before examining external
  // write effects; otherwise this test observes a previous posted store.
  task automatic wait_axi_drain(input string what);
    int guard;
    guard = 0;
    forever begin
      @(posedge core_clk); #1;
      if (m_idle) break;
      if (++guard > 5000) begin
        $display("  FAIL [%s] AXI write queue did not drain", TAG);
        errs++;
        break;
      end
    end
  endtask

  // ---- boundary-case helpers -------------------------------------------------
  // non-cacheable-side read: ONE single-beat piece AR at the byte address and
  // ARSIZE of the access; no allocation (the re-read costs another AR).
  task automatic rd_narrow(input string what, input logic [31:0] a, input logic [3:0] be,
                           input logic [31:0] exp_data, input logic [39:0] exp_axi,
                           input logic [2:0] exp_size);
    logic [31:0] ar0;
    ar0 = ar_count;
    do_read_be(a, be, d);
    chk({what, " data"},         64'(d),              64'(exp_data));
    chk({what, ": ONE piece AR"}, 64'(ar_count - ar0), 64'd1);
    chk({what, ": piece ARLEN"}, 64'(mon_arlen),      64'd0);
    chk({what, ": piece ARSIZE"}, 64'(mon_arsize),    64'(exp_size));
    chk({what, ": piece ARADDR"}, 64'(mon_araddr),    64'(exp_axi));
    ar0 = ar_count;
    do_read_be(a, be, d);
    chk({what, ": re-read ARs (not cached)"}, 64'(ar_count - ar0), 64'd1);
  endtask

  // denied read: local ack, rdata=0, NO AR at all, route_err -> bus_err.
  task automatic rd_loud(input string what, input logic [31:0] a, input logic [3:0] be);
    logic [31:0] ar0;
    ar0 = ar_count;
    do_read_be(a, be, d);
    chk({what, ": local ack rdata=0"}, 64'(d),              64'd0);
    chk({what, ": NO AR"},            64'(ar_count - ar0), 64'd0);
    chk({what, ": route_err -> bus_err"}, 64'(bus_err),    64'd1);
  endtask

  // write that must reach DDR: exactly ONE AW at the word-aligned folded
  // address with the lane-shifted strobes.
  task automatic wr_ok(input string what, input logic [31:0] a, input logic [31:0] wdata,
                       input logic [3:0] be, input logic [39:0] exp_axi, input logic [3:0] exp_strb);
    logic [31:0] aw0;
    aw0 = aw_count;
    do_write(a, wdata, be);
    wait_axi_drain(what);
    chk({what, ": ONE AW"}, 64'(aw_count - aw0), 64'd1);
    chk({what, ": AWADDR"}, 64'(mon_awaddr),     64'(exp_axi));
    chk({what, ": AWSIZE"}, 64'(mon_awsize),     64'd2);
    chk({what, ": WSTRB"},   64'(mon_wstrb),     64'(exp_strb));
  endtask

  // straddling write that must reach DDR: TWO single-beat writes, first beat
  // below the boundary, second at/above it.
  task automatic wr_ok2(input string what, input logic [31:0] a, input logic [31:0] wdata,
                        input logic [3:0] be,
                        input logic [39:0] exp_axi1, input logic [3:0] exp_strb1,
                        input logic [39:0] exp_axi2, input logic [3:0] exp_strb2);
    logic [31:0] aw0;
    aw0 = aw_count;
    do_write(a, wdata, be);
    wait_axi_drain(what);
    chk({what, ": TWO AWs"},   64'(aw_count - aw0), 64'd2);
    chk({what, ": p1 AWADDR"}, 64'(mon_awaddr2),    64'(exp_axi1));
    chk({what, ": p1 WSTRB"},  64'(mon_wstrb2),     64'(exp_strb1));
    chk({what, ": p2 AWADDR"}, 64'(mon_awaddr),     64'(exp_axi2));
    chk({what, ": p2 WSTRB"},  64'(mon_wstrb),      64'(exp_strb2));
  endtask

  // denied write: no AW at all, route_err -> bus_err.
  task automatic wr_loud(input string what, input logic [31:0] a, input logic [31:0] wdata,
                         input logic [3:0] be);
    logic [31:0] aw0;
    aw0 = aw_count;
    do_write(a, wdata, be);
    wait_axi_drain(what);
    repeat (4) @(posedge axi_clk); #1;
    chk({what, ": NO AW"},               64'(aw_count - aw0), 64'd0);
    chk({what, ": route_err -> bus_err"}, 64'(bus_err),       64'd1);
  endtask

  // (the rd_wedge pin task was retired with the fold guard's narrow-piece
  // extent fix: byte/word reads wholly inside the RAM window's last word now
  // take the rd_narrow contract -- see the last-word cases below.)

  logic [31:0] d; logic [31:0] ar0;
  initial begin
    errs=0; done=1'b0;
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    repeat(10) @(posedge core_clk);
    @(negedge core_clk); core_rst_n<=1'b1;
    @(negedge axi_clk);  axi_rst_n<=1'b1;
    repeat(8) @(posedge core_clk);

    if (ADDR_MASK_P == 32'h3FFF_FFFF) begin
      // ---------------- R6WIN: the 1 GiB window (TOM = 0x3FC0_0000) ---------
      do_read(32'h0000_1004, d);
      chk("DOS below TOM data (fill beats)", 64'(d), 64'h1A5A1004);
      chk("DOS below TOM: no error", 64'(bus_err), 64'd0);
      // region 6 INSIDE the window: routes to DDR (narrow: ONE AR, ARLEN=0).
      // The master's fold is REMAP_BASE + (phys & ADDR_MASK) for EVERY address.
      ar0 = ar_count;
      do_read(32'h3FC0_0004, d);
      chk("r6 in-window data", 64'(d), 64'h259A0004);
      chk("r6 in-window: ONE narrow AR", 64'(ar_count - ar0), 64'd1);
      chk("r6 in-window: ARLEN=0", 64'(mon_arlen), 64'd0);
      chk("r6 in-window: ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'h3FC00004));
      chk("r6 in-window: no error", 64'(bus_err), 64'd0);
      // the BIOS-shadow exception: both shadow pages route to DDR (their
      // ARADDRs fold to the TOP of the window -- that is what the fold is for).
      ar0 = ar_count;
      do_read(32'hFFFE_0004, d);
      chk("shadow 0xFFFE_0004: ONE AR", 64'(ar_count - ar0), 64'd1);
      chk("shadow 0xFFFE_0004: ARADDR (folded)", 64'(mon_araddr), 64'(REMAP_BASE + 40'h3FFE0004));
      ar0 = ar_count;
      do_read(32'hFFFF_0004, d);
      chk("shadow 0xFFFF_0004: ONE AR", 64'(ar_count - ar0), 64'd1);
      chk("shadow 0xFFFF_0004: ARADDR (folded)", 64'(mon_araddr), 64'(REMAP_BASE + 40'h3FFF0004));
      chk("shadow: no error", 64'(bus_err), 64'd0);
      // fully-inside straddle at the window edge (bytes 3FFF_FFFC..3FFF_FFFF):
      // classified inside by BOTH endpoints -> DDR.
      ar0 = ar_count;
      do_read(32'h3FFF_FFFC, d);
      chk("in-window straddle: ONE AR", 64'(ar_count - ar0), 64'd1);
      chk("in-window straddle: ARLEN=0", 64'(mon_arlen), 64'd0);
      chk("in-window straddle: no error", 64'(bus_err), 64'd0);

      // ===== byte/word endpoints: TOM, the RAM-window edge, the shadow edge ====
      // TOM (0x3FC0_0000): below is cacheable DRAM, at/above is the
      // non-cacheable in-window PCI band. A byte/word read ending at
      // 0x3FBF_FFFF touches nothing at/above TOM -> an ordinary cacheable
      // fill. Its own extent never crosses its 32B line end either, so the
      // fill pulls in exactly ONE line, never the region-6 line above it.
      ar0 = ar_count;
      do_read_be(32'h3FBF_FFFF, 4'h1, d);
      chk("tom-lo byte  rd data", 64'(d & 32'hFF), 64'h25);
      chk("tom-lo byte  rd: fill ARs", 64'(ar_count - ar0), 64'd2);
      chk("tom-lo byte  rd: fill ARLEN", 64'(mon_arlen), 64'd7);
      chk("tom-lo byte  rd: fill ARADDR (line)", 64'(mon_araddr), 64'(REMAP_BASE + 40'h3FBFFFE0));
      ar0 = ar_count; do_read_be(32'h3FBF_FFFE, 4'h3, d);
      chk("tom-lo word  rd data", 64'(d & 32'hFFFF), 64'h25E5);
      chk("tom-lo word  rd: hit, no AR", 64'(ar_count - ar0), 64'd0);
      ar0 = ar_count; do_read_be(32'h3FBF_FFFC, 4'hF, d);
      chk("tom-lo dword rd data", 64'(d), 64'h25E5FFFC);
      chk("tom-lo dword rd: hit, no AR", 64'(ar_count - ar0), 64'd0);
      rd_narrow("tom    byte  rd @3FC0_0000", 32'h3FC0_0000, 4'h1, 32'h0000_0000, REMAP_BASE + 40'h3FC00000, 3'd0);
      rd_narrow("tom    word  rd @3FC0_0000", 32'h3FC0_0000, 4'h3, 32'h0000_0000, REMAP_BASE + 40'h3FC00000, 3'd1);
      rd_narrow("tom    dword rd @3FC0_0000", 32'h3FC0_0000, 4'hF, 32'h259A_0000, REMAP_BASE + 40'h3FC00000, 3'd2);
      // TOM straddles: non-cacheable by extent, aligned pieces on both sides.
      ar0 = ar_count;
      do_read_be(32'h3FBF_FFFF, 4'h3, d);   // word: bytes 3FBF_FFFF + 3FC0_0000
      chk("tom strad word  rd data", 64'(d), 64'h0000_0025);
      chk("tom strad word  rd: TWO piece ARs", 64'(ar_count - ar0), 64'd2);
      chk("tom strad word  rd: p1 ARADDR", 64'(mon_araddr2), 64'(REMAP_BASE + 40'h3FBFFFFF));
      chk("tom strad word  rd: p1 ARSIZE", 64'(mon_arsize2), 64'd0);
      chk("tom strad word  rd: p2 ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'h3FC00000));
      chk("tom strad word  rd: p2 ARSIZE", 64'(mon_arsize), 64'd0);
      ar0 = ar_count;
      do_read_be(32'h3FBF_FFFD, 4'hF, d);   // dword: byte/word/byte pieces
      chk("tom strad dword rd @...FFD data", 64'(d), 64'h0025_E5FF);
      chk("tom strad dword rd @...FFD: THREE piece ARs", 64'(ar_count - ar0), 64'd3);
      chk("tom strad dword rd @...FFD: p1 ARADDR", 64'(mon_araddr3), 64'(REMAP_BASE + 40'h3FBFFFFD));
      chk("tom strad dword rd @...FFD: p2 ARADDR", 64'(mon_araddr2), 64'(REMAP_BASE + 40'h3FBFFFFE));
      chk("tom strad dword rd @...FFD: p3 ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'h3FC00000));
      ar0 = ar_count;
      do_read_be(32'h3FBF_FFFE, 4'hF, d);   // dword: two word pieces
      chk("tom strad dword rd @...FFE data", 64'(d), 64'h0000_25E5);
      chk("tom strad dword rd @...FFE: TWO piece ARs", 64'(ar_count - ar0), 64'd2);
      chk("tom strad dword rd @...FFE: p1 ARSIZE", 64'(mon_arsize2), 64'd1);
      chk("tom strad dword rd @...FFE: p2 ARSIZE", 64'(mon_arsize), 64'd1);
      // the RAM-window edge (0x4000_0000): byte/word ending at 3FFF_FFFF is
      // wholly INSIDE the window. The master-side alias guard still measures a
      // READ's extent with the legacy 4-byte window, so those two reads are
      // rejected there (no ack, no AR, alias_err) -- pinned as a known defect
      // after the good-phase checks below. The dword control (the in-window
      // straddle above, and the writes below) is inside the guard's window.
      // the shadow edge (0xFFFE_0000): byte/word at the shadow base route to DDR.
      rd_narrow("shadow byte  rd @FFFE_0000", 32'hFFFE_0000, 4'h1, 32'h0000_0000, REMAP_BASE + 40'h3FFE0000, 3'd0);
      rd_narrow("shadow dword rd @FFFE_0000", 32'hFFFE_0000, 4'hF, 32'h25A4_0000, REMAP_BASE + 40'h3FFE0000, 3'd2);
      // writes at the same shapes: inside/TOM-side stores reach DDR with exact
      // lanes; a straddling store inside the window is two single beats.
      wr_ok ("tom-lo byte  wr @3FBF_FFFF", 32'h3FBF_FFFF, 32'h0000_005A, 4'h1, REMAP_BASE + 40'h3FBFFFFC, 4'b1000);
      wr_ok ("tom    byte  wr @3FC0_0000", 32'h3FC0_0000, 32'h0000_005A, 4'h1, REMAP_BASE + 40'h3FC00000, 4'b0001);
      wr_ok2("tom strad word wr @3FBF_FFFF", 32'h3FBF_FFFF, 32'h0000_E7E7, 4'h3,
             REMAP_BASE + 40'h3FBFFFFC, 4'b1000, REMAP_BASE + 40'h3FC00000, 4'b0001);
      wr_ok ("win    byte  wr @3FFF_FFFF", 32'h3FFF_FFFF, 32'h0000_005A, 4'h1, REMAP_BASE + 40'h3FFFFFFC, 4'b1000);
      wr_ok ("win    word  wr @3FFF_FFFE", 32'h3FFF_FFFE, 32'h0000_C3C3, 4'h3, REMAP_BASE + 40'h3FFFFFFC, 4'b1100);
      wr_ok ("win    dword wr @3FFF_FFFC", 32'h3FFF_FFFC, 32'h1234_5678, 4'hF, REMAP_BASE + 40'h3FFFFFFC, 4'b1111);
      wr_ok ("shadow byte  wr @FFFE_0000", 32'hFFFE_0000, 32'h0000_005A, 4'h1, REMAP_BASE + 40'h3FFE0000, 4'b0001);
      chk("endpoint good phase: no error", 64'(bus_err), 64'd0);
      // The fold guard now measures a narrow read's true piece extent
      // (m_rd_narrow/m_rd_size), so byte/word reads wholly inside the window's
      // last word are served like any other narrow piece (the wedge pins this
      // replaced pinned the legacy guard's false alias rejection). Poke the
      // backing explicitly: the folded indices alias the harness's seeded
      // pattern: rdata is a pure function of the word address.
      rd_narrow("win    byte  rd @3FFF_FFFF", 32'h3FFF_FFFF, 4'h1, 32'h0000_0025, REMAP_BASE + 40'h3FFFFFFF, 3'd0);
      rd_narrow("win    word  rd @3FFF_FFFE", 32'h3FFF_FFFE, 4'h3, 32'h0000_25A5, REMAP_BASE + 40'h3FFFFFFE, 3'd1);
      chk("win last-word reads: no error", 64'(bus_err), 64'd0);
      // region 6 OUTSIDE the window: suppressed + sticky route_err, NO AR.
      ar0 = ar_count;
      do_read(32'h5000_0004, d);
      chk("r6 out-window: NO AR", 64'(ar_count - ar0), 64'd0);
      chk("r6 out-window: local ack rdata=0", 64'(d), 64'd0);
      chk("r6 out-window: route_err -> bus_err", 64'(bus_err), 64'd1);
      // straddle OUT of the window (first byte inside, last byte outside):
      // the extent check classifies by the LAST byte -> loud, NO AR at all.
      ar0 = ar_count;
      do_read(32'h3FFF_FFFE, d);
      chk("out-window straddle: NO AR", 64'(ar_count - ar0), 64'd0);
      chk("out-window straddle: rdata=0", 64'(d), 64'd0);
      chk("out-window straddle: route_err", 64'(bus_err), 64'd1);
      // RECONCILED (A4-M01): the retired R2-H03 expectation had 0x4000_0004
      // "inside the fold mask -> must NOT route_err" because region 6 was
      // ALWAYS DDR. Above the 1 GiB mask and outside the shadow, the loud
      // path is now the CORRECT contract.
      ar0 = ar_count;
      do_read(32'h4000_0004, d);
      chk("above-mask r6 (was always-DDR): NO AR", 64'(ar_count - ar0), 64'd0);
      chk("above-mask r6 (was always-DDR): rdata=0", 64'(d), 64'd0);
      chk("above-mask r6 (was always-DDR): route_err", 64'(bus_err), 64'd1);
      // byte/word loud endpoints: anything whose extent crosses OUT of the
      // window (or touches the out-of-window band below the shadow) is denied
      // as a whole, reads and writes alike.
      rd_loud("win    byte  rd @4000_0000", 32'h4000_0000, 4'h1);
      rd_loud("win strad word rd @3FFF_FFFF", 32'h3FFF_FFFF, 4'h3);
      rd_loud("win strad dword rd @3FFF_FFFD", 32'h3FFF_FFFD, 4'hF);
      rd_loud("shadow-lo byte rd @FFFD_FFFF", 32'hFFFD_FFFF, 4'h1);
      rd_loud("shadow strad word rd @FFFD_FFFF", 32'hFFFD_FFFF, 4'h3);
      wr_loud("win    byte  wr @4000_0000", 32'h4000_0000, 32'h0000_005A, 4'h1);
      wr_loud("win    dword wr @4000_0000", 32'h4000_0000, 32'hDEAD_BEEF, 4'hF);
      wr_loud("win strad word wr @3FFF_FFFF", 32'h3FFF_FFFF, 32'h0000_E7E7, 4'h3);
      wr_loud("shadow-lo byte wr @FFFD_FFFF", 32'hFFFD_FFFF, 32'h0000_005A, 4'h1);
    end else begin
      // ---------------- R6KV: the KV260 256 MiB fold (TOM = 0x0F00_0000) ----
      do_read(32'h0000_1004, d);
      chk("kv DOS below TOM data (fill beats)", 64'(d), 64'h1A5A1004);
      chk("kv DOS below TOM: no error", 64'(bus_err), 64'd0);
      // region 6 INSIDE the 256 MiB carveout -> DDR (the ARADDR folds as
      // REMAP_BASE + (phys & ADDR_MASK) = 0x4F00_0004).
      ar0 = ar_count;
      do_read(32'h0F00_0004, d);
      chk("kv r6 in-carveout data", 64'(d), 64'h155A0004);
      chk("kv r6 in-carveout: ONE narrow AR", 64'(ar_count - ar0), 64'd1);
      chk("kv r6 in-carveout: ARLEN=0", 64'(mon_arlen), 64'd0);
      chk("kv r6 in-carveout: ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'h0F000004));
      chk("kv r6 in-carveout: no error", 64'(bus_err), 64'd0);
      // the BIOS-shadow exception survives the narrow fold (ARADDR folds to
      // the top of the 256 MiB window).
      ar0 = ar_count;
      do_read(32'hFFFE_0004, d);
      chk("kv shadow 0xFFFE_0004: ONE AR", 64'(ar_count - ar0), 64'd1);
      chk("kv shadow 0xFFFE_0004: ARADDR (folded)", 64'(mon_araddr), 64'(REMAP_BASE + 40'h0FFE0004));
      chk("kv shadow: no error", 64'(bus_err), 64'd0);
      // ===== byte/word endpoints: TOM and the carveout edge (writes too) ======
      // TOM (0x0F00_0000): below is cacheable DRAM, at/above is the
      // non-cacheable in-carveout PCI band. A byte/word read ending at
      // 0x0EFF_FFFF touches nothing at/above TOM -> an ordinary cacheable
      // fill. Its own extent never crosses its 32B line end either, so the
      // fill pulls in exactly ONE line, never the region-6 line above it.
      ar0 = ar_count;
      do_read_be(32'h0EFF_FFFF, 4'h1, d);
      chk("kv tom-lo byte  rd data", 64'(d & 32'hFF), 64'h14);
      chk("kv tom-lo byte  rd: fill ARs", 64'(ar_count - ar0), 64'd2);
      chk("kv tom-lo byte  rd: fill ARLEN", 64'(mon_arlen), 64'd7);
      chk("kv tom-lo byte  rd: fill ARADDR (line)", 64'(mon_araddr), 64'(REMAP_BASE + 40'h0EFFFFE0));
      ar0 = ar_count; do_read_be(32'h0EFF_FFFE, 4'h3, d);
      chk("kv tom-lo word  rd data", 64'(d & 32'hFFFF), 64'h14A5);
      chk("kv tom-lo word  rd: hit, no AR", 64'(ar_count - ar0), 64'd0);
      ar0 = ar_count; do_read_be(32'h0EFF_FFFC, 4'hF, d);
      chk("kv tom-lo dword rd data", 64'(d), 64'h14A5FFFC);
      chk("kv tom-lo dword rd: hit, no AR", 64'(ar_count - ar0), 64'd0);
      rd_narrow("kv tom    byte  rd @0F00_0000", 32'h0F00_0000, 4'h1, 32'h0000_0000, REMAP_BASE + 40'h0F000000, 3'd0);
      rd_narrow("kv tom    dword rd @0F00_0000", 32'h0F00_0000, 4'hF, 32'h155A_0000, REMAP_BASE + 40'h0F000000, 3'd2);
      ar0 = ar_count;
      do_read_be(32'h0EFF_FFFF, 4'h3, d);   // word: bytes 0EFF_FFFF + 0F00_0000
      chk("kv tom strad word rd data", 64'(d), 64'h0000_0014);
      chk("kv tom strad word rd: TWO piece ARs", 64'(ar_count - ar0), 64'd2);
      chk("kv tom strad word rd: p1 ARADDR", 64'(mon_araddr2), 64'(REMAP_BASE + 40'h0EFFFFFF));
      chk("kv tom strad word rd: p2 ARADDR", 64'(mon_araddr), 64'(REMAP_BASE + 40'h0F000000));
      // the carveout edge (0x1000_0000): byte/word ending at 0FFF_FFFF is
      // wholly INSIDE. The master-side fold guard still measures a READ's
      // extent with the legacy 4-byte window, so those two reads are rejected
      // there -- pinned as a known defect after the good-phase checks below.
      // The dword control read is inside the guard's window.
      rd_narrow("kv carve  dword rd @0FFF_FFFC", 32'h0FFF_FFFC, 4'hF, 32'h15A5_FFFC, REMAP_BASE + 40'h0FFFFFFC, 3'd2);
      // the shadow exception survives at byte granularity too.
      rd_narrow("kv shadow byte  rd @FFFE_0000", 32'hFFFE_0000, 4'h1, 32'h0000_0000, REMAP_BASE + 40'h0FFE0000, 3'd0);
      // writes at the same shapes.
      wr_ok ("kv tom-lo byte  wr @0EFF_FFFF", 32'h0EFF_FFFF, 32'h0000_005A, 4'h1, REMAP_BASE + 40'h0EFFFFFC, 4'b1000);
      wr_ok ("kv tom    byte  wr @0F00_0000", 32'h0F00_0000, 32'h0000_005A, 4'h1, REMAP_BASE + 40'h0F000000, 4'b0001);
      wr_ok2("kv tom strad word wr @0EFF_FFFF", 32'h0EFF_FFFF, 32'h0000_E7E7, 4'h3,
             REMAP_BASE + 40'h0EFFFFFC, 4'b1000, REMAP_BASE + 40'h0F000000, 4'b0001);
      wr_ok ("kv carve  byte  wr @0FFF_FFFF", 32'h0FFF_FFFF, 32'h0000_005A, 4'h1, REMAP_BASE + 40'h0FFFFFFC, 4'b1000);
      wr_ok ("kv carve  word  wr @0FFF_FFFE", 32'h0FFF_FFFE, 32'h0000_C3C3, 4'h3, REMAP_BASE + 40'h0FFFFFFC, 4'b1100);
      wr_ok ("kv carve  dword wr @0FFF_FFFC", 32'h0FFF_FFFC, 32'h1234_5678, 4'hF, REMAP_BASE + 40'h0FFFFFFC, 4'b1111);
      chk("kv endpoint good phase: no error", 64'(bus_err), 64'd0);

      // Same narrow-piece extent fix as the 1 GiB harness: byte/word reads
      // wholly inside the carveout's last word are now served (wedge pins
      // removed with the fold guard's false alias rejection).
      rd_narrow("kv carve  byte  rd @0FFF_FFFF", 32'h0FFF_FFFF, 4'h1, 32'h0000_0015, REMAP_BASE + 40'h0FFFFFFF, 3'd0);
      rd_narrow("kv carve  word  rd @0FFF_FFFE", 32'h0FFF_FFFE, 4'h3, 32'h0000_15A5, REMAP_BASE + 40'h0FFFFFFE, 3'd1);
      chk("kv last-word reads: no error", 64'(bus_err), 64'd0);

      // above-carveout, non-shadow region 6 -> loud, NO AR.
      ar0 = ar_count;
      do_read(32'h1000_0004, d);
      chk("kv r6 above-carveout: NO AR", 64'(ar_count - ar0), 64'd0);
      chk("kv r6 above-carveout: rdata=0", 64'(d), 64'd0);
      chk("kv r6 above-carveout: route_err", 64'(bus_err), 64'd1);
      // byte/word loud endpoints at the carveout edge, reads and writes.
      rd_loud("kv carve  byte  rd @1000_0000", 32'h1000_0000, 4'h1);
      rd_loud("kv carve strad word rd @0FFF_FFFF", 32'h0FFF_FFFF, 4'h3);
      rd_loud("kv carve strad dword rd @0FFF_FFFD", 32'h0FFF_FFFD, 4'hF);
      wr_loud("kv carve  byte  wr @1000_0000", 32'h1000_0000, 32'h0000_005A, 4'h1);
      wr_loud("kv carve strad word wr @0FFF_FFFF", 32'h0FFF_FFFF, 32'h0000_E7E7, 4'h3);
    end

    if (errs==0) $display("  ok  [%s] windowed R_PCI checks pass", TAG);
    done <= 1'b1;
  end
endmodule

module tb_l1axi_route;
  logic d0,d1,d2,d3,d4,d5; int e0,e1,e2,e3,e4,e5;
  route_harness #(.CORE_HALF(4), .AXI_HALF(4), .TAG("extent"),
                  .NB_DRAMC_P(8'h01), .CD_P(1'b0)) h0(.done(d0),.errs(e0));
  route_harness #(.CORE_HALF(4), .AXI_HALF(4), .TAG("router"),
                  .NB_DRAMC_P(8'h40), .CD_P(1'b0)) h1(.done(d1),.errs(e1));
  route_harness #(.CORE_HALF(4), .AXI_HALF(4), .TAG("cdef"),
                  .NB_DRAMC_P(8'h01), .CD_P(1'b1)) h2(.done(d2),.errs(e2));
  r6_harness #(.CORE_HALF(4), .AXI_HALF(4), .TAG("r6win"),
               .ADDR_MASK_P(32'h3FFF_FFFF), .NB_TOM_MB4_P(8'd255)) h3(.done(d3),.errs(e3));
  r6_harness #(.CORE_HALF(4), .AXI_HALF(4), .TAG("r6kv"),
               .ADDR_MASK_P(32'h0FFF_FFFF), .NB_TOM_MB4_P(8'd60)) h4(.done(d4),.errs(e4));
  // PAM window boundary: 0xC0000-0xC3FFF enabled R/W/CE, 0xC4000-0xC7FFF disabled.
  route_harness #(.CORE_HALF(4), .AXI_HALF(4), .TAG("pardeny"),
                  .NB_DRAMC_P(8'h01), .CD_P(1'b0),
                  .NB_PAM_P(56'h77_7777_7777_0770)) h5(.done(d5),.errs(e5));

  initial begin
    wait (d0 && d1 && d2 && d3 && d4 && d5);
    if (e0+e1+e2+e3+e4+e5 == 0)
      $display("L1AXIROUTE-GATE-OK (R2-H02 extent + R2-H03 router + R2-H12 CR0.CD + A4-M01 windowed R_PCI x2 + PAM boundary; byte/word endpoints at every policy boundary)");
    else
      $display("L1AXIROUTE-GATE-FAIL (extent=%0d router=%0d cdef=%0d r6win=%0d r6kv=%0d pardeny=%0d)", e0, e1, e2, e3, e4, e5);
    $finish;
  end
endmodule
