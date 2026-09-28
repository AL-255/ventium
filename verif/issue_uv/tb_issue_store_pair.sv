// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
module tb_issue_store_pair;
  import ventium_decode_pkg::*;
  logic [7:0] u0 = 8'h89, u1 = 8'h18, v0 = 8'h89, v1 = 8'h11;
  fpd_t uop, vop;
  logic pair_ok, pair_store_ok;
  int errors = 0;

  decode u_decode (.ib0(u0), .ib1(u1), .ib2(8'd0), .ib3(8'd0),
      .ib4(8'd0), .ib5(8'd0), .ib6(8'd0), .iflags(32'h2),
      .def16(1'b0), .cycle_mode(1'b1), .uop(uop));
  decode v_decode (.ib0(v0), .ib1(v1), .ib2(8'd0), .ib3(8'd0),
      .ib4(8'd0), .ib5(8'd0), .ib6(8'd0), .iflags(32'h2),
      .def16(1'b0), .cycle_mode(1'b1), .uop(vop));
  issue_uv dut (.iu(uop), .iv(vop), .pair_ok, .pair_store_ok);

  task automatic expect_store(input string label, input logic want);
    #1;
    if (pair_store_ok !== want || (want && pair_ok)) begin
      $display("FAIL %s: pair_store_ok=%b want=%b ordinary_pair=%b U store=%b V store=%b",
               label, pair_store_ok, want, pair_ok, uop.is_store, vop.is_store);
      errors++;
    end
  endtask

  initial begin
    expect_store("independent MOV [EAX],EBX / MOV [ECX],EDX", 1'b1);
    u0 = 8'h53; u1 = 8'h00; // PUSH EBX is an implicit stack transaction
    expect_store("PUSH is not a full-dword MOV pair", 1'b0);
    u0 = 8'h89; u1 = 8'h18;
    v0 = 8'h8b; v1 = 8'h11; // MOV EDX,[ECX] is a load
    expect_store("V load is not a store pair", 1'b0);
    v0 = 8'h88; v1 = 8'h11; // MOV [ECX],DL is byte width
    expect_store("V byte store has no pair lane", 1'b0);
    v0 = 8'h89; v1 = 8'hd1; // MOV ECX,EDX is register-only
    expect_store("V register op uses ordinary pairing", 1'b0);
    v0 = 8'h89; v1 = 8'h11;
    expect_store("restored independent stores", 1'b1);
    if (errors == 0) $display("ISSUE-STORE-PAIR-GATE-OK");
    else             $display("ISSUE-STORE-PAIR-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
