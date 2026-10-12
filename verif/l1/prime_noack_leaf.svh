// Actual fast decoder; the reference-dispatch descriptor inputs below are
// independent, not a substitute for testing the full reference decoder.
logic [7:0] ib0,ib1,ib2,ib3,ib4,ib5,ib6;
logic [31:0] iflags=32'h202,creg0=0;
logic [15:0] fstat=0;
logic def16=0,cycle_mode=1;
fpd_t u_d,pipe_u_eff,pipe_mem_u_q;
decode decoder(.*,.uop(u_d));
logic state=1; localparam logic S_PIPE=1;
logic fsm_case_enabled=1,pipe_mem_active_q=0,fp_issue_block=0;
logic exec_issue_ok=1,pipe_frontend_ready=1,mem_ack=0;
logic [6:0] stall_cnt=0,pending_mem_pen=0;
logic [2:0] mispred_bubbles=0;
logic pipe_mem_we_q=0,pipe_agi=0,fp_pipe_rd_haz=0;
logic sys_mode=1,sys_fp_ok=1,sys_fp_load_ok=1,sys_fp_store_ok=1;
logic stk_is16=0,fp_dbg_active=0,cs_extent_fault=0;
logic fp_sys_bail,pipe_new_load_req,pipe_new_store_req,pipe_new_mem_req;
logic pipe_load_req,pipe_store_req,pipe_mem_wait;
logic reference_arm,raw_candidate_arm,candidate_arm,unguarded_arm;
logic real_bus=1,mc_valid_q=0,mc_boundary_ok=1,paging_on=0;
logic mc_lookup_hit=1;
logic [2:0] mc_lookup_perm=3'b111,pipe_mem_seg=3'd3,d_seg=3'd3;
logic [1:0] eff_cpl=0;
logic [31:0] pipe_load_addr=32'h1000,mc_query_lin=32'h1000,d_ea=32'h1000;
logic [31:0] seg_limit[0:7];
logic [15:0] seg_sel[0:7];
logic [7:0] seg_attr[0:7];
logic [7:0] seg_pm_loaded=8'hff;
logic pipe_fetch_checked_handoff=0,rep_stos_cont_recovery_need=0,rep_stos_cont_take=0;
logic icsnp_v1=0,icsnp_v2=0,ic_snoop_valid2=0;
logic mc_fp_self_prime=0,mc_held_read_prime=0,mc_fresh_read_prime=0,pipe_pair_lookahead=0;
logic d_is_x87=0,pipe_sdispatch_shape_ok=1,d_mem_read=1,d_mem_write=0;
logic d_f_mem_read=1,d_f_mem_write=0;
kind_e d_kind=K_MULDIV;
fxop_e d_fxop=FX_AR_I32;
logic [3:0] d_f_mbytes=4'd4;
logic [2:0] d_ext_srcw=3'd4,d_w=3'd4;
logic real_mode=0,v86=0,cs_d=1;
logic dbg_step_active=0,dbg_block_issue=0,irq_shadow=0;
logic pipe_sdispatch_short_window_ok=1,pipe_fp_scalar_dispatch_ok=1;
logic fp_shared_mem_admit=0,fp_shared_direct=0;
logic agi_prime_select,agi_prime_offer,reference_agi,candidate_agi;
logic [2:0] agi_prime_width;
logic ref_prime_select,ref_prime_offer,reference_ref,candidate_ref;
logic [3:0] ref_prime_bytes,ref_prime_strb;
int mutant=0;
longint unsigned samples=0,fp_samples=0,agi_accepts=0,ref_int_accepts=0,ref_fp_accepts=0;
longint unsigned noack_accepts=0,held_rejections=0,blocked_rejections=0;
logic [31:0] rng=32'hb7f35491;

// ASSIGNMENTS_INSERTED_FROM_FROZEN_CORE

