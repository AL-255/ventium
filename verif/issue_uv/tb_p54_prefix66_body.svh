// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Included by the runner's auto-ported reference-decoder harness. Actual
// production decode/token includes and U datapath/pair checker are under test.
module tb_p54_prefix66;
  import ventium_pkg::*;
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_sys_pkg::*;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  localparam int S_PIPE=1;
  int state=S_PIPE;
  logic [7:0] ub[7],vb[7],refbytes[16];
  logic [31:0] gpr_o[NUM_GPR],eflags=32'h202,eip=32'h0804fffe,fbase=0;
  logic sys_mode=0,soc_en=0,cosim_en=0,def16=0,paging_on=0,smm_active=0;
  logic cycle_mode=1,pipe_mem_active_q=0,fp_occ_pending=0,fp_async_pending=0;
  logic xp_pend=0,xs_act=0,fx_act=0,pipe_frontend_ready=1;
  logic fp_issue_block_base=0,fsm_case_enabled=1,fp_dbg_active=0;
  logic dbg_block_issue=0,dbg_step_active=0,smi_take=0,nmi_take=0,intr_take=0;
  logic fp_pipe_rd_haz=0,exec_flush_all=0,icsnp_v1=0,icsnp_v2=0;
  logic ic_snoop_valid=0,pipe_int_commit=0,pipe_pair_eff=0,pipe_new_mem_req=0;
  logic [7:0] gpr_we=0;
  logic [6:0] stall_cnt=0,pending_mem_pen=0;
  logic [2:0] mispred_bubbles=0;
  fpd_t u_d,v_d,pipe_u_eff,pipe_v_eff,legacy;
  logic pair_ok;
  logic [31:0] u_alu,u_flags,u_sh,u_shm1;
  logic u_shcf;
  logic [4:0] u_shcnt;
  int admitted=0,checks=0,token_checks=0,pair_checks=0;
  logic [31:0] random_q=32'h9d24ba11;
  `include "core_prefix66_decode.svh"
  `include "core_prefix66_d1.svh"
  assign pipe_u_eff=u_d;
  assign pipe_v_eff=v_d;
  decode v_decode(.ib0(vb[0]),.ib1(vb[1]),.ib2(vb[2]),.ib3(vb[3]),
    .ib4(vb[4]),.ib5(vb[5]),.ib6(vb[6]),.iflags(eflags),.def16,.cycle_mode,.uop(v_d));
  decode old_decode(.ib0(ub[0]),.ib1(ub[1]),.ib2(ub[2]),.ib3(ub[3]),
    .ib4(ub[4]),.ib5(ub[5]),.ib6(ub[6]),.iflags(eflags),.def16,.cycle_mode,.uop(legacy));
  issue_uv pair_checker(.iu(u_d),.iv(v_d),.pair_ok);
  u_pipe datapath(.u_d,.u_dst_val(gpr_o[u_d.dst]),.u_src_val(gpr_o[u_d.src]),
    .eflags,.u_alu,.u_flags,.u_sh,.u_shm1,.u_shcf,.u_shcnt);
  `include "p54_prefix66_reference_ports.svh"
  always_comb begin
    for (int i=0;i<16;i++) begin
      if (i<7) refbytes[i]=ub[i];
      else refbytes[i]=8'd0;
    end
  end
  task automatic next_random;
    random_q^=random_q<<13;random_q^=random_q>>17;random_q^=random_q<<5;
  endtask
  task automatic compare_reference;
    logic [31:0] a,b,result,flags,merged;
    logic [5:0] count;
    #1;
    if (!p54_prefix66_candidate) return;
    admitted++;
    if (d_unknown || d_w!=3'd2 || d_len!=u_d.len ||
        d_writes_reg!=u_d.wreg || d_writes_flags!=u_d.wflags ||
        d_dst_reg!=u_d.dst || !u_d.w16 || u_d.w8 ||
        !u_d.pairs_first || u_d.pairs_second ||
        d_mem_read || d_mem_write || d_is_branch || d_is_x87)
      $fatal(1,"PREFIX66 reference descriptor mismatch op%02x modrm%02x",ub[1],ub[2]);
    a=wmask(gpr_o[d_dst_reg],3'd2);
    if (u_d.is_shift) begin
      if (d_kind!=K_SHIFT || d_shrot!=u_d.shrot || d_shift_cl)
        $fatal(1,"PREFIX66 shift metadata mismatch");
      count=d_shift_one?6'd1:{1'b0,d_shift_imm};
      if (u_shcnt!=count[4:0] ||
          u_sh!==shrot_result(d_shrot,a,count,eflags[0],3'd2) ||
          u_shcf!==shrot_cf(d_shrot,a,count,eflags[0],3'd2))
        $fatal(1,"PREFIX66 shift datapath mismatch");
      result=u_sh;
    end else begin
      if (d_kind!=K_ALU || d_alu_op!=u_d.alu_op)
        $fatal(1,"PREFIX66 ALU metadata mismatch");
      b=d_use_imm?wmask(d_imm,3'd2):
        (d_alu_op inside {ALU_INC,ALU_DEC})?32'd1:wmask(gpr_o[d_src_reg],3'd2);
      result=alu_result(d_alu_op,a,b,eflags[0]);
      flags=flags_next(d_alu_op,a,b,result,eflags,3'd2);
      if (u_alu!==result || (d_writes_flags && u_flags!==flags))
        $fatal(1,"PREFIX66 ALU result/flags mismatch op%02x modrm%02x",ub[1],ub[2]);
      if (d_use_imm && u_d.use_imm && d_imm[15:0]!=u_d.imm[15:0])
        $fatal(1,"PREFIX66 immediate mismatch");
    end
    merged=reg_merge(gpr_o[d_dst_reg],result,3'd2,1'b0);
    if (merged[31:16]!=gpr_o[d_dst_reg][31:16])
      $fatal(1,"PREFIX66 corrupted destination high half");
    checks++;
  endtask
  task automatic token_probe(input bit hold_expected,input bit fire_expected,
                             input string name);
    #1;
    if (p54_prefix66_hold!==hold_expected || p54_prefix66_fire!==fire_expected)
      $fatal(1,"PREFIX66 token %s hold%0b fire%0b",name,
             p54_prefix66_hold,p54_prefix66_fire);
    token_checks++;
  endtask
  task automatic paid_prefix;
    token_probe(1,1,"new PC pays real D1");
    @(posedge clk); #1;
    if (!p54_prefix66_match || p54_prefix66_hold)
      $fatal(1,"PREFIX66 paid token not installed");
    @(negedge clk);
  endtask
  task automatic clear_on_edge(input string name);
    @(posedge clk); #1;
    if (p54_prefix66_paid_q) $fatal(1,"PREFIX66 stale token %s",name);
    token_checks++;
    @(negedge clk);
  endtask
  initial begin
    for(int r=0;r<NUM_GPR;r++)gpr_o[r]=32'hdead8001+32'(r*771);
    for(int i=0;i<7;i++)begin ub[i]=0;vb[i]=0;end
    // Enumeration is combinational while reset is held, so no token can hide
    // a paid clock. Test the REAL reference decoder rather than a shape copy.
    for(int op=0;op<256;op++)for(int mr=0;mr<256;mr++)begin
      ub[0]=8'h66;ub[1]=8'(op);ub[2]=8'(mr);
      for(int i=3;i<7;i++)begin next_random();ub[i]=random_q[7:0];end
      eflags[0]=mr[0];compare_reference();
    end
    if(admitted<1000)$fatal(1,"PREFIX66 insufficient whitelist coverage");
    // Macro-on prefix-free output remains exactly the previous decoder.
    for(int mode=0;mode<2;mode++)begin
      def16=1'(mode);
      for(int op=0;op<256;op++)begin
        if(op==8'h66 && !def16)continue;
        ub[0]=8'(op);ub[1]=8'hc3;#1;
        if(u_d!==legacy)$fatal(1,"PREFIX66 changed legacy decode op%02x",op);
        checks++;
      end
    end
    def16=0;ub[0]=8'h66;ub[1]=8'hd1;ub[2]=8'he8;
    for(int i=3;i<7;i++)ub[i]=0;
    vb[0]=8'h83;vb[1]=8'he2;vb[2]=8'h01;#1;
    if(!prefix_pair_qualified)$fatal(1,"PREFIX66 independent SHR AX / AND EDX rejected");pair_checks++;
    vb[0]=8'h89;vb[1]=8'hc2;#1;
    if(prefix_pair_qualified)$fatal(1,"PREFIX66 RAW EAX accepted");pair_checks++;
    vb[0]=8'hb8;vb[1]=1;#1;
    if(prefix_pair_qualified)$fatal(1,"PREFIX66 WAW EAX accepted");pair_checks++;
    ub[1]=8'h39;ub[2]=8'hd0;vb[0]=8'h75;vb[1]=2;#1;
    if(!prefix_pair_qualified)$fatal(1,"PREFIX66 CMP / Jcc rejected");pair_checks++;
    vb[0]=8'h66;vb[1]=8'h40;#1;
    if(prefix_pair_qualified)$fatal(1,"PREFIX66 prefixed V accepted");pair_checks++;

    // Every physical GPR parent matters, including explicit SP/ESP writes.
    // Real issue_uv plus the extracted actual production guard is the gate.
    // Unequal MOV-immediate destinations are independent legal PU/V pairs.
    for(int ur=0;ur<8;ur++)for(int vr=0;vr<8;vr++)begin
      ub[1]=8'hb8+8'(ur);ub[2]=8'h34;ub[3]=8'h12;
      vb[0]=8'hb8+8'(vr);vb[1]=8'h32;vb[2]=8'h54;
      vb[3]=8'h76;vb[4]=8'h98;#1;
      if(prefix_pair_qualified !== (ur!=vr))
        $fatal(1,"PREFIX66 explicit WAW parent U%0d V%0d pair%0b",ur,vr,prefix_pair_qualified);
      pair_checks++;
    end

    ub[1]=8'hd1;ub[2]=8'he8;vb[0]=8'h90;
    @(negedge clk);rst_n=1;
    paid_prefix();
    // Consumption is a single ordinary commit edge. Same-PC loop return
    // must pay again, rather than reuse a persistent instruction descriptor.
    pipe_int_commit=1;clear_on_edge("consumed once");pipe_int_commit=0;
    paid_prefix();
    eip=eip+32'd2;token_probe(1,1,"PC mismatch repays");
    @(posedge clk);#1;if(!p54_prefix66_match)$fatal(1,"new PC token absent");
    @(negedge clk);exec_flush_all=1;clear_on_edge("flush");exec_flush_all=0;
    paid_prefix();ic_snoop_valid=1;token_probe(1,0,"external DMA vetoes consume");
    clear_on_edge("external DMA");ic_snoop_valid=0;
    paid_prefix();icsnp_v1=1;clear_on_edge("CPU SMC history");icsnp_v1=0;
    paid_prefix();dbg_block_issue=1;fp_issue_block_base=1;
    token_probe(0,0,"paid debugger park");clear_on_edge("debug park");
    dbg_block_issue=0;fp_issue_block_base=0;
    paid_prefix();dbg_step_active=1;clear_on_edge("host step");dbg_step_active=0;
    paid_prefix();fp_dbg_active=1;clear_on_edge("TF RF DR");fp_dbg_active=0;
    paid_prefix();nmi_take=1;clear_on_edge("accepted event");nmi_take=0;
    paid_prefix();state=0;clear_on_edge("leave issue boundary");state=S_PIPE;
    paid_prefix();sys_mode=1;clear_on_edge("system CS mode");sys_mode=0;
    paid_prefix();fbase=32'h10000;clear_on_edge("linear base changed");fbase=0;
    // Registered older owners may allow ordinary INT issue in the wider
    // core, but this narrow prefix must fall back rather than issue unpaid.
    // In particular raw next-prefix bytes cannot veto/accuse an old memory
    // packet's legal commit: the new candidate itself is absent.
    for(int owner=0;owner<6;owner++)begin
      paid_prefix();
      case(owner)
        0:pipe_mem_active_q=1;
        1:fp_async_pending=1;
        2:fp_occ_pending=1;
        3:xp_pend=1;
        4:xs_act=1;
        5:fx_act=1;
      endcase
      #1;
      if(p54_prefix66_candidate || u_d.simple)
        $fatal(1,"PREFIX66 old owner %0d exposed unpaid descriptor",owner);
      token_probe(0,0,"registered old owner falls back");
      if(owner==0)begin pipe_int_commit=1;gpr_we=8'h04;end
      clear_on_edge("registered old owner cancels token");
      pipe_int_commit=0;gpr_we=0;
      pipe_mem_active_q=0;fp_async_pending=0;fp_occ_pending=0;
      xp_pend=0;xs_act=0;fx_act=0;
    end
    pipe_frontend_ready=0;token_probe(0,0,"cold/crossline/stale BRAM cannot block fill");
    clear_on_edge("missing returned ownership");pipe_frontend_ready=1;
    cycle_mode=0;#1;
    if(p54_prefix66_candidate || u_d.simple)$fatal(1,"functional prefix bypass admitted");
    cycle_mode=1;stall_cnt=1;token_probe(1,0,"existing debt precedes D1");stall_cnt=0;
    mispred_bubbles=1;token_probe(1,0,"mispredict precedes D1");mispred_bubbles=0;
    fsm_case_enabled=0;token_probe(1,0,"fault/walk suppresses prefix capture");fsm_case_enabled=1;
    // Width is operand-only: default32 PC crossing low16 FFFF stays full32.
    if(eip+{28'd0,u_d.len}!=32'h08050003)
      $fatal(1,"PREFIX66 fixture PC/length unexpected");
    $display("P54-PREFIX66-LEAF-OK admitted=%0d checks=%0d token=%0d pairing=%0d",
             admitted,checks,token_checks,pair_checks);
    $finish;
  end
endmodule
