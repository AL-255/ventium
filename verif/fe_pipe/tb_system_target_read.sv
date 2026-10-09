// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Actual selector include; never supplies a hit, permission, or bus response.
`timescale 1ns/1ps
`define VEN_IC_BRAM
module tb_system_target_read;
  typedef enum logic [2:0] {S_PIPE,S_EXEC,S_STORE,S_LOAD,S_WALK,S_PF} state_t;
  typedef enum logic [2:0] {K_ALU,K_CTRL,K_STR,K_EXT,K_STKMISC} kind_t;
  typedef enum logic [3:0] {
    CT_RETN,CT_RETN_IMM,CT_JMPIND,CT_CALLREL,CT_CALLIND,CT_LOOP,CT_JECXZ
  } ctrl_t;
  state_t state;
  kind_t q_kind;
  ctrl_t q_ct;
  logic cycle_mode,sys_mode,soc_en,cosim_en,def16,paging_on,smm_active;
  logic sys_fp_ok,real_mode,v86,cs_d,fp_dbg_active,dbg_block_issue;
  logic [31:0] fbase,flin,mem_load_data,call_target;
  logic [2:0] q_w;
  int checks=0;
  `include "core_ctrl_target_read.svh"

  task automatic check(input logic enabled,input logic [31:0] target);
    #1;
    if (p54_ctrl_target_read !== enabled || p54_ctrl_target_addr !== target ||
        p54_ctrl_target_next_line !== ((target & 32'hffffffe0)+32'd32))
      $fatal(1,"selector expected=%b/%08x actual=%b/%08x state=%0d ctrl=%0d",
        enabled,target,p54_ctrl_target_read,p54_ctrl_target_addr,state,q_ct);
    checks++;
  endtask
  initial begin
    cycle_mode=1; sys_mode=0; soc_en=0; cosim_en=0; def16=0;
    paging_on=0; smm_active=0; sys_fp_ok=0; real_mode=0; v86=0;
    cs_d=1; fp_dbg_active=0; dbg_block_issue=0; fbase=0;
    flin=32'h7654321f;
    // All contexts, target forms, state owners, widths, offsets and wraparound.
    // Context gates are exercised one at a time and with all 13 bits swept
    // below; complete target/address checks use independent arithmetic.
    for (int context_case=0;context_case<8;context_case++) begin
      sys_mode=(context_case!=0); soc_en=sys_mode; cosim_en=sys_mode;
      sys_fp_ok=sys_mode; paging_on=(context_case>=2);
      case (context_case)
        0,1,2: fbase=0;
        3: fbase=32'h00400000;
        4: fbase=32'hfffffff0;
        5: fbase=32'hffff0000;
        6: fbase=32'h00000001;
        default: fbase=32'h81234000;
      endcase
      for (int s=0;s<6;s++)
        for (int k=0;k<5;k++)
          for (int c=0;c<7;c++)
            for (int w=0;w<2;w++)
              for (int off=0;off<32;off++) begin
                logic enabled;
                logic [31:0] target,offset_target;
                state=state_t'(s); q_kind=kind_t'(k); q_ct=ctrl_t'(c);
                q_w=w ? 3'd2 : 3'd4;
                mem_load_data=32'hffff8000+32'(off);
                call_target=32'h08069000+32'(off);
                enabled=(k==1) && ((s==1 && c<=2) || (s==2 && c>=3 && c<=4));
`ifndef VEN_P54_CTRL_TARGET_SYSTEM
                enabled &= (context_case==0);
`endif
                offset_target=(c<=1) ? (w ? (mem_load_data & 32'hffff) : mem_load_data) : call_target;
                target=enabled ? fbase+offset_target : flin;
                check(enabled,target);
              end
    end
    state=S_EXEC; q_kind=K_CTRL; q_ct=CT_RETN; q_w=3'd4;
    mem_load_data=32'hffffffff; fbase=0;
    for (int bits=0;bits<8192;bits++) begin
      logic allowed;
      {cycle_mode,sys_mode,soc_en,cosim_en,def16,paging_on,smm_active,
       sys_fp_ok,real_mode,v86,cs_d,fp_dbg_active,dbg_block_issue}=13'(bits);
      allowed=cycle_mode && !def16 && !smm_active && !sys_mode &&
              !soc_en && !cosim_en && !paging_on;
`ifdef VEN_P54_CTRL_TARGET_SYSTEM
      if (sys_mode && cycle_mode && !def16 && !smm_active && sys_fp_ok &&
          !real_mode && !v86 && cs_d && !fp_dbg_active && !dbg_block_issue)
        allowed=1;
`endif
      check(allowed,allowed ? mem_load_data : flin);
    end
    $display("SYSTEM-TARGET-READ-LEAF-OK checks=%0d",checks);
    $finish;
  end
endmodule