assign candidate_arm = (mutant==1) ? (raw_candidate_arm && !u_d.is_mem && !u_d.is_store) :
                       (mutant==2) ? (raw_candidate_arm && mem_ack) :
                       (mutant==3) ? unguarded_arm : raw_candidate_arm;

task automatic check;
  #1;
  samples++;
  if(u_d.is_fp) begin
    fp_samples++;
    if(u_d.simple || u_d.is_mem || u_d.is_store)
      $fatal(1,"PRIME_DECODE_INVARIANT opcode=%h %h",ib0,ib1);
  end
  if({reference_agi,reference_ref} !== {candidate_agi,candidate_ref})
    $fatal(1,"PRIME_EQUIV mutant=%0d opcode=%h %h active=%b agi=%b fsm=%b ack=%b old=%b%b new=%b%b",
      mutant,ib0,ib1,pipe_mem_active_q,pipe_agi,fsm_case_enabled,mem_ack,
      reference_agi,reference_ref,candidate_agi,candidate_ref);
  if(candidate_agi || candidate_ref) begin
    if(pipe_mem_active_q || pipe_new_mem_req || pipe_mem_wait || pipe_load_req || pipe_store_req)
      $fatal(1,"PRIME_MEMORY_OWNER");
    if(!mem_ack) noack_accepts++;
  end
  if(candidate_agi) agi_accepts++;
  if(candidate_ref && d_is_x87) ref_fp_accepts++;
  if(candidate_ref && !d_is_x87) ref_int_accepts++;
  if(pipe_mem_active_q && !candidate_agi && !candidate_ref) held_rejections++;
  if(!fsm_case_enabled && !candidate_agi && !candidate_ref) blocked_rejections++;
endtask

task automatic defaults;
  state=1;fsm_case_enabled=1;pipe_mem_active_q=0;fp_issue_block=0;
  exec_issue_ok=1;pipe_frontend_ready=1;stall_cnt=0;pending_mem_pen=0;
  mem_ack=0;pipe_agi=0;pipe_mem_we_q=0;fp_pipe_rd_haz=0;
  sys_mode=1;sys_fp_ok=1;sys_fp_load_ok=1;sys_fp_store_ok=1;
  stk_is16=0;fp_dbg_active=0;cs_extent_fault=0;mispred_bubbles=0;
endtask

