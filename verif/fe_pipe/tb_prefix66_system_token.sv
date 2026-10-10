// Actual private D1 include: context and paid-clock cancellation, not a decoder.
module tb_prefix66_system_token;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  localparam int S_PIPE=1;
  int state=S_PIPE;
  logic sys_mode=1,soc_en=1,cosim_en=1,def16=0,paging_on=1,smm_active=0;
  logic sys_fp_ok=1,real_mode=0,v86=0;
  logic [31:0] eip=32'hfffe,fbase=32'h10000000;
  wire [31:0] flin=fbase+eip;
  logic cycle_mode=1,pipe_mem_active_q=0,fp_occ_pending=0,fp_async_pending=0;
  logic xp_pend=0,xs_act=0,fx_act=0,pipe_frontend_ready=1;
  logic fp_issue_block_base=0,fsm_case_enabled=1,fp_dbg_active=0;
  logic dbg_block_issue=0,dbg_step_active=0,smi_take=0,nmi_take=0,intr_take=0;
  logic fp_pipe_rd_haz=0,exec_flush_all=0,icsnp_v1=0,icsnp_v2=0;
  logic ic_snoop_valid=0,pipe_int_commit=0,pipe_pair_eff=0,pipe_new_mem_req=0;
  logic [7:0] gpr_we=0;
  logic [6:0] stall_cnt=0,pending_mem_pen=0;
  logic [2:0] mispred_bubbles=0;
  typedef struct packed {logic is_mem,is_fp,is_stack,is_lea;} desc_t;
  desc_t pipe_u_eff='0,pipe_v_eff='0;
  logic p54_prefix66_candidate;
  assign p54_prefix66_candidate=p54_prefix66_context_ok;
  `include "core_prefix66_d1.svh"
  int checks=0;
  task automatic paid;
    #1;
    assert(p54_prefix66_hold && p54_prefix66_fire && !p54_prefix66_match)
      else $fatal(1,"new owner did not pay D1");
    @(posedge clk);#1;
    assert(p54_prefix66_match && !p54_prefix66_hold)
      else $fatal(1,"paid owner missing");
    checks++;
    @(negedge clk);
  endtask
  task automatic cancelled(input string name);
    @(posedge clk);#1;
    assert(!p54_prefix66_paid_q) else $fatal(1,"stale token: %s",name);
    checks++;
    @(negedge clk);
  endtask
  task automatic context_check(input bit expected,input string name);
    #1;
    assert(p54_prefix66_context_ok===expected) else $fatal(1,"context: %s",name);
    checks++;
  endtask
  initial begin
    #1;context_check(1,"paged relocated protected client");
    for(int mask=0;mask<128;mask++)begin
      {def16,smm_active,real_mode,v86,fp_dbg_active,dbg_step_active,sys_fp_ok}=
        7'(mask)^7'b0000001;
      context_check(mask==0,"all system context veto combinations");
    end
    {def16,smm_active,real_mode,v86,fp_dbg_active,dbg_step_active,sys_fp_ok}=7'b0000001;
    sys_mode=0;context_check(0,"SoC without system context is not user testbench");
    soc_en=0;cosim_en=0;paging_on=0;fbase=0;context_check(1,"old flat user mode");
    paging_on=1;context_check(0,"user paging remains excluded");
    sys_mode=1;soc_en=1;cosim_en=1;fbase=32'h10000000;
    @(negedge clk);rst_n=1;
    paid();repeat(3)begin @(posedge clk);#1;assert(p54_prefix66_match);end
    @(negedge clk);pipe_int_commit=1;cancelled("consume");pipe_int_commit=0;
    paid();fbase=32'h20000000;#1;
    assert(!p54_prefix66_match && p54_prefix66_hold && p54_prefix66_fire)
      else $fatal(1,"same EIP in different CS inherited D1");
    @(posedge clk);#1;assert(p54_prefix66_pc_q==flin);
    @(negedge clk);state=2;cancelled("state departure");state=S_PIPE;
    paid();ic_snoop_valid=1;#1;assert(p54_prefix66_hold && !p54_prefix66_fire);
    cancelled("external snoop");ic_snoop_valid=0;
    paid();icsnp_v1=1;cancelled("CPU snoop1");icsnp_v1=0;
    paid();icsnp_v2=1;cancelled("CPU snoop2");icsnp_v2=0;
    paid();exec_flush_all=1;cancelled("flush/CR3/A20");exec_flush_all=0;
    paid();smi_take=1;cancelled("SMI");smi_take=0;
    paid();nmi_take=1;cancelled("NMI");nmi_take=0;
    paid();intr_take=1;cancelled("INTR");intr_take=0;
    paid();dbg_block_issue=1;cancelled("external park");dbg_block_issue=0;
    paid();fp_dbg_active=1;cancelled("TF/RF/DR7");fp_dbg_active=0;
    paid();dbg_step_active=1;cancelled("STEP");dbg_step_active=0;
    paid();smm_active=1;cancelled("SMM");smm_active=0;
    paid();pipe_frontend_ready=0;cancelled("returned byte ownership");pipe_frontend_ready=1;
    paid();pipe_mem_active_q=1;cancelled("older memory");pipe_mem_active_q=0;
    paid();fp_occ_pending=1;cancelled("older FP occupancy");fp_occ_pending=0;
    paid();fp_async_pending=1;cancelled("older async FP");fp_async_pending=0;
    paid();xp_pend=1;cancelled("split read");xp_pend=0;
    paid();xs_act=1;cancelled("split store");xs_act=0;
    paid();fx_act=1;cancelled("fragment");fx_act=0;
    paid();rst_n=0;cancelled("reset");
    $display("PREFIX66-SYSTEM-TOKEN-OK checks=%0d",checks);$finish;
  end
endmodule
