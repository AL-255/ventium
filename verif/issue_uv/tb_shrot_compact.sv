// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
module tb_shrot_compact;
  import ventium_alu_pkg::*;

  // Frozen reference for the original iterative ROL/ROR helper. Unlike the
  // implementation under test, this deliberately retains its 32-step loop.
  function automatic logic [31:0] old_rotate(
      input logic [2:0] subop, input logic [31:0] value,
      input logic [5:0] count, input logic [2:0] width);
    logic [31:0] x;
    logic [5:0] bits;
    logic [4:0] top_bit;
    x = wmask(value, width);
    bits = width == 3'd1 ? 6'd8 : width == 3'd2 ? 6'd16 : 6'd32;
    top_bit = 5'(bits - 6'd1);
    for (int i = 0; i < 32; i++) begin
      if (i < count) begin
        if (subop == 3'd0)
          x = wmask((x << 1) | {31'd0, x[top_bit]}, width);
        else
          x = wmask((x >> 1) | ({31'd0, x[0]} << (bits - 6'd1)), width);
      end
    end
    return wmask(x, width);
  endfunction

  logic [31:0] samples [8] = '{32'h00000000, 32'h00000001,
      32'h80000000, 32'hffffffff, 32'h12345678, 32'h01234567,
      32'habcdef01, 32'h00008001};
  int checks = 0;
  initial begin
    for (int wi = 0; wi < 3; wi++) begin
      logic [2:0] width;
      width = wi == 0 ? 3'd1 : wi == 1 ? 3'd2 : 3'd4;
      for (int sub = 0; sub < 2; sub++) begin
        for (int count = 0; count < 64; count++) begin
          for (int sample = 0; sample < 8; sample++) begin
            logic [31:0] expected, actual;
            logic expected_cf, actual_cf;
            logic [5:0] cnt;
            cnt = 6'(count);
            expected = old_rotate(3'(sub), samples[sample], cnt, width);
            actual = shrot_result(3'(sub), samples[sample], cnt, 1'b1, width);
            expected_cf = count == 0 ? 1'b1 :
                          sub == 0 ? expected[0] : sbit(expected, width);
            actual_cf = shrot_cf(3'(sub), samples[sample], cnt, 1'b1, width);
            if (actual !== expected || actual_cf !== expected_cf)
              $fatal(1, "rotate mismatch width=%0d sub=%0d count=%0d value=%08x old=%08x new=%08x old_cf=%b new_cf=%b",
                     width, sub, count, samples[sample], expected, actual,
                     expected_cf, actual_cf);
            checks++;
          end
        end
      end
    end
    $display("SHROT-COMPACT-GATE-OK checks=%0d", checks);
    $finish;
  end
endmodule