initial begin
  if($value$plusargs("mutant=%d",mutant)) begin end
  pipe_mem_u_q='0;
  pipe_mem_u_q.simple=1;pipe_mem_u_q.is_mem=1;
  for(int s=0;s<8;s++) begin
    seg_limit[s]=32'hffffffff;seg_sel[s]=16'h10;seg_attr[s]=8'h93;
  end
  // Full opcode/ModRM space in both size and both decoder cycle modes.
  // Each is checked as AGI, integer reference, and x87 reference selection.
  for(int mode=0;mode<4;mode++) begin
    {def16,cycle_mode}=2'(mode);
    for(int op=0;op<65536;op++) begin
      {ib0,ib1}=16'(op);
      for(int tail=0;tail<4;tail++) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        {ib2,ib3,ib4,ib5,ib6}={rng,8'(tail*37)};
        iflags=rng;mem_ack=tail[0];
        pipe_agi=1;d_is_x87=0;check();
        pipe_agi=0;check();
        d_is_x87=1;check();
      end
    end
  end
  // Every SIB for all x87 opcode/ModRM pairs. Reference operands remain
  // independently driven; the actual fast descriptor invariant is checked.
  for(int mode=0;mode<4;mode++) begin
    {def16,cycle_mode}=2'(mode);
    for(int op=16'hd800;op<16'he000;op++) begin
      {ib0,ib1}=16'(op);
      for(int sib=0;sib<256;sib++) begin
        ib2=8'(sib);ib3=8'hff;ib4=8'h7f;ib5=8'h80;ib6=8'h01;
        mem_ack=sib[0];check();
      end
    end
  end
  def16=0;cycle_mode=1;
  for(int op=0;op<3;op++) begin
    defaults();
    case(op)
      0:begin {ib0,ib1}=16'h8b03;d_is_x87=0;end
      1:begin {ib0,ib1}=16'hf733;d_is_x87=0;end
      2:begin {ib0,ib1}=16'hd810;d_is_x87=1;end
    endcase
    // Exhaustive owner, event diversion, frontend, AGI and ACK combinations.
    for(int bits=0;bits<262144;bits++) begin
      {state,fsm_case_enabled,pipe_mem_active_q,fp_issue_block,
       exec_issue_ok,pipe_frontend_ready,mem_ack,pipe_mem_we_q,pipe_agi,
       sys_mode,fp_dbg_active,sys_fp_ok,sys_fp_load_ok,sys_fp_store_ok,
       fp_pipe_rd_haz,cs_extent_fault,stall_cnt[0],pending_mem_pen[0]}=18'(bits);
      check();
    end
    defaults();pipe_agi=(op==0);
    // Permission, poison, debugger, competing-prime and dispatch rejection.
    for(int bitno=0;bitno<24;bitno++) begin
      for(int value=0;value<2;value++) begin
        case(bitno)
          0:mc_valid_q=1'(value);1:mc_boundary_ok=1'(value);
          2:mc_fp_self_prime=1'(value);3:mc_held_read_prime=1'(value);
          4:mc_fresh_read_prime=1'(value);5:pipe_pair_lookahead=1'(value);
          6:pipe_fetch_checked_handoff=1'(value);7:rep_stos_cont_recovery_need=1'(value);
          8:rep_stos_cont_take=1'(value);9:icsnp_v1=1'(value);
          10:icsnp_v2=1'(value);11:ic_snoop_valid2=1'(value);
          12:dbg_step_active=1'(value);13:dbg_block_issue=1'(value);
          14:irq_shadow=1'(value);15:pipe_sdispatch_short_window_ok=1'(value);
          16:pipe_fp_scalar_dispatch_ok=1'(value);17:fp_shared_mem_admit=1'(value);
          18:fp_shared_direct=1'(value);19:d_mem_write=1'(value);
          20:d_f_mem_write=1'(value);21:real_mode=1'(value);
          22:v86=1'(value);23:cs_d=1'(value);
        endcase
        for(int offset=0;offset<32;offset++) begin
          mc_query_lin[4:0]=5'(offset);
          for(int perm=0;perm<16;perm++) begin
            {paging_on,mc_lookup_perm}=4'(perm);check();
          end
        end
      end
      // Restore all orthogonal guards before the next targeted sweep.
      mc_valid_q=0;mc_boundary_ok=1;mc_fp_self_prime=0;mc_held_read_prime=0;
      mc_fresh_read_prime=0;pipe_pair_lookahead=0;pipe_fetch_checked_handoff=0;
      rep_stos_cont_recovery_need=0;rep_stos_cont_take=0;icsnp_v1=0;icsnp_v2=0;ic_snoop_valid2=0;
      dbg_step_active=0;dbg_block_issue=0;irq_shadow=0;pipe_sdispatch_short_window_ok=1;
      pipe_fp_scalar_dispatch_ok=1;fp_shared_mem_admit=0;fp_shared_direct=0;
      d_mem_write=0;d_f_mem_write=0;real_mode=0;v86=0;cs_d=1;
      mc_query_lin=32'h1000;paging_on=0;mc_lookup_perm=7;
    end
  end
  if(!fp_samples || !agi_accepts || !ref_int_accepts || !ref_fp_accepts ||
     !noack_accepts || !held_rejections || !blocked_rejections) $fatal(1,"PRIME_COVERAGE");
  $display("PRIME-NOACK-OK samples=%0d fp=%0d agi=%0d ref_int=%0d ref_fp=%0d noack=%0d held=%0d blocked=%0d",
    samples,fp_samples,agi_accepts,ref_int_accepts,ref_fp_accepts,noack_accepts,held_rejections,blocked_rejections);
  $finish;
end
