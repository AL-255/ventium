`timescale 1ns/1ps
module tb_regmem_prime_pair;
  import ventium_decode_pkg::*;
  fpd_t u, v;
  logic pair_ok, pair_mem_ok, pair_regmem_ok;

  issue_uv dut (
      .iu(u), .iv(v), .pair_ok(pair_ok), .pair_mem_ok(pair_mem_ok),
      .pair_regmem_ok(pair_regmem_ok));

  initial begin
    u = '0;
    v = '0;
    u.simple = 1'b1;
    u.pairs_first = 1'b1;
    u.wreg = 1'b1;
    u.dst = 3'd0;                 // EAX
    u.writes = 8'h01;
    v.simple = 1'b1;
    v.pairs_second = 1'b1;
    v.is_mem = 1'b1;
    v.is_load = 1'b1;
    v.wreg = 1'b1;
    v.dst = 3'd2;                 // EDX
    v.writes = 8'h04;
    v.base = 3'd6;                // ESI
    v.mem_base_en = 1'b1;
    v.addr_mask = 8'h40;
    #1;
    assert (pair_regmem_ok && !pair_ok && !pair_mem_ok)
      else $fatal(1, "independent register/load pair was rejected");

    v.addr_mask = 8'h01;         // V EA reads U's EAX result
    #1;
    assert (!pair_regmem_ok) else $fatal(1, "dependent V address paired");
    v.addr_mask = 8'h40;
    v.writes = 8'h01;            // V overwrites U's EAX
    #1;
    assert (!pair_regmem_ok) else $fatal(1, "WAW V load paired");
    v.writes = 8'h04;
    v.is_store = 1'b1;
    v.is_load = 1'b0;
    #1;
    assert (!pair_regmem_ok) else $fatal(1, "V store used read owner");
    v.is_store = 1'b0;
    v.is_load = 1'b1;
    u.is_shift = 1'b1;
    #1;
    assert (!pair_regmem_ok) else $fatal(1, "multi-EX U paired as one clock");
`ifdef VEN_P54_DUAL_READ_ALU_PAIR
    u.is_shift = 1'b0;
    v.is_load = 1'b0;
    v.wflags = 1'b1;
    v.reads = 8'h04;              // old EDX plus the checked memory source
    #1;
    assert (pair_regmem_ok && !pair_ok && !pair_mem_ok)
      else $fatal(1, "independent register/ALU-memory pair was rejected");
    v.mem_lhs = 1'b1;             // RMW destination cannot use read-only V
    #1;
    assert (!pair_regmem_ok) else $fatal(1, "V RMW used read-only owner");
    v.mem_lhs = 1'b0;
    v.w8 = 1'b1;
    #1;
    assert (!pair_regmem_ok) else $fatal(1, "byte ALU read used dword owner");
    v.w8 = 1'b0;
    v.addr_mask = 8'h01;          // speculative EA depends on U EAX
    #1;
    assert (!pair_regmem_ok) else $fatal(1, "dependent ALU address paired");
`endif
    $display("REGMEM-PAIR-CLASS-OK");
    $finish;
  end
endmodule
