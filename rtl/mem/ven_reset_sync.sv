// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_reset_sync.sv — async-assert / sync-deassert reset synchronizer (P1-3).
//
// The dual-clock L1/AXI build (+VEN_AXI_CDC) drives the core and AXI domains from
// the SAME PL reset (proc_sys_reset's peripheral_aresetn). A raw async reset that
// deasserts near a clock edge can release the two domains' flops on different cycles
// (recovery/removal violation) — so each domain locally synchronizes the DEASSERTION
// of its reset: reset ASSERTS asynchronously (the moment rst_n falls, the output
// falls — no clock needed, safe even with no clock yet), and DEASSERTS only after two
// rising edges of that domain's clock (clean recovery). This is the standard, license-
// free reset-bridge; one instance per clock domain. ASYNC_REG keeps the two flops
// adjacent so the (rare) recovery-time metastability resolves within the second flop.

module ven_reset_sync (
    input  logic clk,
    input  logic arst_n,      // raw async-asserted active-low reset in
    output logic srst_n       // synchronized active-low reset out (this domain)
);
  (* ASYNC_REG = "TRUE" *) logic m0, m1;
  always_ff @(posedge clk or negedge arst_n)
    if (!arst_n) begin m0 <= 1'b0; m1 <= 1'b0; end
    else         begin m0 <= 1'b1; m1 <= m0;   end
  assign srst_n = m1;
endmodule : ven_reset_sync
