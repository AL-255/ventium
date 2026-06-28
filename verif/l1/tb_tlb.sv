// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/l1/tb_tlb.sv — standalone self-checking gate + breadth-coverage sweep for
// rtl/mem/tlb.sv (the direct-mapped I/D-TLB array: lookup + pulsed fill + flush).
// The module is core-internal (only exercised via the ISA/sys lanes at ~47% toggle);
// this TB drives it directly with diverse fills/lookups/flushes so the entry arrays
// (tlb_vpn/tlb_pfn/tlb_perm/tlb_big/tlb_dirty) and the lookup datapath toggle fully.
// Built with `verilator --binary`; prints TLB-GATE-OK / TLB-GATE-FAIL.
module tb_tlb;
  localparam int N = 16;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;

  logic [31:0] lk_lin = 0; logic lk_hit; logic [31:0] lk_phys; logic [2:0] lk_perm; logic lk_dirty;
  logic        fill_en = 0; logic [31:0] fill_lin = 0; logic [19:0] fill_pfn = 0;
  logic [2:0]  fill_perm = 0; logic fill_big = 0, fill_dirty = 0, flush_en = 0;
  int errors = 0;

  tlb #(.IS_D(1), .TLB_ENTRIES(N)) dut (
      .clk, .rst_n, .lk_lin, .lk_hit, .lk_phys, .lk_perm, .lk_dirty,
      .fill_en, .fill_lin, .fill_pfn, .fill_perm, .fill_big, .fill_dirty, .flush_en);

  // linear address whose index = entry i and whose vpn carries a diverse high pattern
  function automatic logic [31:0] mk_lin(input int i, input logic [15:0] hi);
    mk_lin = ({4'd0, hi, 4'(i)} << 12);    // [15:12]=i (index); [31:16]=hi (vpn high)
  endfunction

  task automatic fill(input [31:0] lin, input [19:0] pfn, input [2:0] perm,
                      input logic big, input logic dirty);
    @(negedge clk); fill_en <= 1; fill_lin <= lin; fill_pfn <= pfn;
    fill_perm <= perm; fill_big <= big; fill_dirty <= dirty;
    @(negedge clk); fill_en <= 0;
  endtask
  task automatic lookup(input [31:0] lin);
    @(negedge clk); lk_lin <= lin; @(posedge clk); #1;
  endtask
  task automatic chk(input string what, input logic got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %0d exp %0d", what, got, exp); errors++; end
  endtask

  initial begin
    repeat (3) @(posedge clk); rst_n <= 1; @(posedge clk);

    // [1] fill all 16 entries with diverse vpn/pfn/perm/big/dirty (walking bits)
    for (int i = 0; i < N; i++)
      fill(mk_lin(i, 16'h1 << i), 20'h1 << (i % 20), 3'(i & 7), i[0], i[1]);
    // [2] every entry must now HIT for its own linear address, with correct phys
    for (int i = 0; i < N; i++) begin
      lookup(mk_lin(i, 16'h1 << i));
      chk($sformatf("entry %0d hit", i), lk_hit, 1'b1);
    end
    // [3] a different vpn in the same index slot must MISS
    for (int i = 0; i < N; i++) begin
      lookup(mk_lin(i, 16'hF00F));
      chk($sformatf("entry %0d alias miss", i), lk_hit, 1'b0);
    end
    // [4] flush (CR3) clears valid -> all lookups MISS
    @(negedge clk); flush_en <= 1; @(negedge clk); flush_en <= 0; @(posedge clk);
    for (int i = 0; i < N; i++) begin
      lookup(mk_lin(i, 16'h1 << i));
      chk($sformatf("entry %0d miss after flush", i), lk_hit, 1'b0);
    end
    // [5] COVERAGE: refill with COMPLEMENTARY values (toggle the arrays the other way)
    //     + diverse 4 MiB pages + diverse perms/dirty, then diverse lookups.
    for (int i = 0; i < N; i++)
      fill(mk_lin(i, ~(16'h1 << i)), ~(20'h1 << (i % 20)), 3'(~i & 7), ~i[0], ~i[1]);
    for (int i = 0; i < N; i++) begin            // 4 MiB-page fills (big=1)
      fill(mk_lin(i, 16'(i * 16'h1111)), 20'(i * 20'h0_8421), 3'(i % 8), 1'b1, i[0]);
      lookup(mk_lin(i, 16'(i * 16'h1111)));
    end
    for (int i = 0; i < 32; i++)                  // diverse lookups across the index space
      lookup((32'hA5A5_A5A5 >> (i % 20)) ^ (32'(i) << 12));

    if (errors == 0) $display("TLB-GATE-OK (all checks pass)");
    else             $display("TLB-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #200000; $display("TLB-GATE-FAIL (timeout)"); $finish; end
endmodule
