// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Real admission/merge, new WB fragment, and normal retire task. The small
// environment controls fault/fragment/owner inputs; whole-core QEMU fixtures
// separately qualify the existing decoder, reg_merge, and request sequencer.
`timescale 1ns/1ps
module tb_p54_mov_ack_retire;
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
  localparam int SG_CS=1,DR6_BS=14;
  localparam logic [3:0] SYS_NONE=0;
  typedef enum logic [1:0] {S_LOAD,S_EXEC,S_PIPE,S_DB} state_t;
  state_t state=S_LOAD;
  logic clk=0,rst_n=0,force_owner=0,test_exec=0;
  logic cycle_mode=1,sys_mode=0,soc_en=0,cosim_en=0,def16=0;
  logic paging_on=0,smm_active=0,fold_pending_r=0;
  logic dbg_block_issue=0,dbg_step_active=0,fp_dbg_active=0;
  logic tf_at_issue=0,rf_at_issue=0,fp_async_pending=0,fp_occ_pending=0;
  logic fp_async_fault_hold=0,fsm_case_enabled=1,mem_ack=1,xp_cross=0;
  logic xp_pend=0,q_is_mov=1,q_mem_read=1,q_mem_write=0,q_mem_dst=0;
  logic q_writes_reg=1,q_writes_flags=0,q_use_imm=0,q_dst_high8=0;
  logic q_is_push=0,q_is_pop=0,q_is_lea=0,q_is_branch=0,q_is_x87=0;
  logic q_seg_load=0,q_store_sreg=0,q_push_sreg=0,q_pop_sreg=0,q_xlat=0;
  logic q_callf_mem=0,q_jmpf_mem=0,q_io=0,q_lock=0;
  logic q_cld=0,q_std=0,q_cli=0,q_sti=0,q_clc=0,q_stc=0,q_cmc=0,q_clts=0;
  logic [2:0] xp_first=1,q_w=4,q_dst_reg=0;
  logic [3:0] q_len=3,q_sysop=0;
  kind_e q_kind=K_ALU;
  logic [4:0] q_alu_op=ALU_MOV;
  logic [31:0] xp_lo=0,mem_rdata=0,q_pc=32'h1000,eip=32'h1000;
  logic [31:0] fbase=0;
  logic [7:0] ibuf[16]='{default:8'd0};
  logic [7:0] gpr_we;
  logic [7:0][31:0] gpr_wd,gpr_o='{default:32'h1234abcd};
  logic [31:0] seg_base[6]='{default:32'd0};
  logic [31:0] eflags=32'h246,test_target=32'h2000,test_flags=32'h2;
  logic test_flags_we=0,retire_valid=0;
  logic [3:0] test_xbp=0;
  logic [31:0] db_bits=0,db_pc=0,db_resume=0;
  int checks=0;

  // Independent byte-mask oracle. Production uses its already-verified
  // canonical reg_merge, exercised by the whole-core fixture as well.
  function automatic logic [31:0] reg_merge(input logic [31:0] old_value,new_value,
      input logic [2:0] width,input logic high8);
    logic [31:0] mask;
    int offset;
    offset=(width==1 && high8)?8:0;
    mask=(width==1)?(32'hff<<offset):(width==2)?32'hffff:32'hffff_ffff;
    return (old_value&~mask)|((new_value<<offset)&mask);
  endfunction
  function automatic logic [3:0] dr_match(input logic [31:0] addr,input logic insn);
    return test_xbp;
  endfunction
  task automatic arm_db(input logic [31:0] bits,pc,resume_pc);
    db_bits<=bits; db_pc<=pc; db_resume<=resume_pc; state<=S_DB;
  endtask
  `include "core_mov_ack_retire.svh"
  `include "core_int_retire.svh"
  always_comb begin
    gpr_we=0;gpr_wd='0;
    `include "core_mov_ack_gpr.svh"
  end
  always_ff @(posedge clk) begin
    if (!rst_n || force_owner) begin
      state<=S_LOAD;eip<=q_pc;eflags<=32'h246;retire_valid<=0;
      db_bits<=0;db_pc<=0;db_resume<=0;
    end else begin
      retire_valid<=0;
      if (test_exec) retire_reference_integer(test_target,test_flags_we,test_flags);
      else if (p54_mov_ack_take) retire_reference_integer(q_pc+{28'd0,q_len},0,eflags);
    end
  end
  task automatic tick;
    #2;clk=1;#2;clk=0;#1;
  endtask
  task automatic install;
    force_owner=1;tick();force_owner=0;#1;
  endtask
  task automatic check_take(input bit expected,input string reason);
    #1;
    if(p54_mov_ack_take!==expected || (gpr_we!=0)!==expected)
      $fatal(1,"%s take=%b WE=%02x",reason,p54_mov_ack_take,gpr_we);
    checks++;
  endtask
  initial begin
    tick();rst_n=1;ibuf[0]=8'h8b;install();
    for(int pattern=0;pattern<256;pattern++)
      for(int width_idx=0;width_idx<3;width_idx++)
        for(int lane=0;lane<8;lane++) begin
          q_w=(width_idx==0)?3'd1:(width_idx==1)?3'd2:3'd4;
          q_dst_high8=(q_w==1 && lane>=4);q_dst_reg=3'(lane);
          xp_pend=0;mem_rdata=32'hdeadbe00|32'(pattern);
          check_take(1,"plain source ACK");
          if(gpr_we!=(8'h1<<q_dst_reg) ||
             gpr_wd[q_dst_reg]!=reg_merge(gpr_o[q_dst_reg],mem_rdata,q_w,q_dst_high8))
            $fatal(1,"width/high-byte writer mismatch");
          checks++;
          for(int first=1;first<4;first++) begin
            logic [31:0] expected;
            xp_first=3'(first);xp_pend=1;xp_lo=32'h01234567^32'(pattern);
            expected=0;
            for(int byte_idx=0;byte_idx<4;byte_idx++)
              expected[byte_idx*8+:8]=(byte_idx<first)
                  ?xp_lo[byte_idx*8+:8]:mem_rdata[(byte_idx-first)*8+:8];
            #1;
            if(p54_mov_ack_load_value!==expected)
              $fatal(1,"final-fragment merge mismatch first%0d",first);
            check_take(1,"final legacy fragment");
          end
        end
    xp_pend=0;q_w=2;q_dst_high8=0;q_dst_reg=0;
    ibuf[0]=8'h66;ibuf[1]=8'h8b;check_take(1,"one 66 D1 is retained");
    ibuf[1]=8'h67;check_take(0,"multiple prefixes stay reference");ibuf[1]=8'h8b;
    mem_ack=0;check_take(0,"delayed source no write");mem_ack=1;
    xp_cross=1;check_take(0,"first page fragment no write");xp_cross=0;
    fsm_case_enabled=0;check_take(0,"fault/walk suppresses WB");fsm_case_enabled=1;
    fp_async_fault_hold=1;check_take(0,"older FP fault");fp_async_fault_hold=0;
    sys_mode=1;check_take(0,"system default unchanged");sys_mode=0;
    soc_en=1;check_take(0,"SoC default unchanged");soc_en=0;
    cosim_en=1;check_take(0,"cosim default unchanged");cosim_en=0;
    def16=1;check_take(0,"default16 conservative");def16=0;
    paging_on=1;check_take(0,"paging conservative");paging_on=0;
    smm_active=1;check_take(0,"SMM conservative");smm_active=0;
    fbase=1;check_take(0,"nonflat code conservative");fbase=0;
    fold_pending_r=1;check_take(0,"proxy fold conservative");fold_pending_r=0;
    dbg_block_issue=1;check_take(0,"debug park");dbg_block_issue=0;
    dbg_step_active=1;check_take(0,"external single step");dbg_step_active=0;
    fp_dbg_active=1;check_take(0,"architectural debug");fp_dbg_active=0;
    tf_at_issue=1;check_take(0,"TF retains common EX");tf_at_issue=0;
    rf_at_issue=1;check_take(0,"RF retains common EX");rf_at_issue=0;
    fp_async_pending=1;check_take(0,"older FP pending");fp_async_pending=0;
    fp_occ_pending=1;check_take(0,"older FP occupancy");fp_occ_pending=0;
    q_pc=32'h1001;check_take(0,"wrong owner PC");q_pc=32'h1000;
    q_len=0;check_take(0,"empty owner");q_len=3;
    q_kind=K_EXT;check_take(0,"MOVSX three EX unchanged");q_kind=K_ALU;
    q_alu_op=ALU_CMP;check_take(0,"CMP two EX unchanged");q_alu_op=ALU_MOV;
    q_writes_flags=1;check_take(0,"TEST/flag writers excluded");q_writes_flags=0;
    q_mem_write=1;check_take(0,"RMW/store excluded");q_mem_write=0;
    q_mem_dst=1;check_take(0,"memory destination excluded");q_mem_dst=0;
    q_is_pop=1;check_take(0,"POP excluded");q_is_pop=0;
    q_seg_load=1;check_take(0,"far/segment load excluded");q_seg_load=0;
    q_lock=1;check_take(0,"LOCK excluded");q_lock=0;
    install();tick();
    if(!retire_valid || state!=S_PIPE || eip!=q_pc+3 || eflags!=32'h246)
      $fatal(1,"ACK retirement did not preserve normal PC/flags");checks++;
    // Actual common helper #DB priority and RF behavior, including macro-off
    // S_EXEC callers. The ACK admission itself rejects system/debug forms.
    test_exec=1;sys_mode=1;tf_at_issue=1;test_xbp=4'h2;
    install();tick();
    if(retire_valid || state!=S_DB || db_bits!=2 || db_resume!=test_target || db_pc!=q_pc)
      $fatal(1,"common instruction breakpoint priority changed");checks++;
    rf_at_issue=1;install();tick();
    if(retire_valid || db_bits!=(32'd1<<DR6_BS))
      $fatal(1,"common RF/TF semantics changed");checks++;
    tf_at_issue=0;install();test_flags_we=1;tick();
    if(!retire_valid || state!=S_PIPE || eflags!=test_flags || eip!=test_target)
      $fatal(1,"common normal S_EXEC flags changed");checks++;
    $display("P54-MOV-ACK-RETIRE-LEAF-OK checks=%0d",checks);$finish;
  end
endmodule
