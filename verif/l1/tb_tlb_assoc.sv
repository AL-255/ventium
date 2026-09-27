// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Standalone reference-model gate for the default-off associative D-TLB
// experiment.  The existing tb_tlb remains the regression for the deployed
// 16-entry direct map; this test deliberately exercises both 2-way and 4-way
// geometries through its top-level WAYS parameter.

module tb_tlb_assoc #(
    parameter int WAYS = 2
);
  localparam int SETS = 16;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] d_lk_lin = 0;
  logic d_lk_hit;
  logic [31:0] d_lk_phys;
  logic [2:0] d_lk_perm;
  logic d_lk_dirty;
  logic d_fill_en = 0;
  logic [31:0] d_fill_lin = 0;
  logic [19:0] d_fill_pfn = 0;
  logic [2:0] d_fill_perm = 0;
  logic d_fill_big = 0;
  logic d_fill_dirty = 0;
  logic d_flush_en = 0;

  // A separate I-side instance establishes that an I fill never exposes a
  // dirty bit, independent of the D-side geometry being tested.
  logic [31:0] i_lk_lin = 0;
  logic i_lk_hit;
  logic [31:0] i_lk_phys;
  logic [2:0] i_lk_perm;
  logic i_lk_dirty;
  logic i_fill_en = 0;
  logic [31:0] i_fill_lin = 0;
  logic [19:0] i_fill_pfn = 0;
  logic [2:0] i_fill_perm = 0;
  logic i_fill_big = 0;
  logic i_fill_dirty = 0;
  logic i_flush_en = 0;

  tlb_assoc #(.IS_D(1'b1), .TLB_SETS(SETS), .TLB_WAYS(WAYS)) dut (
`ifdef VEN_PIPE_MEM_CHAIN
      .next_lin(32'd0), .next_hit(), .next_phys(), .next_perm(), .next_dirty(),
`endif

      .clk, .rst_n,
      .lk_lin(d_lk_lin), .lk_hit(d_lk_hit), .lk_phys(d_lk_phys),
      .lk_perm(d_lk_perm), .lk_dirty(d_lk_dirty),
      .fill_en(d_fill_en), .fill_lin(d_fill_lin), .fill_pfn(d_fill_pfn),
      .fill_perm(d_fill_perm), .fill_big(d_fill_big), .fill_dirty(d_fill_dirty),
      .flush_en(d_flush_en)
  );
  tlb_assoc #(.IS_D(1'b0), .TLB_SETS(SETS), .TLB_WAYS(2)) u_itlb (
