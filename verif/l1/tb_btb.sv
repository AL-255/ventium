// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/l1/tb_btb.sv — standalone self-checking gate + breadth-coverage sweep for
// rtl/core/bpred_btb.sv (the 64-set x 4-way branch-target buffer: dual predict
// ports + a resolve/train port with 2-bit saturating counters). Core-internal,
// only hit via the cyc lane at ~55% toggle; this TB trains all 256 entries with
// diverse tags and saturates every counter both directions so btb_tag/btb_ctr/
// btb_val/btb_rr and the lookup datapath toggle. Prints BTB-GATE-OK / BTB-GATE-FAIL.
module tb_btb;
  localparam int SETS = 64, WAYS = 4;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;

  logic [31:0] u_query_pc = 0, v_query_pc = 0; logic u_predict_taken, v_predict_taken;
  logic        resolve_valid = 0; logic [31:0] resolve_pc = 0; logic resolve_taken = 0;
  int errors = 0;

  bpred_btb #(.BTB_SETS(SETS), .BTB_WAYS(WAYS)) dut (
      .clk, .rst_n, .u_query_pc, .u_predict_taken, .v_query_pc, .v_predict_taken,
      .resolve_valid, .resolve_pc, .resolve_taken);

  // pc with set = s (pc[5:0]) and a diverse tag (pc[31:6])
  function automatic logic [31:0] mk_pc(input int s, input logic [25:0] tag);
    mk_pc = {tag, 6'(s)};
  endfunction

  task automatic resolve(input [31:0] pc, input logic taken);
    @(negedge clk); resolve_valid <= 1; resolve_pc <= pc; resolve_taken <= taken;
    @(negedge clk); resolve_valid <= 0;
  endtask
  task automatic query(input [31:0] pcu, input [31:0] pcv);
    @(negedge clk); u_query_pc <= pcu; v_query_pc <= pcv; @(posedge clk); #1;
  endtask

  initial begin
    repeat (3) @(posedge clk); rst_n <= 1; @(posedge clk);

    // [1] allocate WALKING-BIT tags (and complements) into every set -> the 4 ways
    //     cycle through diverse tags via the round-robin ptr, so btb_tag toggles all
    //     26 bits both directions, btb_val 0->1, btb_rr cycles.
    for (int s = 0; s < SETS; s++)
      for (int t = 0; t < 64; t++) begin
        logic [25:0] tag;
        case (t % 4)                            // rich patterns so each of the 4 ways
          0: tag = 26'h1 << (t % 26);           // (round-robin) sees diverse tags that
          1: tag = ~(26'h1 << (t % 26));        // collectively toggle all 26 bits both
          2: tag = 26'h2AA_AAAA ^ 26'(t * 11);  // ways -> btb_tag toggles broadly
          3: tag = 26'h155_5555 ^ 26'(t * 23);
        endcase
        resolve(mk_pc(s, tag), 1'b1);           // taken -> a miss ALWAYS allocates
      end

    // [2] saturate every set's counters BOTH directions (00<->11) on a fixed tag
    for (int s = 0; s < SETS; s++) begin
      logic [31:0] pc = mk_pc(s, 26'(s * 13 + 1));
      resolve(pc, 1'b1); resolve(pc, 1'b1); resolve(pc, 1'b1);   // saturate up -> ctr=11
      resolve(pc, 1'b0); resolve(pc, 1'b0); resolve(pc, 1'b0);   // saturate down -> ctr=00
      resolve(pc, 1'b1);                                         // back up -> ctr=01
    end

    // [3] diverse dual-port queries across the index/tag space (lookup datapath)
    for (int i = 0; i < 128; i++)
      query((32'hA5A5_A5A5 >> (i % 24)) ^ 32'(i),
            (32'h5A5A_5A5A >> (i % 22)) ^ 32'(i * 3));

    // [4] self-check: a freshly trained-taken entry must predict TAKEN, and an
    //     untrained alias in the same set must predict NOT-taken.
    resolve(32'h0001_2340, 1'b1); resolve(32'h0001_2340, 1'b1);  // ctr -> >=2
    query(32'h0001_2340, 32'h0001_2340);
    if (u_predict_taken !== 1'b1) begin $display("  FAIL trained entry not taken"); errors++; end
    query(32'hFFFF_0000, 32'hFFFF_0000);     // untrained tag
    if (u_predict_taken !== 1'b0) begin $display("  FAIL untrained entry taken"); errors++; end

    if (errors == 0) $display("BTB-GATE-OK (all checks pass)");
    else             $display("BTB-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #500000; $display("BTB-GATE-FAIL (timeout)"); $finish; end
endmodule
