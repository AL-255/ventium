`timescale 1ns/1ps
module tb_p54_pair_dtlb;
  logic clk = 0, rst_n = 0;
  always #5 clk = !clk;
  logic [31:0] lk_lin = 0, next_lin = 0, pair_lin = 0;
  logic lk_hit, next_hit, pair_hit;
  logic [31:0] lk_phys, next_phys, pair_phys;
  logic [2:0] lk_perm, next_perm, pair_perm;
  logic lk_dirty, next_dirty, pair_dirty;
  logic fill_en = 0, fill_big = 0, fill_dirty = 0, flush_en = 0;
  logic [31:0] fill_lin = 0;
  logic [19:0] fill_pfn = 0;
  logic [2:0] fill_perm = 0;
  int checks = 0;

`ifdef TB_ASSOC
  tlb_assoc #(.IS_D(1'b1), .TLB_SETS(16), .TLB_WAYS(4)) dut (.*);
`else
  tlb #(.IS_D(1'b1), .TLB_ENTRIES(16)) dut (.*);
`endif

  task automatic step;
    @(posedge clk); #1;
  endtask

  task automatic fill(input logic [31:0] lin, input logic [19:0] pfn,
                      input logic [2:0] perm, input logic dirty,
                      input logic big);
    @(negedge clk);
    fill_lin = lin; fill_pfn = pfn; fill_perm = perm;
    fill_dirty = dirty; fill_big = big; fill_en = 1;
    step();
    @(negedge clk); fill_en = 0;
  endtask

  initial begin
    repeat (2) step();
    @(negedge clk); rst_n = 1;
    pair_lin = 32'h1234_5064;
    lk_lin = 32'h1234_5070;
    next_lin = 32'h1234_5080;
    #1;
    if (pair_hit || lk_hit || next_hit) $fatal(1,"reset left valid entry");
    checks++;

    // A fill is visible only after its edge on all three independent ports.
    fill_lin = 32'h1234_5000; fill_pfn = 20'hab123;
    fill_perm = 3'b101; fill_dirty = 0; fill_en = 1;
    #1;
    if (pair_hit) $fatal(1,"V lookup bypassed pre-edge fill");
    step();
    if (!pair_hit || !lk_hit || !next_hit ||
        pair_phys != 32'hab123064 || lk_phys != 32'hab123070 ||
        next_phys != 32'hab123080 || pair_perm != 3'b101 || pair_dirty)
      $fatal(1,"three-port translation/payload mismatch");
    checks++;
    @(negedge clk); fill_en = 0;

    // U and lookahead can change independently, including to misses, without
    // reselecting V's physical frame or permission payload.
    lk_lin = 32'h8899_5070; next_lin = 32'h0000_0080;
    #1;
    if (lk_hit || next_hit || !pair_hit || pair_phys != 32'hab123064 ||
        pair_perm != 3'b101 || pair_dirty)
      $fatal(1,"other queries steered V translation");
    checks++;

    // Same-set replacement distinguishes the direct-map and four-way probes.
    fill(32'h2234_5000, 20'hbc234, 3'b111, 1'b1, 1'b0);
    pair_lin = 32'h2234_50a8;
    #1;
    if (!pair_hit || pair_phys != 32'hbc2340a8 || pair_perm != 3'b111 ||
        !pair_dirty) $fatal(1,"V selected wrong same-set payload");
    checks++;
    pair_lin = 32'h1234_5064;
    #1;
`ifdef TB_ASSOC
    if (!pair_hit || pair_phys != 32'hab123064 || pair_perm != 3'b101)
      $fatal(1,"associative V port lost independent way");
`else
    if (pair_hit) $fatal(1,"direct-map same-set victim survived");
`endif
    checks++;

    // Large-page offset and a flush of valid bits on the V port.
    fill(32'h1200_5000, 20'habc00, 3'b111, 1'b1, 1'b1);
    pair_lin = 32'h1200_5abc;
    #1;
    if (!pair_hit || pair_phys != {10'h2af,22'h5abc} || !pair_dirty)
      $fatal(1,"large-page V physical offset mismatch got=%h",pair_phys);
    checks++;
    @(negedge clk); flush_en = 1;
    step();
    if (pair_hit || lk_hit || next_hit) $fatal(1,"flush left a valid lookup");
    checks++;
    $display("P54-PAIR-DTLB-OK checks=%0d assoc=%0d",checks,
`ifdef TB_ASSOC
             1
`else
             0
`endif
    );
    $finish;
  end
endmodule