`ifdef VEN_PIPE_MEM_CHAIN
      .next_lin(32'd0), .next_hit(), .next_phys(), .next_perm(), .next_dirty(),
`endif

      .clk, .rst_n,
      .lk_lin(i_lk_lin), .lk_hit(i_lk_hit), .lk_phys(i_lk_phys),
      .lk_perm(i_lk_perm), .lk_dirty(i_lk_dirty),
      .fill_en(i_fill_en), .fill_lin(i_fill_lin), .fill_pfn(i_fill_pfn),
      .fill_perm(i_fill_perm), .fill_big(i_fill_big), .fill_dirty(i_fill_dirty),
      .flush_en(i_flush_en)
  );

  // Independent software model of the documented initial experiment policy:
  // matching tag -> first invalid way -> fill-only round-robin victim.
  logic        m_val   [SETS][WAYS];
  logic [19:0] m_vpn   [SETS][WAYS];
  logic [19:0] m_pfn   [SETS][WAYS];
  logic [2:0]  m_perm  [SETS][WAYS];
  logic        m_big   [SETS][WAYS];
  logic        m_dirty [SETS][WAYS];
  int          m_rr    [SETS];
  int errors = 0;

  function automatic logic [31:0] mk_lin(
      input logic [3:0] set, input logic [15:0] tag, input logic [11:0] off);
    mk_lin = {tag, set, off};
  endfunction

  function automatic logic [31:0] expected_phys(
      input logic [31:0] lin, input logic [19:0] pfn, input logic big);
    expected_phys = big ? {pfn[19:10], lin[21:0]} : {pfn, lin[11:0]};
  endfunction

  task automatic ck_bit(input string what, input logic got, input logic exp);
    if (got !== exp) begin
      $display("  FAIL %s: got=%b exp=%b", what, got, exp);
      errors++;
    end
  endtask
  task automatic ck_vec32(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("  FAIL %s: got=%08x exp=%08x", what, got, exp);
      errors++;
    end
  endtask
  task automatic ck_vec3(input string what, input logic [2:0] got, input logic [2:0] exp);
    if (got !== exp) begin
      $display("  FAIL %s: got=%03b exp=%03b", what, got, exp);
      errors++;
    end
  endtask

  task automatic model_reset;
    for (int s = 0; s < SETS; s++) begin
      m_rr[s] = 0;
      for (int w = 0; w < WAYS; w++) begin
        m_val[s][w] = 0;
        m_vpn[s][w] = 0;
        m_pfn[s][w] = 0;
        m_perm[s][w] = 0;
        m_big[s][w] = 0;
        m_dirty[s][w] = 0;
      end
    end
  endtask

  task automatic model_flush;
    for (int s = 0; s < SETS; s++)
      for (int w = 0; w < WAYS; w++) m_val[s][w] = 0;
  endtask

  task automatic model_fill(input logic [31:0] lin, input logic [19:0] pfn,
                            input logic [2:0] perm, input logic big, input logic dirty);
    int set;
    int same;
    int invalid;
    int chosen;
    set = int'(lin[15:12]);
    same = -1;
    invalid = -1;
    for (int w = 0; w < WAYS; w++) begin
      if ((same < 0) && m_val[set][w] && (m_vpn[set][w] == lin[31:12])) same = w;
      if ((invalid < 0) && !m_val[set][w]) invalid = w;
    end
    if (same >= 0) chosen = same;
    else if (invalid >= 0) chosen = invalid;
    else chosen = m_rr[set];
    if (same < 0) m_rr[set] = (chosen + 1) % WAYS;
    m_val[set][chosen] = 1'b1;
    m_vpn[set][chosen] = lin[31:12];
    m_pfn[set][chosen] = pfn;
    m_perm[set][chosen] = perm;
    m_big[set][chosen] = big;
    m_dirty[set][chosen] = dirty;
  endtask

  task automatic d_fill(input logic [31:0] lin, input logic [19:0] pfn,
                        input logic [2:0] perm, input logic big, input logic dirty);
    model_fill(lin, pfn, perm, big, dirty);
    @(negedge clk);
    d_fill_en <= 1'b1;
    d_fill_lin <= lin;
    d_fill_pfn <= pfn;
    d_fill_perm <= perm;
    d_fill_big <= big;
    d_fill_dirty <= dirty;
    @(negedge clk);
    d_fill_en <= 1'b0;
  endtask

  task automatic d_flush;
    model_flush();
    @(negedge clk); d_flush_en <= 1'b1;
    @(negedge clk); d_flush_en <= 1'b0;
  endtask

  task automatic d_probe_model(input string what, input logic [31:0] lin);
    int set;
    int match;
    logic exp_hit;
    set = int'(lin[15:12]);
    match = 0;
    exp_hit = 1'b0;
    for (int w = 0; w < WAYS; w++) begin
      if (!exp_hit && m_val[set][w] && (m_vpn[set][w] == lin[31:12])) begin
        exp_hit = 1'b1;
        match = w;
      end
    end
    @(negedge clk); d_lk_lin <= lin;
    @(posedge clk); #1;
    ck_bit({what, " hit"}, d_lk_hit, exp_hit);
    if (exp_hit) begin
      ck_vec32({what, " phys"}, d_lk_phys, expected_phys(lin, m_pfn[set][match], m_big[set][match]));
      ck_vec3({what, " perm"}, d_lk_perm, m_perm[set][match]);
      ck_bit({what, " dirty"}, d_lk_dirty, m_dirty[set][match]);
    end
  endtask

  task automatic no_duplicate_tag(input string what, input logic [3:0] set);
    for (int a = 0; a < WAYS; a++) begin
      for (int b = a + 1; b < WAYS; b++) begin
        ck_bit($sformatf("%s duplicate a=%0d b=%0d", what, a, b),
               dut.tlb_val[int'(set)*WAYS+a] && dut.tlb_val[int'(set)*WAYS+b] &&
               (dut.tlb_vpn[int'(set)*WAYS+a] == dut.tlb_vpn[int'(set)*WAYS+b]), 1'b0);
      end
    end
  endtask

  task automatic i_fill(input logic [31:0] lin, input logic [19:0] pfn,
                        input logic [2:0] perm, input logic big, input logic dirty);
    @(negedge clk);
    i_fill_en <= 1'b1;
    i_fill_lin <= lin;
    i_fill_pfn <= pfn;
    i_fill_perm <= perm;
    i_fill_big <= big;
    i_fill_dirty <= dirty;
    @(negedge clk); i_fill_en <= 1'b0;
  endtask

  task automatic i_probe(input string what, input logic [31:0] lin,
                         input logic [31:0] phys, input logic [2:0] perm);
    @(negedge clk); i_lk_lin <= lin;
    @(posedge clk); #1;
    ck_bit({what, " hit"}, i_lk_hit, 1'b1);
    ck_vec32({what, " phys"}, i_lk_phys, phys);
    ck_vec3({what, " perm"}, i_lk_perm, perm);
    ck_bit({what, " dirty ignored"}, i_lk_dirty, 1'b0);
  endtask

  initial begin : test
    logic [31:0] lin [WAYS+2];
    logic [31:0] same_lin;
    logic [31:0] big_lin;
    logic [31:0] seed;
    logic [31:0] rlin;
    logic [19:0] rpfn;

    model_reset();
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);

    // Reset is a complete valid-bit reset.  The model starts empty as well.
    d_probe_model("reset miss", mk_lin(4'h4, 16'h1000, 12'h123));

    // W distinct aliases of one [15:12] set all survive with their own payload.
    for (int w = 0; w < WAYS; w++) begin
      lin[w] = mk_lin(4'h4, 16'h1100 + w, 12'h020 + w);
      d_fill(lin[w], 20'h12000 + w, w[2:0], w[0], w[0]);
    end
    for (int w = 0; w < WAYS; w++)
      d_probe_model($sformatf("all-way alias %0d", w), lin[w]);

    // The W+1th tag takes deterministic RR victim way 0.  A second extra fill
    // proves that RR wraps to way 1 rather than repeatedly evicting way 0.
    lin[WAYS] = mk_lin(4'h4, 16'h1200, 12'h0aa);
    d_fill(lin[WAYS], 20'h13000, 3'b101, 1'b0, 1'b1);
    d_probe_model("rr first newcomer", lin[WAYS]);
    d_probe_model("rr victim zero", lin[0]);
    lin[WAYS+1] = mk_lin(4'h4, 16'h1201, 12'h0ab);
    d_fill(lin[WAYS+1], 20'h13001, 3'b110, 1'b1, 1'b0);
    d_probe_model("rr second newcomer", lin[WAYS+1]);
    d_probe_model("rr victim one", lin[1]);

    // A D clean->dirty rewalk is a SAME-VPN refill, not a new allocation.  Its
    // updated payload must be selected atomically and it must leave no duplicate.
    same_lin = mk_lin(4'h5, 16'h2201, 12'h345);
    d_fill(same_lin, 20'h14000, 3'b001, 1'b0, 1'b0);
    d_fill(same_lin, 20'h15000, 3'b110, 1'b0, 1'b1);
    d_probe_model("same-vpn dirty refill", same_lin);
    no_duplicate_tag("same-vpn dirty refill", 4'h5);

    // A different set does not perturb the alias set's survivor/rr state.
    d_fill(mk_lin(4'h6, 16'h3300, 12'h010), 20'h16000, 3'b011, 1'b0, 1'b1);
    d_probe_model("cross-set independent", lin[WAYS]);

    // Preserve the direct-map big-page compatibility contract deliberately:
    // 4 MiB physical offset, but a full 4 KiB VPN tag.  A different 4 KiB
    // subpage of the same 4 MiB region is therefore a MISS in this experiment.
    big_lin = mk_lin(4'h9, 16'h3333, 12'h345);
    d_fill(big_lin, 20'ha5c00, 3'b101, 1'b1, 1'b1);
    d_probe_model("legacy big exact subpage", big_lin);
    d_probe_model("legacy big different subpage", big_lin ^ 32'h0001_0000);

    // Flush wins over a simultaneous fill, exactly like tlb.sv's single write
    // port.  The model sees only the flush because the fill must not commit.
    model_flush();
    @(negedge clk);
    d_fill_en <= 1'b1;
    d_fill_lin <= mk_lin(4'h7, 16'h4400, 12'h000);
    d_fill_pfn <= 20'h17000;
    d_fill_perm <= 3'b111;
    d_fill_big <= 1'b0;
    d_fill_dirty <= 1'b1;
    d_flush_en <= 1'b1;
    @(negedge clk);
    d_fill_en <= 1'b0;
    d_flush_en <= 1'b0;
    d_probe_model("flush beats fill", mk_lin(4'h7, 16'h4400, 12'h000));

    // No combinational bypass: the same lookup misses before the fill edge and
    // hits immediately after that edge.  Add it to the model at the edge.
    rlin = mk_lin(4'h8, 16'h5500, 12'h222);
    @(negedge clk);
    d_lk_lin <= rlin;
    d_fill_en <= 1'b1;
    d_fill_lin <= rlin;
    d_fill_pfn <= 20'h18000;
    d_fill_perm <= 3'b010;
    d_fill_big <= 1'b0;
    d_fill_dirty <= 1'b1;
    #1;
    ck_bit("pre-fill lookup remains miss", d_lk_hit, 1'b0);
    model_fill(rlin, 20'h18000, 3'b010, 1'b0, 1'b1);
    @(posedge clk); #1;
    ck_bit("post-fill lookup hit", d_lk_hit, 1'b1);
    ck_vec32("post-fill lookup phys", d_lk_phys, 32'h18000222);
    @(negedge clk); d_fill_en <= 1'b0;

    // I-side dirty is architecturally suppressed even if the producer supplies
    // fill_dirty=1.  This also checks that a second associative instance does
    // not share D-side state.
    i_fill(mk_lin(4'h2, 16'h6600, 12'h111), 20'h19000, 3'b100, 1'b0, 1'b1);
    i_probe("I dirty suppression", mk_lin(4'h2, 16'h6600, 12'h111), 32'h19000111, 3'b100);

    // Short deterministic randomized model sweep: mixed sets, fills, lookups,
    // same-VPN refills, big entries, and flushes.  Every lookup compares all
    // architecturally meaningful output fields against the independent model.
    seed = 32'h1bad_f00d;
    for (int n = 0; n < 160; n++) begin
      seed = seed * 32'h0019_660d + 32'h3c6e_f35f;
      rlin = mk_lin(seed[3:0], seed[31:16], seed[11:0]);
      rpfn = seed[31:12] ^ 20'h0a55a;
      case (seed[3:0])
        4'h0, 4'h1: d_flush();
        4'h2, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9:
          d_fill(rlin, rpfn, seed[14:12], seed[15], seed[16]);
        default: d_probe_model($sformatf("random %0d", n), rlin);
      endcase
    end
    for (int s = 0; s < SETS; s++) no_duplicate_tag($sformatf("random set %0d", s), s[3:0]);

    if (errors == 0) $display("TLB-ASSOC-GATE-OK (%0d-way)", WAYS);
    else             $display("TLB-ASSOC-GATE-FAIL (%0d errors, %0d-way)", errors, WAYS);
    $finish;
  end

  initial begin
    #500000;
    $display("TLB-ASSOC-GATE-FAIL (timeout, %0d-way)", WAYS);
    $finish;
  end
endmodule
