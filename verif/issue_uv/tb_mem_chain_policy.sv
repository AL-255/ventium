// Production lookahead policy with synthetic returned-uop/TLB fixtures.
// This is a rejection/ownership unit test, NOT architectural fault delivery.
`timescale 1ns/1ps
module tb_mem_chain_policy;
  import ventium_decode_pkg::*;
  localparam int IC_IDXW=7, IC_WAYW=1, UC_TAIL_IDXW=2;
  localparam int SG_CS=0, SG_SS=1, SG_DS=2, S_PIPE=1;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic [2:0] state=S_PIPE;
  logic [31:0] seg_base[6], seg_limit[6], gpr_o[8];
  logic [15:0] seg_attr[6], seg_sel[6];
  logic seg_pm_loaded[6];
  logic [6:0] rdA_set_q=0, rdB_set_q=1;
  logic rdA_way_q=0, rdB_way_q=0, ic_rd_collA=0, ic_rd_collB=0;
  logic uc_pdvA=1, uc_pdvB=1;
  logic uc_bvA[32], uc_bvB[32];
  logic [3:0] uc_bsA[32], uc_bsB[32];
  fpd_t uc_baseA[8], uc_baseB[8], uc_tailA[4], uc_tailB[4];
  fpd_t pipe_u_eff, pipe_v_eff;
  logic [31:0] flin=32'h8000, pipe_commit_eip=32'h8000;
  logic pipe_pair_eff=0, cycle_mode=1, real_bus=1, def16=0, a20_on=1;
  logic [6:0] pending_mem_pen=0, stall_cnt=0;
  logic [2:0] mispred_bubbles=0;
  logic [31:0] cur_lin_nat=32'h2000;
  logic irq_shadow=0, fp_dbg_active=0, dbg_step_active=0, fp_issue_block=0;
  logic smi_take=0, nmi_take=0, intr_take=0, exec_flush_all=0;
  logic ic_snoop_valid=0, ic_snoop_valid1=0, ic_snoop_valid2=0;
  logic tlb_flush=0, tlb_fill_en=0, fx_act=0, fx_abort_q=0, bus_err=0;
  logic pipe_mem_active_q=1, pipe_new_load_req=0, pipe_new_mem_req=0, pipe_mem_we_q=0;
  logic pipe_mem_abort_now=0, pipe_int_commit=0;
  logic paging_on=1, sys_mode=1, sys_fp_ok=1, real_mode=0, cs_d=1;
  logic [1:0] eff_cpl=3;
  logic mem_next_req, mem_next_commit, mem_next_ready=1;
  logic [31:0] mem_next_addr;
  logic [3:0] mem_next_wstrb;
  logic fixture_hit=1;
  logic [2:0] fixture_perm=3'b111;
  logic [31:0] fixture_phys=32'h00301000;
  function automatic logic ic_hit_way(input logic [31:0] addr);
    return 1'b0;
  endfunction
  function automatic logic ic_present(input logic [31:0] addr);
    return addr[31:12]==20'h00008;
  endfunction
  `include "core_mem_chain.svh"
  assign mc_lookup_hit=fixture_hit;
  assign mc_lookup_perm=fixture_perm;
  assign mc_lookup_phys=fixture_phys;
  assign mc_lookup_dirty=1'b1;
  task automatic expect_prepare(input string name, input logic wanted);
    #1;
    if(mc_prepare_ok!==wanted)
      $fatal(1,"%s prepare=%0b wanted=%0b",name,mc_prepare_ok,wanted);
  endtask
  task automatic check_cancel(input string name);
    #1;
    if(mem_next_req || mc_accept) $fatal(1,"%s admitted stale next owner",name);
    @(posedge clk); #1;
    if(mc_valid_q) $fatal(1,"%s retained candidate",name);
  endtask
  task automatic prime;
    @(negedge clk); rst_n=0; pipe_int_commit=0;
    @(negedge clk); rst_n=1;
    @(posedge clk); #1;
    if(!mc_valid_q || mc_pc_q!=32'h8002 || mc_phys_q!=fixture_phys)
      $fatal(1,"candidate not independently registered");
  endtask
  initial begin
    for(int s=0;s<6;s++) begin
      seg_base[s]=0; seg_limit[s]=32'hffffffff; seg_attr[s]=16'h0093;
      seg_sel[s]=16'h0010; seg_pm_loaded[s]=1;
    end
    for(int r=0;r<8;r++) gpr_o[r]=32'h1000;
    for(int b=0;b<32;b++) begin
      uc_bvA[b]=0; uc_bvB[b]=0; uc_bsA[b]=0; uc_bsB[b]=0;
    end
    for(int s=0;s<8;s++) begin uc_baseA[s]='0; uc_baseB[s]='0; end
    for(int s=0;s<4;s++) begin uc_tailA[s]='0; uc_tailB[s]='0; end
    pipe_u_eff='0; pipe_v_eff='0;
    pipe_u_eff.len=2; pipe_u_eff.simple=1; pipe_u_eff.is_mem=1;
    pipe_u_eff.writes=8'h01;
    uc_bvA[2]=1; uc_bsA[2]=0;
    uc_baseA[0].len=2; uc_baseA[0].simple=1; uc_baseA[0].is_mem=1;
    uc_baseA[0].is_load=1; uc_baseA[0].base=6;
    uc_baseA[0].mem_base_en=1; uc_baseA[0].addr_mask=8'h40;
    expect_prepare("independent translated page",1);
    fixture_hit=0; expect_prepare("TLB miss has no walk",0); fixture_hit=1;
    fixture_perm=3'b011; expect_prepare("supervisor page denies user",0);
    fixture_perm=3'b110; expect_prepare("nonpresent",0); fixture_perm=3'b111;
    gpr_o[6]=32'hfffffffd; seg_base[SG_DS]=3;
    expect_prepare("relocated full-limit EA wrap",0);
    gpr_o[6]=32'h1000; seg_base[SG_DS]=0;
    seg_limit[SG_DS]=32'hfff; expect_prepare("segment past limit",0);
    seg_limit[SG_DS]=32'hffffffff;
    seg_attr[SG_DS][2]=1; expect_prepare("expand-down",0); seg_attr[SG_DS][2]=0;
    seg_sel[SG_DS]=0; expect_prepare("null selector",0); seg_sel[SG_DS]=16'h10;
    pipe_u_eff.writes=8'h40; expect_prepare("older address RAW",0); pipe_u_eff.writes=8'h01;
    pending_mem_pen=3; expect_prepare("older timing debt",0); pending_mem_pen=0;
    cur_lin_nat=32'h2001; expect_prepare("real-bus unaligned owner has no modeled debt",1); cur_lin_nat=32'h2000;
    uc_bvA[2]=0; expect_prepare("missing boundary",0); uc_bvA[2]=1;
    rdA_set_q=7'h7f; expect_prepare("wrong returned code identity",0); rdA_set_q=0;
    ic_rd_collA=1; expect_prepare("collided code return",0); ic_rd_collA=0;
    gpr_o[6]=32'h101f; expect_prepare("dword line crossing",0);
    uc_baseA[0].w8=1; expect_prepare("contained line-end byte",1);
    uc_baseA[0].w8=0; gpr_o[6]=32'h1000;
    prime();
    if(mc_accept) $fatal(1,"consumed before older retirement");
    pipe_int_commit=1; #1;
    if(!mc_accept) $fatal(1,"checked successor failed handoff");
    pipe_int_commit=0;
    intr_take=1; check_cancel("IRQ"); intr_take=0;
    prime(); nmi_take=1; check_cancel("NMI"); nmi_take=0;
    prime(); smi_take=1; check_cancel("SMI"); smi_take=0;
    prime(); irq_shadow=1; check_cancel("shadow"); irq_shadow=0;
    prime(); fp_dbg_active=1; check_cancel("architectural debug"); fp_dbg_active=0;
    prime(); ic_snoop_valid1=1; check_cancel("SMC"); ic_snoop_valid1=0;
    prime(); exec_flush_all=1; check_cancel("code flush"); exec_flush_all=0;
    // Production flush/fill originate in non-S_PIPE states. Their raw
    // mem_ack-dependent terms must not enter the lookahead ACK cone.
    prime(); state=2; tlb_flush=1; check_cancel("TLB flush"); tlb_flush=0; state=S_PIPE;
    prime(); state=2; tlb_fill_en=1; check_cancel("TLB replacement"); tlb_fill_en=0; state=S_PIPE;
`ifdef VEN_PIPE_REG_LOAD_PRIME
    @(negedge clk); rst_n=0; pipe_int_commit=0;
    pipe_mem_active_q=0; pipe_u_eff.is_mem=0; pipe_u_eff.writes=0;
    @(negedge clk); rst_n=1;
    #1; if(!mc_prime_offer || !mem_next_req || mem_next_commit || mc_accept)
      $fatal(1,"independent register could not offer resident next load");
    @(posedge clk); #1;
    if(mc_valid_q) $fatal(1,"uncommitted register query retained stale owner");
    pipe_u_eff.writes=8'h40;
    #1; if(mc_prime_offer) $fatal(1,"register/address RAW primed load");
    pipe_u_eff.writes=0; pipe_new_mem_req=1;
    #1; if(mc_prime_offer) $fatal(1,"current memory owner primed twice");
    pipe_new_mem_req=0; intr_take=1;
    #1; if(mc_prime_offer) $fatal(1,"IRQ boundary primed younger load");
    intr_take=0; pipe_int_commit=1;
    #1; if(!mc_prime_accept || mem_next_addr!=fixture_phys)
      $fatal(1,"committed register failed resident prime");
    @(posedge clk); #1;
    if(mc_valid_q) $fatal(1,"primed load retained duplicate lookahead owner");
`endif
    $display("MEM-CHAIN-POLICY-OK (production predicates; not fault delivery)");
    $finish;
  end
  initial begin #100000; $fatal(1,"watchdog"); end
endmodule
