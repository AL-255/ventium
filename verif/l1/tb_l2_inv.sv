// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_l2_inv.sv — REVIEW1_Aug2 H-09: the L2 invalidation path must not LOSE
// invalidations, at any pulse rate, with no producer contract.
//
// The old design held ONE pending address and dropped invalidations two ways:
//
//   case 1  a second colliding pulse OVERWROTE the pending address. The older set was
//           never invalidated. (This one at least printed a $display warning.)
//
//   case 2  with the tag port FREE and one already pending, the mux selected the FRESH
//           address while the sequential block cleared l2_inv_pend on its
//           `else if (l2_inv_pend && !update_tag_we)` arm -- so the PENDING set was
//           retired without ever being applied. Nothing reported this one.
//
// A dropped invalidation leaves a stale line valid in L2: a later read returns data
// that DMA or another master has since overwritten. That is silent memory corruption,
// which is why "rare in practice" is not an argument.
//
// This gate drives the invalidation port directly and checks the SET OF SETS that
// actually got invalidated against the set of sets that were requested. It does not
// care about ordering or timing -- only that nothing is lost.

module tb_l2_inv;
  localparam int LINES     = 128;
  localparam int LINE_BITS = 7;
  localparam int LINESIZE  = 8;
  localparam int LSB       = 3;             // $clog2(LINESIZE)

  logic clk = 0; always #5 clk = ~clk;
  logic rst = 1;

  // Mirror of the DUT's invalidation front-end. The l2_cache module is deep in the
  // ao486 memory system and needs a full DDR/CPU harness to run standalone, so this
  // gate instantiates the invalidation LOGIC ITSELF -- the exact expressions from
  // l2_cache.v -- and drives it. That keeps the gate about the finding (is the skid
  // lossless?) instead of about booting a SoC.
  logic                 l2_inv_pulse;
  logic [31:0]          l2_inv_addr;
  logic                 update_tag_we;      // the state machine owning the tag port

  wire  [LINE_BITS-1:0] l2_inv_addr_idx = l2_inv_addr[LSB+LINE_BITS-1:LSB];

`ifdef H09_BROKEN
  // ---- the ORIGINAL one-entry skid, verbatim -------------------------------------
  logic                 l2_inv_pend;
  logic [LINE_BITS-1:0] l2_inv_pend_addr;
  always_ff @(posedge clk) begin
    if (rst) l2_inv_pend <= 1'b0;
    else begin
      if (l2_inv_pulse && update_tag_we) begin
        l2_inv_pend      <= 1'b1;
        l2_inv_pend_addr <= l2_inv_addr_idx;
      end else if (l2_inv_pend && !update_tag_we) begin
        l2_inv_pend <= 1'b0;
      end
    end
  end
  wire                  l2_inv_go   = !update_tag_we && (l2_inv_pulse || l2_inv_pend);
  wire [LINE_BITS-1:0]  l2_inv_go_a = l2_inv_pulse ? l2_inv_addr_idx : l2_inv_pend_addr;
`else
  // ---- the pending BITMAP -------------------------------------------------------
  logic [LINES-1:0]     l2_inv_pend_set;
  wire                  l2_inv_any = |l2_inv_pend_set;
  logic [LINE_BITS-1:0] l2_inv_drain_idx;
  integer               ii;
  always_comb begin
    l2_inv_drain_idx = '0;
    for (ii = LINES-1; ii >= 0; ii = ii - 1)
      if (l2_inv_pend_set[ii]) l2_inv_drain_idx = ii[LINE_BITS-1:0];
  end
  wire l2_inv_apply_fresh = !update_tag_we && l2_inv_pulse && !l2_inv_any;
  wire l2_inv_apply_pend  = !update_tag_we && l2_inv_any;
  always_ff @(posedge clk) begin
    if (rst) l2_inv_pend_set <= '0;
    else begin
      if (l2_inv_apply_pend)                   l2_inv_pend_set[l2_inv_drain_idx] <= 1'b0;
      if (l2_inv_pulse && !l2_inv_apply_fresh) l2_inv_pend_set[l2_inv_addr_idx]  <= 1'b1;
    end
  end
  wire                  l2_inv_go   = l2_inv_apply_fresh || l2_inv_apply_pend;
  wire [LINE_BITS-1:0]  l2_inv_go_a = l2_inv_apply_fresh ? l2_inv_addr_idx
                                                         : l2_inv_drain_idx;
`endif

  // ---- bookkeeping ---------------------------------------------------------------
  logic [LINES-1:0] requested, invalidated;
  int req_n, inv_n;

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (l2_inv_pulse) begin requested[l2_inv_addr_idx] <= 1'b1; req_n <= req_n + 1; end
      if (l2_inv_go)    begin invalidated[l2_inv_go_a]   <= 1'b1; inv_n <= inv_n + 1; end
    end
  end

  task automatic pulse(input int set_idx, input bit busy);
    begin
      @(negedge clk);
      l2_inv_addr   = set_idx << LSB;
      l2_inv_pulse  = 1'b1;
      update_tag_we = busy;
      @(negedge clk);
      l2_inv_pulse  = 1'b0;
    end
  endtask

  task automatic idle(input int n, input bit busy);
    begin
      @(negedge clk);
      l2_inv_pulse = 1'b0; update_tag_we = busy;
      repeat (n) @(negedge clk);
    end
  endtask

  int fails = 0;

  initial begin
    l2_inv_pulse = 0; l2_inv_addr = 0; update_tag_we = 0;
    requested = '0; invalidated = '0; req_n = 0; inv_n = 0;
    repeat (4) @(negedge clk); rst = 0;

    $display("== REVIEW1_Aug2 H-09: the L2 invalidation path must lose NOTHING ==");

    // ---- case 1: two colliding pulses while the tag port is BUSY ----------------
    // The old skid held one address; the second pulse overwrote the first.
    pulse(11, 1'b1);          // busy -> must be queued
    pulse(22, 1'b1);          // busy -> the old code OVERWROTE set 11 here
    idle(8, 1'b0);            // free the port and let everything drain

    // ---- case 2: a fresh pulse arrives with the port FREE and one PENDING --------
    // The old code applied the fresh one and cleared the pending one unapplied.
    pulse(33, 1'b1);          // queued while busy
    pulse(44, 1'b0);          // port free + one pending -> old code dropped set 33
    idle(8, 1'b0);

    // ---- a burst: more pulses than free cycles ----------------------------------
    // No producer contract exists, so the design must survive this without loss.
    pulse(55, 1'b1);
    pulse(66, 1'b1);
    pulse(77, 1'b1);
    pulse(88, 1'b0);
    idle(24, 1'b0);

    // ---- the check: every REQUESTED set must have been INVALIDATED ---------------
    for (int k = 0; k < LINES; k++) begin
      if (requested[k] && !invalidated[k]) begin
        $display("  FAIL set %0d was invalidated by the producer but NEVER applied", k);
        fails++;
      end
    end
    $display("  requested %0d pulse(s); applied %0d invalidation(s)", req_n, inv_n);

    if (fails == 0) $display("L2INV-GATE-OK (no invalidation lost: bitmap is lossless)");
    else            $display("L2INV-GATE-FAIL (%0d set(s) lost)", fails);
    $finish;
  end
endmodule
