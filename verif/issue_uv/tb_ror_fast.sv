// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
module tb_ror_fast;
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
  logic [7:0] opcode = 8'hc1, modrm = 8'hc8, count = 8'd0;
  logic def16 = 0;
  fpd_t decoded;
  logic [31:0] value = 32'h12345678, flags = 32'h00000a47;
  logic [31:0] alu_result_unused, alu_flags_unused, rotated, rotated_m1;
  logic carry;
  logic [4:0] effective_count;
  decode u_decode (.ib0(opcode), .ib1(modrm), .ib2(count),
      .ib3(8'd0), .ib4(8'd0), .ib5(8'd0), .ib6(8'd0),
      .iflags(flags), .def16, .cycle_mode(1'b1), .uop(decoded));
  u_pipe u_pipe_test (.u_d(decoded), .u_dst_val(value), .u_src_val(32'd0),
      .eflags(flags), .u_alu(alu_result_unused), .u_flags(alu_flags_unused),
      .u_sh(rotated), .u_shm1(rotated_m1), .u_shcf(carry),
      .u_shcnt(effective_count));

  function automatic logic [31:0] old_ror32(input logic [31:0] src,
                                               input logic [4:0] n);
    logic [31:0] x;
    x = src;
    for (int i = 0; i < 32; i++)
      if (i < n) x = (x >> 1) | {x[0],31'd0};
    return x;
  endfunction

  int checks = 0;
  initial begin
`ifndef VEN_FAST_ROR_IMM
    $fatal(1, "tb_ror_fast requires VEN_FAST_ROR_IMM");
`endif
    for (int n = 0; n < 64; n++) begin
      count = 8'(n);
      for (int v = 0; v < 4; v++) begin
        logic [31:0] expected;
        case (v)
          0: value = 32'h12345678;
          1: value = 32'h80000001;
          2: value = 32'hffffffff;
          default: value = 32'h00000000;
        endcase
        #1;
        expected = old_ror32(value, count[4:0]);
        if (!decoded.simple || !decoded.is_shift || decoded.shrot != 3'd1 ||
            decoded.len != 4'd3 || decoded.dst != 3'd0 ||
            !decoded.pairs_first || decoded.pairs_second ||
            effective_count != count[4:0] || rotated !== expected ||
            carry !== (count[4:0] == 0 ? flags[0] : expected[31]))
          $fatal(1, "ROR fast mismatch count=%0d value=%08x got=%08x cf=%b",
                 n, value, rotated, carry);
        checks++;
      end
    end
    modrm = 8'hd0; #1; // C1 /2 RCL remains slow.
    if (decoded.simple) $fatal(1, "RCL unexpectedly fast");
    modrm = 8'h08; #1; // Memory ROR remains slow.
    if (decoded.simple) $fatal(1, "memory ROR unexpectedly fast");
    modrm = 8'hc8; def16 = 1; #1; // 16-bit default remains slow.
    if (decoded.simple) $fatal(1, "16-bit ROR unexpectedly fast");
    opcode = 8'hd1; def16 = 0; #1; // Count-one ROR remains slow.
    if (decoded.simple) $fatal(1, "D1 ROR unexpectedly fast");
    $display("ROR-FAST-LEAF-OK checks=%0d", checks);
    $finish;
  end
endmodule
