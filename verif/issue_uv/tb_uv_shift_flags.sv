// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
// Exercise the real decoder, pairing checker and U-to-V forwarding together.
// The oracle below shifts one bit at a time and does not call RTL flag helpers.
module tb_uv_shift_flags;
  import ventium_decode_pkg::*;
  logic [7:0] opcode, modrm, immediate;
  logic def16, pair_ok, taken;
  logic [31:0] operand, flags, alu, alu_flags, shifted, previous;
  logic carry;
  logic [4:0] count;
  fpd_t u, v;
  decode dec(.ib0(opcode), .ib1(modrm), .ib2(immediate), .ib3(8'd0),
      .ib4(8'd0), .ib5(8'd0), .ib6(8'd0), .iflags(flags), .def16,
      .cycle_mode(1'b1), .uop(u));
  issue_uv issue(.iu(u), .iv(v), .pair_ok);
  u_pipe execute(.u_d(u), .u_dst_val(operand), .u_src_val(32'd0),
      .eflags(flags), .u_alu(alu), .u_flags(alu_flags), .u_sh(shifted),
      .u_shm1(previous), .u_shcf(carry), .u_shcnt(count));
  uv_common forward(.eflags(flags), .bcd_eax16(16'd0), .bcd_imm8(8'd1),
      .bcd_alu_op(5'd0), .bcd_ax(), .bcd_flags(), .u_d(u), .v_d(v),
      .u_flags(alu_flags), .u_sh(shifted), .u_shm1(previous), .u_shcf(carry),
      .v_br_taken_eff(taken));

  function automatic logic branch(input int cc, input logic [31:0] f);
    case (cc)
      0: return f[11];             1: return !f[11];
      2: return f[0];              3: return !f[0];
      4: return f[6];              5: return !f[6];
      6: return f[0] | f[6];       7: return !(f[0] | f[6]);
      8: return f[7];              9: return !f[7];
      10: return f[2];             11: return !f[2];
      12: return f[7] ^ f[11];     13: return !(f[7] ^ f[11]);
      14: return f[6] | (f[7] ^ f[11]);
      default: return !(f[6] | (f[7] ^ f[11]));
    endcase
  endfunction

  int checks = 0, failures = 0;
  int narrow_checks = 0, rotate_checks = 0, zero_checks = 0;
  initial begin
    logic [31:0] values [0:9];
    logic [31:0] mask, x, before_last, expect_flags;
    logic cf, sign_bit;
    int bits;
    values = '{32'd0, 32'd1, 32'hffffffff, 32'h80000000, 32'h7fffffff,
               32'h80, 32'h8000, 32'h40, 32'h4000, 32'ha55ac33c};
    v = '0; v.simple = 1; v.pairs_second = 1; v.is_branch = 1;
    v.br_cond = 1; v.len = 2;
    for (int width = 0; width < 3; width++) begin
      bits = (width == 0) ? 8 : ((width == 1) ? 16 : 32);
      mask = 32'hffffffff >> (32-bits);
      def16 = (width == 1);
      opcode = (width == 0) ? 8'hc0 : 8'hc1;
      for (int op = 1; op < 8; op++) begin
        if (op < 4) begin
`ifdef VEN_FAST_ROR_IMM
          if (op != 1 || width != 2) continue;
`else
          continue;
`endif
        end
        modrm = 8'hc0 | 8'(op << 3);
        for (int n = 0; n < 32; n++) begin
          immediate = 8'(n);
          for (int val = 0; val < 10; val++) begin
            // Non-operand bits intentionally nonzero for byte/word forms.
            operand = values[val] | (~mask & 32'ha55a0000);
            for (int f = 0; f < 64; f++) begin
              flags = 32'h202;
              flags[0]=1'(f); flags[2]=1'(f>>1); flags[4]=1'(f>>2);
              flags[6]=1'(f>>3); flags[7]=1'(f>>4); flags[11]=1'(f>>5);
              expect_flags = flags; x = operand & mask; before_last = x;
              cf = flags[0];
              for (int step = 0; step < n; step++) begin
                before_last = x; sign_bit = x[bits-1];
                if (op == 4 || op == 6) begin
                  cf = sign_bit; x = (x << 1) & mask;
                end else begin
                  cf = x[0]; x = x >> 1;
                  if (op == 7) x[bits-1] = sign_bit;
                  if (op == 1) x[bits-1] = cf;
                end
              end
              if (n != 0) begin
                expect_flags[0] = cf;
                if (op == 1) expect_flags[11] = x[31] ^ x[30];
                else begin
                  expect_flags[2] = ~^x[7:0]; expect_flags[4] = 0;
                  expect_flags[6] = (x == 0); expect_flags[7] = x[bits-1];
                  expect_flags[11] = before_last[bits-1] ^ x[bits-1];
                end
              end
              for (int cc = 0; cc < 16; cc++) begin
                // Do not manufacture an oracle for architecturally undefined
                // OF (multi-bit shift/rotate) or CF (count >= operand width).
                if (n > 1 && (cc < 2 || cc >= 12)) continue;
                if (op != 1 && n >= bits && (cc == 2 || cc == 3 || cc == 6 || cc == 7)) continue;
                v.cc = 4'(cc); #1;
                if (!u.simple || !u.is_shift || u.shift_cl || !pair_ok)
                  $fatal(1, "UV shift fixture did not admit a pair width=%0d op=%0d", bits, op);
                checks++; narrow_checks += int'(width != 2);
                rotate_checks += int'(op == 1); zero_checks += int'(n == 0);
                if (taken !== branch(cc, expect_flags)) begin
                  if (failures < 12)
                    $display("UV-SHIFT-MISMATCH width=%0d op=%0d count=%0d a=%08x old=%08x cc=%0d expected=%0d got=%0d",
                        bits, op, n, operand, flags, cc, branch(cc, expect_flags), taken);
                  failures++;
                end
              end
            end
          end
        end
      end
    end
    $display("UV-SHIFT-FLAGS checks=%0d narrow=%0d rotate=%0d zero=%0d failures=%0d",
        checks, narrow_checks, rotate_checks, zero_checks, failures);
    if (failures != 0) $fatal(1, "UV-SHIFT-FLAGS-FAIL");
    $display("UV-SHIFT-FLAGS-OK"); $finish;
  end
endmodule
