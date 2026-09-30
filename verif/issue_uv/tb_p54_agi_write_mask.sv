// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Prepared leaf: executes the REAL core include, not a policy copy. Deliberately
// not run during the CoreMark-only/below-2.0 phase. This checks ownership/storage;
// it does not replace the subsequent whole-core/QEMU dependency witnesses.
`timescale 1ns/1ps
module tb_p54_agi_write_mask;
  localparam logic [2:0] R_ESP=3'd4;
  typedef enum logic [3:0] {
    S_PIPE, S_EXEC, S_STORE, S_LOAD, S_WALK, S_TSW_BUSY, S_RSM,
    S_ENTER, S_LCALL, S_RETF, S_USEQ
  } state_t;
  typedef enum logic [2:0] {K_ALU,K_CTRL,K_STKMISC,K_MULDIV,K_EXT} kind_t;
  typedef struct packed {
    logic is_stack, is_load, wreg;
    logic [2:0] dst;
  } packet_t;
  logic clk=0, rst_n=0;
  state_t state=S_PIPE;
  kind_t q_kind=K_ALU;
  packet_t pipe_u_eff='0, pipe_v_eff='0;
  logic pipe_pair_eff=0;
  logic [7:0] gpr_we=0;
  logic str_store_rollback_now=0;
  logic q_is_push=0, q_is_pop=0, q_mem_write=0, q_pop_sreg=0;
  logic [2:0] q_dst_reg=0;
  int checks=0;
  always #5 clk=~clk;
  `include "core_agi_write_mask.svh"

  task automatic clock_check(input logic [7:0] expected,input string name);
    @(posedge clk); #1;
    if (p54_prior_write_mask!==expected)
      $fatal(1,"%s state%0d writes%02x expected%02x actual%02x",
             name,state,gpr_we,expected,p54_prior_write_mask);
    checks++;
    @(negedge clk);
  endtask
  task automatic plain_owner;
    pipe_u_eff='0; pipe_v_eff='0; pipe_pair_eff=0; q_kind=K_ALU;
    q_is_push=0; q_is_pop=0; q_mem_write=0; q_pop_sreg=0;
    q_dst_reg=0; str_store_rollback_now=0;
  endtask
  initial begin
    clock_check(8'd0,"reset clears history");
    rst_n=1;
    for (int bits=0;bits<256;bits++) begin
      plain_owner(); gpr_we=8'(bits); state=S_PIPE;
      clock_check(8'(bits),"all actual U/V and partial-parent writers");
      pipe_u_eff.is_stack=1; pipe_u_eff.is_load=0;
      clock_check(8'(bits)&8'hef,"fast PUSH implicit ESP only");
      pipe_u_eff.is_load=1; pipe_u_eff.dst=3'd3;
      clock_check(8'(bits)&8'hef,"fast POP EBX preserves explicit dst");
      pipe_u_eff.dst=R_ESP;
      clock_check(8'(bits),"fast POP ESP remains explicit");
      pipe_u_eff.dst=3'd3; pipe_pair_eff=1;
      pipe_v_eff.wreg=1; pipe_v_eff.dst=R_ESP;
      clock_check(8'(bits),"paired V explicit ESP defeats U implicit exemption");
      pipe_v_eff.dst=3'd2;
      clock_check(8'(bits)&8'hef,"paired V nonESP writes are preserved");

      plain_owner(); state=S_EXEC; q_kind=K_MULDIV;
      clock_check(8'(bits),"native/iterative MUL DIV two outputs");
      q_kind=K_ALU; q_is_push=1;
      clock_check(8'(bits)&8'hef,"slow PUSH implicit ESP only");
      q_is_push=0; q_is_pop=1; q_dst_reg=3'd3;
      clock_check(8'(bits)&8'hef,"slow POP EBX keeps explicit destination");
      q_dst_reg=R_ESP;
      clock_check(8'(bits),"slow POP ESP remains explicit");
      q_mem_write=1;
      clock_check(8'(bits)&8'hef,"slow POP memory scratch ESP not explicit");
      q_mem_write=0; q_pop_sreg=1;
      clock_check(8'(bits)&8'hef,"slow POP segment scratch ESP not explicit");
      state=S_STORE; q_is_pop=0; q_pop_sreg=0; q_is_push=1;
      clock_check(8'(bits)&8'hef,"PUSH memory store ACK owner");
      q_is_push=0; q_is_pop=1; q_mem_write=1;
      clock_check(8'(bits)&8'hef,"POP memory store ACK owner");

      // Do not extend the manual's literal PUSH/POP exemption to CALL/RET,
      // PUSHF/POPF/PUSHA/POPA/ENTER/LEAVE or stale flags on a different kind.
      plain_owner(); state=S_EXEC; q_kind=K_CTRL;
      clock_check(8'(bits),"CALL/RET conservative ESP producer");
      q_is_push=1;
      clock_check(8'(bits),"different kind ignores stale PUSH flag");
      q_kind=K_STKMISC;
      clock_check(8'(bits),"misc stack bookkeeping conservative");
      state=S_ENTER;
      clock_check(8'(bits),"ENTER conservative producer");
      state=S_USEQ;
      clock_check(8'(bits),"PUSHA/POPA conservative producer");

      // A stale slow record cannot exempt a live explicit fast ESP writer.
      state=S_PIPE; pipe_u_eff='0; pipe_v_eff='0; pipe_pair_eff=0;
      q_kind=K_ALU; q_is_pop=1;
      clock_check(8'(bits),"live explicit fast writer ignores stale q record");
      str_store_rollback_now=1;
      clock_check(8'd0,"restart rollback is not executed producer");
      str_store_rollback_now=0; state=S_TSW_BUSY;
      clock_check(8'd0,"incoming task context resets history");
      state=S_RSM;
      clock_check(8'd0,"incoming SMM context resets history");
    end
    plain_owner(); state=S_EXEC; q_kind=K_EXT; gpr_we=8'h05;
    clock_check(8'h05,"explicit slow EAX EDX producer");
    // Hold/walk/fault/debug/masked-zero reference shift have no actual writes.
    gpr_we=8'd0; state=S_WALK;
    clock_check(8'd0,"one no-write clock clears all prior producers");
    state=S_PIPE;
    clock_check(8'd0,"no stale producer survives a hold");
    // Never filter equal-value explicit writes in this tracker. The owning WB
    // guard supplies zero WE for masked-zero shifts in the optional profile.
    gpr_we=8'h01;
    clock_check(8'h01,"all supplied actual explicit writes are retained");
    rst_n=0;
    clock_check(8'd0,"reset or snapshot installation clears history");
    $display("P54-AGI-WRITE-MASK-LEAF-OK checks=%0d",checks);
    $finish;
  end
endmodule
