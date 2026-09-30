// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Exercises the real selector include. Whole-core returned-tag/collision and
// differential tests are additional gates, not replaced by this policy leaf.
`timescale 1ns/1ps
`define VEN_IC_BRAM
module tb_p54_ctrl_target_read;
  typedef enum logic [2:0] {S_PIPE,S_EXEC,S_STORE,S_LOAD,S_WALK,S_PF} state_t;
  typedef enum logic [2:0] {K_ALU,K_CTRL,K_STR,K_EXT,K_STKMISC} kind_t;
  typedef enum logic [3:0] {
    CT_RETN,CT_RETN_IMM,CT_JMPIND,CT_CALLREL,CT_CALLIND,CT_LOOP,CT_JECXZ
  } ctrl_t;
  state_t state;
  kind_t q_kind;
  ctrl_t q_ct;
  logic cycle_mode,sys_mode,soc_en,cosim_en,def16,paging_on,smm_active;
  logic [31:0] fbase,flin,mem_load_data,call_target;
  logic [2:0] q_w;
  int checks=0;
  `include "core_ctrl_target_read.svh"

  task automatic check(input logic enabled,input logic [31:0] target);
    #1;
    if (p54_ctrl_target_read !== enabled || p54_ctrl_target_addr !== target ||
        p54_ctrl_target_next_line !== ({target[31:5],5'd0}+32'd32))
      $fatal(1,"bad selector state=%0d kind=%0d control=%0d width=%0d expected=%b/%08x actual=%b/%08x",
             state,q_kind,q_ct,q_w,enabled,target,
             p54_ctrl_target_read,p54_ctrl_target_addr);
    checks++;
  endtask
  initial begin
    cycle_mode=1; sys_mode=0; soc_en=0; cosim_en=0; def16=0;
    paging_on=0; smm_active=0; fbase=0; flin=32'h08048010;
    for (int s=0;s<6;s++)
      for (int k=0;k<5;k++)
        for (int c=0;c<7;c++)
          for (int w=0;w<2;w++)
            for (int off=0;off<32;off++) begin
              logic enable; logic [31:0] target;
              state=state_t'(s); q_kind=kind_t'(k); q_ct=ctrl_t'(c);
              q_w=w ? 3'd2 : 3'd4;
              mem_load_data=32'h08058000+32'(off);
              call_target=32'h08069000+32'(off);
              enable=(q_kind==K_CTRL) &&
                  (((state==S_EXEC) && (q_ct inside {CT_RETN,CT_RETN_IMM,CT_JMPIND})) ||
                   ((state==S_STORE) && (q_ct inside {CT_CALLREL,CT_CALLIND})));
              target=flin;
              if (enable) target=(q_ct inside {CT_RETN,CT_RETN_IMM})
                    ? (w ? {16'd0,mem_load_data[15:0]} : mem_load_data) : call_target;
              check(enable,target);
            end
    state=S_EXEC; q_kind=K_CTRL; q_ct=CT_RETN; q_w=3'd4;
    mem_load_data=32'hfffffff7;
    check(1,mem_load_data); // next-line wraps architecturally at 32 bits.
    cycle_mode=0; check(0,flin); cycle_mode=1;
    sys_mode=1; check(0,flin); sys_mode=0;
    soc_en=1; check(0,flin); soc_en=0;
    cosim_en=1; check(0,flin); cosim_en=0;
    def16=1; check(0,flin); def16=0;
    paging_on=1; check(0,flin); paging_on=0;
    smm_active=1; check(0,flin); smm_active=0;
    fbase=32'h1000; check(0,flin); fbase=0;
    check(1,mem_load_data);
    $display("P54-CTRL-TARGET-READ-LEAF-OK checks=%0d",checks);
    $finish;
  end
endmodule
