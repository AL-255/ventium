// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/l1/tb_l1d_coherence.sv — L1D invalidation-is-transactional gate.
//
// REVIEW Aug-1 H-05/H-06/H-07. The August review shipped a REPRODUCER
// (tmp/review_cache_soc_jul29/tb_l1d_coherence_races.sv) that $fatal's when a race
// does NOT occur — useful to prove a bug exists, useless as a regression gate,
// because it goes red the moment the bug is fixed. This is the inverted form: it
// PASSES iff the L1D never serves pre-invalidation data, so it keeps failing if any
// of the three races comes back.
//
// The three races share ONE root cause: an invalidation (flush_all or a per-line
// snoop) is only ever applied to the CURRENT contents of the tag/valid arrays, but
// two pieces of L1D state outlive that instant --
//
//   H-05  the registered read window (rd_window_q/rd_addr_q/rd_armed). It is captured
//         from the COMBINATIONAL hit (pre-edge tag/valid) and replayed later through
//         rd_match, which compares only the ADDRESS. A same-cycle snoop clears the
//         array but the captured window still acks the old bytes.
//
//   H-06  an 8-beat line fill. flush_all clears the valid bits that exist NOW; the
//   H-07  fill's own tag/valid are installed on the LAST beat, so a flush or snoop
//         during beats 0..6 has nothing to match and is silently dropped. The final
//         beat then validates a line whose backing store has already changed.
//         (A same-cycle LAST-beat snoop is lost too: the snoop block's
//         `dc_val[set][way] && dc_tag[set][way]==tag` guard reads the PRE-EDGE array,
//         which is still valid=0 for the line being allocated — so the "LAST in the FF
//         so an invalidation wins" comment never actually applied to a fill.)
//
// Each case seeds a line with OLD, gets it cached, rewrites the backing to NEW, fires
// the invalidation in the race window, and requires the next read to observe NEW.

