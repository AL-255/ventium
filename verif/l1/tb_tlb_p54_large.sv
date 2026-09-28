`timescale 1ns/1ps
module tb_tlb_p54_large;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;
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

  tlb_assoc #(.IS_D(1'b1), .TLB_SETS(16), .TLB_WAYS(4),
              .P54_LARGE(1'b1)) dut (.*);

  task automatic fill(input logic [31:0] lin, input logic [31:0] phys,
                      input bit large_page, input logic [2:0] perm,
                      input bit dirty);
    @(negedge clk);
    fill_lin = lin;
    fill_pfn = phys[31:12];
    fill_big = large_page;
    fill_perm = perm;
    fill_dirty = dirty;
    fill_en = 1;
    @(negedge clk);
    fill_en = 0;
  endtask

  task automatic check_hit(input logic [31:0] lin, input logic [31:0] phys,
                           input logic [2:0] perm, input bit dirty);
    lk_lin = lin;
    next_lin = lin;
    pair_lin = lin;
    #1;
    if (!lk_hit || !next_hit || !pair_hit ||
        lk_phys !== phys || next_phys !== phys || pair_phys !== phys ||
        lk_perm !== perm || next_perm !== perm || pair_perm !== perm ||
        lk_dirty !== dirty || next_dirty !== dirty || pair_dirty !== dirty)
      $fatal(1, "P54 DTLB hit mismatch lin=%08h expected=%08h: primary=%b/%08h/%b/%b next=%b/%08h/%b/%b pair=%b/%08h/%b/%b",
             lin, phys, lk_hit, lk_phys, lk_perm, lk_dirty,
             next_hit, next_phys, next_perm, next_dirty,
             pair_hit, pair_phys, pair_perm, pair_dirty);
    checks++;
  endtask

  task automatic check_miss(input logic [31:0] lin);
    lk_lin = lin;
    next_lin = lin;
    pair_lin = lin;
    #1;
    if (lk_hit || next_hit || pair_hit)
      $fatal(1, "P54 DTLB unexpected hit lin=%08h", lin);
    checks++;
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    check_miss(32'h0400_0000);
    check_miss(32'h0040_0000);

    // Four colliding 4 KiB translations remain in the original small bank.
    for (int i = 0; i < 4; i++)
      fill(32'h0040_0000 + (32'(i) << 16),
           32'h0080_0000 + (32'(i) << 12), 0, 3'b011, 0);
    for (int i = 0; i < 4; i++)
      check_hit(32'h0040_0324 + (32'(i) << 16),
                32'h0080_0324 + (32'(i) << 12), 3'b011, 0);

    // One large translation covers every 4 KiB subpage without extra fills.
    fill(32'h0400_0000, 32'h0800_0000, 1, 3'b101, 0);
    check_hit(32'h0400_0000, 32'h0800_0000, 3'b101, 0);
    check_hit(32'h0400_1004, 32'h0800_1004, 3'b101, 0);
    check_hit(32'h043f_fffc, 32'h083f_fffc, 3'b101, 0);
    check_miss(32'h0440_0000);
    for (int i = 0; i < 4; i++)
      check_hit(32'h0040_0324 + (32'(i) << 16),
                32'h0080_0324 + (32'(i) << 12), 3'b011, 0);

    // Dirty refill must replace the same large tag, not allocate a duplicate.
    fill(32'h0400_2000, 32'h0c00_0000, 1, 3'b111, 1);
    check_hit(32'h043f_fffc, 32'h0c3f_fffc, 3'b111, 1);
    fill(32'h0480_0000, 32'h1000_0000, 1, 3'b011, 0);
    fill(32'h0500_0000, 32'h1400_0000, 1, 3'b011, 0);
    fill(32'h0580_0000, 32'h1800_0000, 1, 3'b011, 0);
    check_hit(32'h0400_0008, 32'h0c00_0008, 3'b111, 1);
    check_hit(32'h0480_0008, 32'h1000_0008, 3'b011, 0);
    check_hit(32'h0500_0008, 32'h1400_0008, 3'b011, 0);
    check_hit(32'h0580_0008, 32'h1800_0008, 3'b011, 0);

    // A fifth set-0 allocation evicts exactly the round-robin victim.
    fill(32'h0600_0000, 32'h1c00_0000, 1, 3'b011, 0);
    check_miss(32'h0400_0008);
    check_hit(32'h0600_0008, 32'h1c00_0008, 3'b011, 0);
    check_hit(32'h0480_0008, 32'h1000_0008, 3'b011, 0);

    // Independent set-1 storage and all three side-effect-free read ports.
    fill(32'h0440_0000, 32'h2000_0000, 1, 3'b110, 1);
    lk_lin = 32'h0440_1234;
    next_lin = 32'h0600_5678;
    pair_lin = 32'h0500_9abc;
    #1;
    if (!lk_hit || lk_phys !== 32'h2000_1234 || lk_perm !== 3'b110 || !lk_dirty ||
        !next_hit || next_phys !== 32'h1c00_5678 ||
        !pair_hit || pair_phys !== 32'h1400_9abc)
      $fatal(1, "P54 DTLB independent ports/selectors failed");
    checks++;

    // If both banks match after a software remap without an invalidation,
    // Intel's documented large-page priority chooses the 4 MiB payload.
    fill(32'h0500_1000, 32'h2800_0000, 0, 3'b001, 0);
    check_hit(32'h0500_1004, 32'h1400_1004, 3'b011, 0);

    @(negedge clk);
    flush_en = 1;
    @(negedge clk);
    flush_en = 0;
    check_miss(32'h0500_1004);
    check_miss(32'h0040_0324);
    check_miss(32'h0440_1234);
    // Flush outranks a coincident walker fill, including the large bank.
    @(negedge clk);
    fill_lin = 32'h0400_0000;
    fill_pfn = 20'h0c000;
    fill_big = 1;
    fill_perm = 3'b111;
    fill_en = 1;
    flush_en = 1;
    @(negedge clk);
    fill_en = 0;
    flush_en = 0;
    check_miss(32'h0400_0000);
    $display("P54-LARGE-DTLB-OK checks=%0d", checks);
    $finish;
  end
endmodule
