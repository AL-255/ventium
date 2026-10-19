// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_fp_misc.sv -- registered, serialized x87 conversion service.
//
// Rare narrowing stores and D9 conversion operations share this one service.
// Operands are captured before any conversion logic, and results are registered
// before the architectural state shell sees them.  This deliberately trades
// latency for a bounded setup path and avoids reproducing converters in the
// command/writeback mux.

`default_nettype none

module ven_fp_misc
  import fpu_x87_pkg::*;
  import ventium_decode_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,
    input  wire fxop_e       op,
    input  wire logic [79:0] operand_a,
    input  wire logic [79:0] operand_b,
    input  wire logic [1:0]  rc,
    input  wire logic [1:0]  pc,
    input  wire logic        fist_bug,
    output      logic        busy,
    output      logic        done,
    output      logic [79:0] value,
    output      logic        flag_ie,
    output      logic        flag_oe,
    output      logic        flag_ue,
    output      logic        flag_pe,
    output      logic        rounded_up,
    output      logic        tiny_nonzero
);

  typedef enum logic [1:0] {M_IDLE, M_EXEC, M_DONE} misc_state_t;
  misc_state_t state;

  fxop_e op_q;
  logic [79:0] a_q, b_q;
  logic [1:0] rc_q, pc_q;
  logic fist_bug_q;

  assign busy = (state != M_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state      <= M_IDLE;
      done       <= 1'b0;
      value      <= 80'd0;
      flag_ie    <= 1'b0;
      flag_oe    <= 1'b0;
      flag_ue    <= 1'b0;
      flag_pe    <= 1'b0;
      rounded_up <= 1'b0;
      tiny_nonzero <= 1'b0;
      op_q        <= FX_NONE;
      a_q         <= 80'd0;
      b_q         <= 80'd0;
      rc_q        <= 2'd0;
      pc_q        <= 2'b11;
      fist_bug_q  <= 1'b0;
    end else begin
      done <= 1'b0;
      unique case (state)
        M_IDLE: if (start) begin
          op_q       <= op;
          a_q        <= operand_a;
          b_q        <= operand_b;
          rc_q       <= rc;
          pc_q       <= pc;
          fist_bug_q <= fist_bug;
          state      <= M_EXEC;
        end

        M_EXEC: begin
          automatic logic [35:0] f32;
          automatic logic [67:0] f64;
          automatic logic [65:0] ri;
          automatic logic [79:0] integral;
          automatic logic signed [63:0] scale_n;
          automatic logic signed [17:0] scale_e;
          automatic int width;

          value   <= a_q;
          flag_ie <= 1'b0;
          flag_oe <= 1'b0;
          flag_ue <= 1'b0;
          flag_pe <= 1'b0;
          rounded_up <= 1'b0;
          tiny_nonzero <= 1'b0;
          f32 = 36'd0;
          f64 = 68'd0;
          ri  = 66'd0;
          integral = 80'd0;
          width = 64;
          scale_n = 64'sd0;
          scale_e = 18'sd0;

          unique case (op_q)
            FX_FST_M32: begin
              f32      = fx_to_f32_c1(a_q, rc_q);
              rounded_up <= f32[35];
              // Exact tiny results also fault when UM=0. Zeros do not.
              tiny_nonzero <= !fx_is_zero(a_q) && (f32[30:23] == '0);
              value    <= {48'd0, f32[31:0]};
              flag_pe  <= f32[32];
              flag_ue  <= f32[33];
              flag_oe  <= f32[34];
            end
            FX_FST_M64: begin
              f64      = fx_to_f64_c1(a_q, rc_q);
              rounded_up <= f64[67];
              // Exact tiny results also fault when UM=0. Zeros do not.
              tiny_nonzero <= !fx_is_zero(a_q) && (f64[62:52] == '0);
              value    <= {16'd0, f64[63:0]};
              flag_pe  <= f64[64];
              flag_ue  <= f64[65];
              flag_oe  <= f64[66];
            end
            FX_FST_M80: value <= a_q;

            FX_FIST_M16, FX_FIST_M32, FX_FIST_M64: begin
              width = (op_q == FX_FIST_M16) ? 16 :
                      (op_q == FX_FIST_M32) ? 32 : 64;
              if (fist_bug_q && fist_errata_overflow(a_q, width, rc_q))
                ri = {1'b0, 1'b0, 64'd0};
              else
                ri = fx_to_int_ex(a_q, width, rc_q);
              unique case (op_q)
                FX_FIST_M16: value <= {64'd0, ri[15:0]};
                FX_FIST_M32: value <= {48'd0, ri[31:0]};
                default:     value <= {16'd0, ri[63:0]};
              endcase
              flag_ie <= ri[65];
              flag_pe <= ri[64];
            end

            FX_FRNDINT: begin
              if ((fx_exp(a_q) != 15'd0) && !a_q[63]) begin
                value <= 80'hffffc000000000000000; // unsupported encoding
                flag_ie <= 1'b1;
              end else if ((fx_exp(a_q) == 15'h7fff) && !a_q[62] &&
                           (a_q[61:0] != 62'd0)) begin
                value <= {a_q[79:63], 1'b1, a_q[61:0]}; // quiet SNaN
                flag_ie <= 1'b1;
              end else if (fx_is_inf_nan(a_q) || fx_is_zero(a_q) ||
                           (fx_uexp(a_q) >= 32'sd63)) begin
                value <= a_q;
              end else begin
                ri = fx_round_int_mag(a_q, rc_q);
                // All rounded magnitudes fit <=2^63. The signed converter's
                // absolute value handles the 2^63 bit pattern; restore the
                // ORIGINAL sign, including negative zero. FRNDINT ignores PC.
                integral = fx_from_int($signed(ri[63:0]), 2'b11);
                value <= {fx_sign(a_q), integral[78:0]};
                flag_pe <= ri[64];
                rounded_up <= ri[65];
              end
            end

            FX_FSCALE: begin
              if (fx_is_inf_nan(a_q) || fx_is_zero(a_q)) begin
                value <= a_q;
              end else begin
                ri      = fx_to_int_ex(b_q, 64, 2'd3);
                scale_n = $signed(ri[63:0]);
                if (scale_n >= 64'sd32768) begin
                  value   <= fx_make(fx_sign(a_q), 15'h7fff,
                                     64'h8000000000000000);
                  flag_oe <= 1'b1;
                end else if (scale_n <= -64'sd32768) begin
                  value   <= fx_make(fx_sign(a_q), 15'd0, 64'd0);
                  flag_ue <= 1'b1;
                end else begin
                  scale_e = $signed({3'd0, fx_exp(a_q)}) +
                            $signed(scale_n[17:0]);
                  if (scale_e >= 18'sd32767) begin
                    value   <= fx_make(fx_sign(a_q), 15'h7fff,
                                       64'h8000000000000000);
                    flag_oe <= 1'b1;
                  end else if (scale_e <= 18'sd0) begin
                    value   <= fx_make(fx_sign(a_q), 15'd0, 64'd0);
                    flag_ue <= 1'b1;
                  end else begin
                    value <= fx_make(fx_sign(a_q), scale_e[14:0], fx_man(a_q));
                  end
                end
              end
            end

            default: begin
              value   <= 80'hffffc000000000000000;
              flag_ie <= 1'b1;
            end
          endcase
`ifdef VEN_FP_MISC_EARLY_DONE
          // Payload and exception flags above are already registered on this
          // edge. Publish their valid bit on that same edge; ven_fp_top samples
          // all of them on the following edge, with unchanged registered-data
          // setup and precise commit ordering. The old M_DONE state only
          // delayed this notification; it performed no conversion or rounding.
          // The shell still admits no new command until its old owner commits.
          done  <= 1'b1;
          state <= M_IDLE;
`else
          state <= M_DONE;
`endif
        end

        M_DONE: begin
          done  <= 1'b1;
          state <= M_IDLE;
        end

        default: state <= M_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
