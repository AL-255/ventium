// Actual overlap include with explicit mocked cache/context/retirement inputs.
// This leaf tests admission, not architectural interrupt or fault delivery.
module tb_prefix_ex_system_guards;
  import ventium_decode_pkg::*;
  // The include only compares SYS_NONE; production's full enum is declared
  // at compilation-unit scope in core.sv. Model its zero/other distinction.
  typedef enum logic [5:0] {SYS_NONE=0,SYS_OTHER=1} sysop_e;
  localparam int SG_CS=1,S_EXEC=5,IWORDS=4;
  logic clk=0,rst_n=0;
  logic [31:0] eip,q_pc,next_eip,fbase,flin,seg_limit[6],dbg_bp_addr;
  logic [7:0] refdecode_ibuf[16],gpr_we,d_addr_mask;
  logic [3:0] d_len,q_len;
  logic [2:0] d_w;
  kind_e q_kind,d_kind;
  sysop_e q_sysop,d_sysop;
  int state,checks=0;
  logic [6:0] pending_mem_pen,stall_cnt;
  logic [2:0] mispred_bubbles;
  logic cycle_mode,fsm_case_enabled,sys_mode,soc_en,cosim_en,def16,paging_on,smm_active;
  logic sys_fp_ok,real_mode,v86,cs_d,irq_shadow,intr,nmi,smi_pending,nmi_pending;
  logic fold_pending_r,dbg_block_issue,dbg_step_active,fp_dbg_active,tf_at_issue,rf_at_issue;
  logic dbg_bp_en,smi_take,nmi_take,intr_take,fp_occ_pending,fp_async_pending;
  logic pipe_mem_active_q,fpp_valid,fpp2_valid,xp_pend,xs_act,fx_act;
  logic exec_issue_ok,icsnp_v1,icsnp_v2,ic_snoop_valid;
  logic first_returned,last_returned,retire_valid,p54_int_exec_hold,p54_int_exec_active_q;
  logic d_unknown,d_halt,d_is_x87,d_is_fwait,d_is_branch,d_int,d_int80,d_iret;
  logic d_ud2,d_rsm,d_cacheinv,d_lock,d_io,d_writes_reg,d_mem_read,d_mem_write,d_mem_dst;
  logic d_is_push,d_is_pop,d_is_lea,d_seg_load,d_store_sreg,d_push_sreg,d_pop_sreg;
  logic d_xlat,d_callf_mem,d_jmpf_mem,d_cld,d_std,d_cli,d_sti,d_clc,d_stc,d_cmc,d_clts;
  logic pfx_addr,pfx_seg,pfx_lock,d_addr_mask_known;
  logic [1:0] pfx_rep;
  logic q_writes_reg,q_mem_write,q_mem_dst,q_is_branch,q_is_push,q_is_pop,q_is_lea;
  logic q_is_x87,q_io,q_lock,q_seg_load,q_store_sreg,q_push_sreg,q_pop_sreg,q_xlat;
  logic q_callf_mem,q_jmpf_mem,q_cld,q_std,q_cli,q_sti,q_clc,q_stc,q_cmc,q_clts;
  assign q_pc=eip;
  assign next_eip=q_pc+{28'd0,q_len};
  assign flin=fbase+eip;
  function automatic logic ic_buffered(input logic [31:0] address);
    return address==fbase+next_eip ? first_returned : last_returned;
  endfunction
  `include "core_prefix_ex_chain.svh"

  task automatic defaults;
    eip=32'h200;fbase=32'h10000000;dbg_bp_addr=0;
    foreach(seg_limit[i])seg_limit[i]=32'hffffffff;
    foreach(refdecode_ibuf[i])refdecode_ibuf[i]=8'h90;
    refdecode_ibuf[0]=8'h0f;refdecode_ibuf[1]=8'haf;refdecode_ibuf[2]=8'hd6;
    gpr_we=8'h40;d_addr_mask=0;d_len=3;q_len=3;d_w=4;
    q_kind=K_EXT;d_kind=K_IMUL2;q_sysop=SYS_NONE;d_sysop=SYS_NONE;
    state=S_EXEC;pending_mem_pen=0;stall_cnt=0;mispred_bubbles=0;
    cycle_mode=1;fsm_case_enabled=1;sys_mode=1;soc_en=1;cosim_en=1;def16=0;
    paging_on=1;smm_active=0;sys_fp_ok=1;real_mode=0;v86=0;cs_d=1;
    irq_shadow=0;intr=0;nmi=0;smi_pending=0;nmi_pending=0;fold_pending_r=0;
    dbg_block_issue=0;dbg_step_active=0;fp_dbg_active=0;tf_at_issue=0;rf_at_issue=0;
    dbg_bp_en=0;smi_take=0;nmi_take=0;intr_take=0;fp_occ_pending=0;fp_async_pending=0;
    pipe_mem_active_q=0;fpp_valid=0;fpp2_valid=0;xp_pend=0;xs_act=0;fx_act=0;
    exec_issue_ok=1;icsnp_v1=0;icsnp_v2=0;ic_snoop_valid=0;
    first_returned=1;last_returned=1;retire_valid=1;p54_int_exec_hold=1;p54_int_exec_active_q=0;
    {d_unknown,d_halt,d_is_x87,d_is_fwait,d_is_branch,d_int,d_int80,d_iret,
     d_ud2,d_rsm,d_cacheinv,d_lock,d_io,d_mem_read,d_mem_write,d_mem_dst,
     d_is_push,d_is_pop,d_is_lea,d_seg_load,d_store_sreg,d_push_sreg,d_pop_sreg,
     d_xlat,d_callf_mem,d_jmpf_mem,d_cld,d_std,d_cli,d_sti,d_clc,d_stc,d_cmc,d_clts,
     pfx_addr,pfx_seg,pfx_lock}=0;
    d_writes_reg=1;d_addr_mask_known=1;pfx_rep=0;
    {q_mem_write,q_mem_dst,q_is_branch,q_is_push,q_is_pop,q_is_lea,q_is_x87,q_io,
     q_lock,q_seg_load,q_store_sreg,q_push_sreg,q_pop_sreg,q_xlat,q_callf_mem,
     q_jmpf_mem,q_cld,q_std,q_cli,q_sti,q_clc,q_stc,q_cmc,q_clts}=0;
    q_writes_reg=1;
  endtask
  task automatic check(input bit allowed);
    #1;
    if(p54_prefix_ex_take!==allowed)$fatal(1,"prefix system guard %0d got=%b expected=%b",
                                         checks,p54_prefix_ex_take,allowed);
    checks++;
  endtask
  initial begin
    defaults();#1;clk=1;#1;clk=0;rst_n=1;check(1);
    for(int deny=0;deny<41;deny++)begin
      defaults();
      case(deny)
        0:cycle_mode=0;1:fsm_case_enabled=0;2:state=1;3:def16=1;
        4:smm_active=1;5:sys_fp_ok=0;6:real_mode=1;7:v86=1;8:cs_d=0;
        9:irq_shadow=1;10:intr=1;11:nmi=1;12:smi_pending=1;13:nmi_pending=1;
        14:fold_pending_r=1;15:dbg_block_issue=1;16:dbg_step_active=1;
        17:fp_dbg_active=1;18:tf_at_issue=1;19:rf_at_issue=1;
        20:begin dbg_bp_en=1;dbg_bp_addr=next_eip;end
        21:smi_take=1;22:nmi_take=1;23:intr_take=1;24:fp_occ_pending=1;
        25:fp_async_pending=1;26:pipe_mem_active_q=1;27:fpp_valid=1;
        28:fpp2_valid=1;29:xp_pend=1;30:xs_act=1;31:fx_act=1;
        32:pending_mem_pen=1;33:stall_cnt=1;34:mispred_bubbles=1;
        35:exec_issue_ok=0;36:icsnp_v1=1;37:icsnp_v2=1;38:ic_snoop_valid=1;
        39:first_returned=0;40:last_returned=0;
      endcase
      check(0);
    end
    defaults();d_mem_read=1;check(0);
    defaults();d_mem_write=1;check(0);
    defaults();d_kind=K_EXT;refdecode_ibuf[1]=8'hbf;check(0); // EXT->EXT veto
    defaults();refdecode_ibuf[0]=8'h66;refdecode_ibuf[1]=8'h0f;check(0);
    defaults();refdecode_ibuf[0]=8'h66;refdecode_ibuf[1]=8'h69;d_w=2;check(1);
    defaults();d_writes_reg=0;check(0);
    defaults();q_kind=K_ALU;check(0);
    for(int offset=0;offset<4096;offset++)begin
      defaults();eip=32'h3000+32'(offset);check(offset<=4077);
    end
    for(int limit=512;limit<532;limit++)begin
      defaults();seg_limit[SG_CS]=32'(limit);check(limit>=517);
    end
    defaults();eip=32'hfffffffd;check(0); // wrapped successor is another page
    defaults();sys_mode=0;soc_en=0;cosim_en=0;paging_on=0;fbase=0;check(1);
    $display("PREFIX-EX-SYSTEM-GUARDS-OK checks=%0d",checks);
    $finish;
  end
endmodule
