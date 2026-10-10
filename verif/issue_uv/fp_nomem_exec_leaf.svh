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
  logic pipe_load_req,pipe_store_req,pipe_mem_wait,fp_fast_trap_bail;
  logic reference_arm,candidate_arm,reference_exec,candidate_exec,candidate_live_raw;
  longint unsigned samples=0,fp_samples=0,mem_fp_samples=0,active_samples=0;
  logic [31:0] rng=32'hb7f35491;

  // ASSIGNMENTS_INSERTED_FROM_FROZEN_CORE

  task automatic check;
    #1;
    samples++;
    if(candidate_live_raw !== reference_arm)
      $fatal(1,"NOMEM_SHARED_PERMIT opcode=%h %h ack=%b",ib0,ib1,mem_ack);
    if(u_d.is_fp) begin
      fp_samples++;
      if(u_d.fp_kind==FK_MEM) mem_fp_samples++;
      if(u_d.simple || u_d.is_mem || u_d.is_store)
        $fatal(1,"NOMEM_DECODE_INVARIANT opcode=%h %h",ib0,ib1);
    end
    if(pipe_mem_active_q) active_samples++;
    // Every production consumer is FP-qualified, including the legacy writer
    // and I-cache touch. Non-FP values of the internal qualifier are don't-care.
    if((reference_exec && pipe_u_eff.is_fp) !==
       (candidate_exec && pipe_u_eff.is_fp))
      $fatal(1,"NOMEM_EQUIV opcode=%h %h active=%b ack=%b traps=%h",ib0,ib1,pipe_mem_active_q,mem_ack,creg0);
    if(candidate_exec && pipe_u_eff.is_fp && pipe_mem_wait)
      $fatal(1,"NOMEM_WAIT_ESCAPE");
  endtask

  initial begin
    pipe_mem_u_q='0;
    // Deliberately stale FP in the outstanding packet: owner exclusion must
    // dominate payload, even if a future packet format contains an FP tag.
    pipe_mem_u_q.is_fp=1;
    for(int mode=0;mode<4;mode++) begin
      {def16,cycle_mode}=2'(mode);
      for(int op=0;op<65536;op++) begin
        {ib0,ib1}=16'(op);
        for(int tail=0;tail<8;tail++) begin
          rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
          {ib2,ib3,ib4,ib5,ib6}={rng,8'(tail*37)};
          iflags=rng; mem_ack=tail[0];
          check();
        end
      end
    end
    // All SIB encodings for all x87 opcodes/ModRMs in both decode modes.
    for(int mode=0;mode<4;mode++) begin
      {def16,cycle_mode}=2'(mode);
      for(int op=16'hd800;op<16'he000;op++) begin
        {ib0,ib1}=16'(op);
        for(int sib=0;sib<256;sib++) begin
          ib2=8'(sib); ib3=8'hff;ib4=8'h7f;ib5=8'h80;ib6=8'h01;
          mem_ack=sib[0]; check();
        end
      end
    end
    def16=0; cycle_mode=1;
    // All combinations of owner/frontend/trap/debug/stall controls. Also
    // include ordinary integer reads/writes, not only FP-positive examples.
    for(int op=0;op<7;op++) begin
      case(op)
        0:{ib0,ib1}=16'hd9e8;
        1:{ib0,ib1}=16'hd8c1;
        2:{ib0,ib1}=16'hd800;
        3:{ib0,ib1}=16'hdd00;
        4:{ib0,ib1}=16'h8b03;
        5:{ib0,ib1}=16'h8903;
        6:{ib0,ib1}=16'hdec1;
      endcase
      for(int bits=0;bits<65536;bits++) begin
        {state,fsm_case_enabled,pipe_mem_active_q,fp_issue_block,
         exec_issue_ok,pipe_frontend_ready,mem_ack,pipe_mem_we_q,
         sys_mode,fp_dbg_active,creg0[2],creg0[3],creg0[5],fstat[7],
         stall_cnt[0],pending_mem_pen[0]}=16'(bits);
        check();
      end
    end
    if(fp_samples==0 || active_samples==0) $fatal(1,"NOMEM_COVERAGE");
`ifdef VEN_FP_MEM_ADMIT
    if(mem_fp_samples==0) $fatal(1,"NOMEM_MEMORY_COVERAGE");
`endif
    $display("FP-NOMEM-MITER-OK samples=%0d fp=%0d memory_fp=%0d active=%0d",
             samples,fp_samples,mem_fp_samples,active_samples);
    $finish;
  end
