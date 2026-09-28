`timescale 1ns/1ps
module tb_p54_dual_load_issue;
  import ventium_decode_pkg::*;
  logic [7:0] u0, u1, u2, v0, v1, v2;
  fpd_t u, v;
  logic pair_ok, pair_mem_ok;
  decode du(.ib0(u0), .ib1(u1), .ib2(u2), .ib3(0), .ib4(0), .ib5(0), .ib6(0),
            .iflags(32'h2), .def16(1'b0), .cycle_mode(1'b1), .uop(u));
  decode dv(.ib0(v0), .ib1(v1), .ib2(v2), .ib3(0), .ib4(0), .ib5(0), .ib6(0),
            .iflags(32'h2), .def16(1'b0), .cycle_mode(1'b1), .uop(v));
  issue_uv dut(.iu(u), .iv(v), .pair_ok(pair_ok), .pair_mem_ok(pair_mem_ok));

  task automatic check(input logic expected, input string label);
    #1;
    if (pair_mem_ok !== expected || pair_ok)
      $fatal(1, "%s: pair_mem=%b ordinary_pair=%b expected=%b",
             label, pair_mem_ok, pair_ok, expected);
  endtask

  initial begin
    u0=8'h8b; u1=8'h06; u2=0; // MOV EAX,[ESI]
    v0=8'h8b; v1=8'h56; v2=8'd4; // MOV EDX,[ESI+4]
    check(1'b1, "independent dword MOV loads");
    v1=8'h10; v2=0; // MOV EDX,[EAX]: U->V address RAW
    check(1'b0, "dependent address");
    v0=8'h89; v1=8'h56; v2=8'd4; // store is not a V load
    check(1'b0, "V store");
    v0=8'h8a; v1=8'h56; v2=8'd4; // byte V load needs a different return path
    check(1'b0, "V byte load");
    v0=8'h8b; v1=8'h06; v2=0; // EAX WAW
    check(1'b0, "WAW");
    $display("P54-DUAL-LOAD-ISSUE-OK");
    $finish;
  end
endmodule
