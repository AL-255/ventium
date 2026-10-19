// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_fp_widemul.sv -- one area-minimal 128x128 unsigned multiplier.
//
// A command is decomposed into sixteen 32x32 limb products.  There is exactly
// one multiplication operator in this module, so synthesis cannot replicate
// four 64x64 products behind a nominally shared 128-bit function.  Latency is
// deliberately traded for area; x87 commands already use a valid/ready
// multicycle interface.

`default_nettype none

(* use_dsp = "yes" *)
module ven_fp_widemul (
    input  wire logic         clk,
    input  wire logic         rst_n,
    input  wire logic         start,
    input  wire logic [127:0] a,
    input  wire logic [127:0] b,
    output      logic         busy,
    output      logic         done,
    output      logic [255:0] product
);

  logic [127:0] a_q, b_q;
  logic [255:0] accum_q;
  logic [3:0]   phase_q;
  logic [31:0]  limb_a, limb_b;
  logic [255:0] addend;

  // The sole physical multiplier in the wide-integer service.
  wire logic [63:0] limb_product = limb_a * limb_b;

  always_comb begin
    unique case (phase_q[1:0])
      2'd0: limb_b = b_q[31:0];
      2'd1: limb_b = b_q[63:32];
      2'd2: limb_b = b_q[95:64];
      default: limb_b = b_q[127:96];
    endcase
    unique case (phase_q[3:2])
      2'd0: limb_a = a_q[31:0];
      2'd1: limb_a = a_q[63:32];
      2'd2: limb_a = a_q[95:64];
      default: limb_a = a_q[127:96];
    endcase

    addend = 256'd0;
    unique case (phase_q[3:2] + phase_q[1:0])
      3'd0: addend[63:0]    = limb_product;
      3'd1: addend[95:32]   = limb_product;
      3'd2: addend[127:64]  = limb_product;
      3'd3: addend[159:96]  = limb_product;
      3'd4: addend[191:128] = limb_product;
      3'd5: addend[223:160] = limb_product;
      default: addend[255:192] = limb_product;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      a_q     <= 128'd0;
      b_q     <= 128'd0;
      accum_q <= 256'd0;
      phase_q <= 4'd0;
      product <= 256'd0;
      busy    <= 1'b0;
      done    <= 1'b0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        a_q     <= a;
        b_q     <= b;
        accum_q <= 256'd0;
        phase_q <= 4'd0;
        busy    <= 1'b1;
      end else if (busy) begin
        if (phase_q == 4'd15) begin
          product <= accum_q + addend;
          accum_q <= accum_q + addend;
          busy    <= 1'b0;
          done    <= 1'b1;
        end else begin
          accum_q <= accum_q + addend;
          phase_q <= phase_q + 4'd1;
        end
      end
    end
  end

endmodule

`default_nettype wire