module tb_l1d_coherence;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic flush_all = 1'b0;
  logic cacheable = 1'b1;
  logic snoop_inv_valid = 1'b0;
  logic [31:0] snoop_inv_addr = 32'd0;
  logic c_req = 1'b0;
  logic c_we = 1'b0;
  logic [31:0] c_addr = 32'd0;
  logic [31:0] c_wdata = 32'd0;
  logic [3:0] c_wstrb = 4'd0;
  logic [31:0] c_rdata;
  logic c_ack;
  logic m_req;
  logic m_we;
  logic [31:0] m_addr;
  logic [31:0] m_wdata;
  logic [3:0] m_wstrb;
  logic [31:0] m_rdata;
  logic m_ack;

  ven_l1d dut (
      .clk, .rst_n, .flush_all, .golden(1'b0), .cacheable,
      .snoop_inv_valid, .snoop_inv_addr,
      .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb, .c_rdata, .c_ack,
      .dbg_serve(),
      .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack);

  logic [7:0] mem [0:65535];

  function automatic logic [31:0] rd32(input logic [31:0] a);
    return {mem[a+3], mem[a+2], mem[a+1], mem[a]};
  endfunction

  task automatic wr32(input logic [31:0] a, input logic [31:0] d);
    for (int b = 0; b < 4; b++) mem[a+b] = d[b*8 +: 8];
  endtask

  task automatic seed_line(input logic [31:0] base, input logic [31:0] first);
    for (int w = 0; w < 8; w++) wr32(base + 4*w, first + w);
  endtask

  always_comb begin
    m_ack = m_req;
    m_rdata = m_req && !m_we ? rd32(m_addr) : 32'd0;
  end

  always_ff @(posedge clk)
    if (m_req && m_we)
      for (int b = 0; b < 4; b++)
        if (m_wstrb[b]) mem[m_addr+b] <= m_wdata[b*8 +: 8];

  task automatic reset_dut;
    @(negedge clk);
    rst_n = 1'b0;
    flush_all = 1'b0;
    snoop_inv_valid = 1'b0;
    c_req = 1'b0;
    c_we = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
  endtask

  task automatic read_word(input logic [31:0] a, output logic [31:0] d);
    int guard = 0;
    @(negedge clk);
    c_req = 1'b1;
    c_we = 1'b0;
    c_addr = a;
    forever begin
      @(posedge clk);
      #1;
      if (c_ack) begin
        d = c_rdata;
        break;
      end
      guard++;
      if (guard > 80) $fatal(1, "read timeout at %08x", a);
    end
    @(negedge clk);
    c_req = 1'b0;
  endtask

  int checks = 0, fails = 0;

  task automatic expect_eq(input string what, input logic [31:0] got,
                           input logic [31:0] want);
    checks++;
    if (got !== want) begin
      fails++;
      $display("FAIL %-18s got=%08x want=%08x", what, got, want);
    end else begin
      $display("ok   %-18s %08x", what, got);
    end
  endtask

  logic [31:0] d;
  localparam logic [31:0] A = 32'h0000_2000;
  localparam logic [31:0] OLD = 32'h1111_0000;
  localparam logic [31:0] NEW = 32'h2222_0000;

  initial begin
    for (int i = 0; i < 65536; i++) mem[i] = 8'd0;

    // ---- H-05: hit-capture vs same-cycle snoop -----------------------------
    // The line is cached with OLD and the read window is armed. The backing then
    // becomes NEW and a snoop for that line lands on the same clock as the next
    // request. The captured window must NOT be acked; the read must refill.
    reset_dut();
    seed_line(A, OLD);
    read_word(A, d);
    if (d !== OLD) $fatal(1, "setup fill failed");
    seed_line(A, NEW);
    @(negedge clk);
    c_req = 1'b1;
    c_addr = A;
    snoop_inv_valid = 1'b1;
    snoop_inv_addr = A;
    @(posedge clk);
    #1;
    // The defect was: c_ack=1 with c_rdata==OLD on this very clock.
    checks++;
    if (c_ack && c_rdata === OLD) begin
      fails++;
      $display("FAIL hit_snoop_race    acked stale %08x (backing %08x)", c_rdata, rd32(A));
    end else begin
      $display("ok   hit_snoop_race    no stale ack (ack=%0d)", c_ack);
    end
    @(negedge clk);
    c_req = 1'b0;
    snoop_inv_valid = 1'b0;
    // ...and the value the core eventually gets must be the new one.
    read_word(A, d);
    expect_eq("hit_snoop_value", d, NEW);

    // ---- H-06: flush_all during a fill -------------------------------------
    // flush_all arrives after beat 0. The in-flight fill must be cancelled, not
    // merely have its (not yet written) valid bit cleared.
    reset_dut();
    seed_line(A, OLD);
    @(negedge clk);
    c_req = 1'b1;
    c_addr = A;
    wait (dut.st == 2'd1 && dut.fw == 3'd1);
    @(negedge clk);
    seed_line(A, NEW);
    flush_all = 1'b1;
    @(negedge clk);
    flush_all = 1'b0;
    begin
      int guard = 0;
      forever begin
        @(posedge clk);
        #1;
        if (c_ack) break;
        guard++;
        if (guard > 80) $fatal(1, "flush race timeout");
      end
    end
    // This first ack may legitimately still carry the in-flight beats; what must
    // NOT happen is the line staying resident with pre-flush contents.
    @(negedge clk);
    c_req = 1'b0;
    read_word(A, d);
    expect_eq("flush_during_fill", d, NEW);

    // ---- H-07: line snoop during a fill ------------------------------------
    reset_dut();
    seed_line(A, OLD);
    @(negedge clk);
    c_req = 1'b1;
    c_addr = A;
    wait (dut.st == 2'd1 && dut.fw == 3'd1);
    @(negedge clk);
    seed_line(A, NEW);
    snoop_inv_valid = 1'b1;
    snoop_inv_addr = A;
    @(negedge clk);
    snoop_inv_valid = 1'b0;
    begin
      int guard = 0;
      forever begin
        @(posedge clk);
        #1;
        if (c_ack) break;
        guard++;
        if (guard > 80) $fatal(1, "fill snoop race timeout");
      end
    end
    @(negedge clk);
    c_req = 1'b0;
    read_word(A, d);
    expect_eq("snoop_during_fill", d, NEW);

    // ---- H-05b: snoop on the SERVE clock, not the capture clock ------------
    // The fix above suppresses the CAPTURE while a snoop is in flight. The read
    // window lives one clock, so there is a second, adjacent window: the snoop can
    // instead land on the clock the captured word is being ACKED (c_ack comes from
    // rd_match, which compares only the address and never re-checks tag/valid).
    // Probing it explicitly rather than assuming the one-clock lifetime makes it
    // unreachable.
    // SAMPLING NOTE (REVIEW2 H-13 / M-09). The first version of this check sampled
    // with `@(posedge clk); #1;` -- i.e. AFTER the nonblocking updates of that edge.
    // That is NOT where the core looks. c_ack/c_rdata are combinational; the core's
    // always_ff captures whatever they hold as the posedge arrives. Sampling after
    // the edge sees rd_armed already cleared and reports a pass while the core
    // latched the stale value. It made this exact test green over a live bug.
    //
    // So sample in the SETTLED LOW PHASE, just before the posedge the core uses --
    // the same values the core's sequential logic will capture.
    reset_dut();
    seed_line(A, OLD);
    read_word(A, d);                      // line resident
    if (d !== OLD) $fatal(1, "setup fill failed");
    seed_line(A, NEW);
    @(negedge clk);
    c_req = 1'b1; c_addr = A;             // clock 1: capture (no snoop yet)
    @(posedge clk);
    @(negedge clk);
    snoop_inv_valid = 1'b1;               // clock 2: snoop lands on the serve clock
    snoop_inv_addr  = A;
    #4;                                   // settled, still BEFORE the posedge at +5
    checks++;
    if (c_ack && c_rdata === OLD) begin
      fails++;
      $display("FAIL serve_clk_snoop  core would latch stale %08x (backing %08x)",
               c_rdata, rd32(A));
    end else begin
      $display("ok   serve_clk_snoop  no stale ack at the core's sampling edge (ack=%0d)",
               c_ack);
    end
    @(posedge clk);
    @(negedge clk);
    c_req = 1'b0; snoop_inv_valid = 1'b0;
    read_word(A, d);
    expect_eq("serve_clk_value", d, NEW);

    // ---- H-19: non-cacheable read crossing a 32-byte line boundary ---------
    // The bypass buffer held ONE line and hard-zeroed the top of the window, so a
    // dword at offsets 29..31 returned its high bytes as ZEROS -- corrupt data in
    // exactly the MMIO / CR0.CD path where a wrong value means a wrong device access.
    // Seed the two lines with distinguishable patterns and read across the seam.
    reset_dut();
    cacheable = 1'b0;                  // KEN# negated -> bypass path
    // line at A: bytes 0..31 = 0x00..0x1F ; next line: bytes 0..31 = 0xA0..0xBF
    for (int b = 0; b < 32; b++) mem[A + b]      = 8'(b);
    for (int b = 0; b < 32; b++) mem[A + 32 + b] = 8'hA0 + 8'(b);
    // dword at offset 30 spans bytes 30,31 of this line and 0,1 of the next:
    //   expect {0xA1, 0xA0, 0x1F, 0x1E} little-endian = 32'hA1A0_1F1E
    read_word(A + 30, d);
    expect_eq("byp_cross_line", d, 32'hA1A0_1F1E);
    // and a fully in-line bypass read must still be right
    read_word(A + 4, d);
    expect_eq("byp_in_line", d, 32'h07060504);
    cacheable = 1'b1;

    // ---- control: with NO invalidation the line stays cached ---------------
    // Guards against "fixing" the races by never caching anything.
    reset_dut();
    seed_line(A, OLD);
    read_word(A, d);
    expect_eq("no_inv_first", d, OLD);
    seed_line(A, NEW);                  // backing changes, but nobody told the L1
    read_word(A, d);
    expect_eq("no_inv_cached", d, OLD); // MUST still hit the cached copy

    if (fails == 0)
      $display("L1D_COHERENCE: PASS  (%0d checks, 0 failures)", checks);
    else
      $display("L1D_COHERENCE: FAIL  (%0d checks, %0d failures)", checks, fails);
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "global timeout");
  end
endmodule
