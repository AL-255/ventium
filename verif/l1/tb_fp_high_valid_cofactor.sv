`timescale 1ns/1ps
module tb;
  localparam L1_LINE=32, L1_IDLE=0, L1_FILL=1, L1_BYP=2;
  localparam S_FLOAD=0, S_WALK=1;
  localparam BYPASS_RD_EN=1, OFFW=5, IDXW=7;
  localparam FX_FLD_M32=0, FX_FLD_M64=1, FX_FILD_M32=2, FX_FILD_M64=3,
             FX_AR_M32=4, FX_AR_M64=5, FX_AR_I32=6, FX_FCOM_M32=7, FX_FCOM_M64=8;
  logic rst_n, c_we, cacheable, golden, flush_all, snoop_inv_valid;
  logic stream_path, early_armed, rd_armed, rd_code_q, code_access;
  logic window_valid_q, shadow_valid_q, rd_full_line_q, c_next_req;
  logic bypass_q, fill_poison, code_fill_q, early_match, byp_match;
  logic code_word_reuse, c_hit_stream, c_rsp_valid, c_rsp_ready;
  logic [1:0] st, tag_current_hit, tag_prime_hit;
  logic [6:0] fset;
  logic [31:0] c_addr, rd_addr_q, c_next_addr;
  logic [31:5] shadow_line_addr_q;
  logic [3:0] c_wstrb;
  wire c_req, rd_match, window_reuse, shadow_reuse;
  wire mc_lookup_old, mc_lookup_prime, mc_lookup_next, hit;
  logic c_read_ack;
  wire c_ack=c_read_ack;
  wire old_hi, new_hi;
  logic seam_core_rst_n, core_req, core_smram_deny, core_route_deny, dma_drain_stall;
  logic core_d_l1c, core_d_l1c_last, cr0_cd;
  wire l1d_c_req, core_read_ack;
  wire l1d_c_read_ack=c_read_ack;
  wire l1d_c_ack=c_ack, l1d_c_rdata_hi_valid=old_hi;
  wire old_seam, new_seam;
  wire bus_read_ack=core_read_ack, bus_ack=core_read_ack;
  wire bus_rdata_hi_valid=old_seam;
  logic cycle_mode, q_f_mem_read, q_f_mem_write, fsm_case_enabled;
  logic [1:0] state;
  logic [3:0] q_f_mbytes, f_step, q_fxop;
  logic fx_eng, fx_start, fx_hold_e, fp_dbg_active, tf_at_issue, rf_at_issue;
  logic [31:0] cur_lin_nat;
  logic fp_shared_early_retire_ok;
  logic [15:0] fctrl, fstat;
  wire mem_read_ack=bus_read_ack && !fx_hold_e;
  wire old_take, new_take, old_cmd, new_cmd;
  integer checks=0, high_count=0, primary_count=0, shadow_count=0;
  integer take_count=0, narrow_count=0, second_count=0, next_blocked=0;
  logic [63:0] rng=64'hbf734cd93721a609;
  // EXTRACTED_EQUATIONS

  task automatic check;
    #1;
    checks++;
    if (old_hi !== new_hi || old_seam !== new_seam ||
        old_take !== new_take || old_cmd !== new_cmd)
      $fatal(1,"FP-HIGH-VALID-MISMATCH sample=%0d hi=%b/%b seam=%b/%b take=%b/%b cmd=%b/%b",
             checks,old_hi,new_hi,old_seam,new_seam,old_take,new_take,old_cmd,new_cmd);
    if (new_hi && (!c_ack || !c_req || c_we))
      $fatal(1,"FP-HIGH-VALID-MISMATCH missing read owner");
    if (old_hi) begin
      high_count++;
      if (shadow_reuse) shadow_count++; else primary_count++;
    end
    if (old_take) take_count++;
    if (old_cmd && q_f_mbytes==4) narrow_count++;
    if (old_cmd && q_f_mbytes==8 && f_step==1) second_count++;
    if (mc_lookup_next && !new_hi) next_blocked++;
  endtask

  task automatic defaults;
    rst_n=1; c_we=0; cacheable=1; golden=0; flush_all=0; snoop_inv_valid=0;
    stream_path=0; early_armed=0; rd_armed=1; rd_code_q=0; code_access=0;
    window_valid_q=1; shadow_valid_q=0; rd_full_line_q=1; c_next_req=0;
    bypass_q=0; fill_poison=0; code_fill_q=0; early_match=0; byp_match=0;
    code_word_reuse=0; c_hit_stream=0; c_rsp_valid=0; c_rsp_ready=0;
    st=L1_IDLE; tag_current_hit=1; tag_prime_hit=0; fset=0;
    c_addr=32'h1000; rd_addr_q=32'h1000; c_next_addr=32'h1020;
    shadow_line_addr_q=27'h82; c_wstrb=15;
    seam_core_rst_n=1; core_req=1; core_smram_deny=0; core_route_deny=0; dma_drain_stall=0;
    core_d_l1c=1; core_d_l1c_last=1; cr0_cd=0;
    cycle_mode=1; q_f_mem_read=1; q_f_mem_write=0; fsm_case_enabled=1; state=S_FLOAD;
    q_f_mbytes=8; f_step=0; q_fxop=FX_FLD_M64; fx_eng=0; fx_start=0; fx_hold_e=0;
    fp_dbg_active=0; tf_at_issue=0; rf_at_issue=0; cur_lin_nat=32'h1000;
    fp_shared_early_retire_ok=1; fctrl=16'h37f; fstat=0;
  endtask

  initial begin
    // Complete sweeps over each interacting guard group, followed by mixed
    // deterministic samples. The separate symbolic proof covers all bits.
    for (integer i=0;i<65536;i++) begin
      defaults();
      {rst_n,c_we,cacheable,golden,flush_all,snoop_inv_valid,stream_path,
       early_armed,rd_armed,window_valid_q,shadow_valid_q,rd_full_line_q,
       c_next_req,code_access,rd_code_q,tag_current_hit[0]}=16'(i);
      shadow_line_addr_q=c_addr[31:5];
      check();
    end
    for (integer i=0;i<65536;i++) begin
      defaults();
      {seam_core_rst_n,core_req,core_smram_deny,core_route_deny,dma_drain_stall,
       core_d_l1c,core_d_l1c_last,cr0_cd,cycle_mode,q_f_mem_read,q_f_mem_write,
       fsm_case_enabled,fx_hold_e,fp_dbg_active,tf_at_issue,rf_at_issue}=16'(i);
      check();
    end
    for (integer i=0;i<8192;i++) begin
      defaults();
      {rd_armed,window_valid_q,shadow_valid_q,rd_full_line_q,c_next_req,
       tag_current_hit,tag_prime_hit,rd_code_q,code_access,early_match,byp_match}=13'(i);
      for (integer offset=0;offset<32;offset++) begin
        c_addr=32'h1000+32'(offset);
        rd_addr_q=32'h1000+(i[0]?32'(offset):32'd4);
        shadow_line_addr_q=i[1]?27'h80:27'h82;
        check();
      end
    end
    for (integer bytes=0;bytes<16;bytes++)
      for (integer step=0;step<16;step++)
        for (integer op=0;op<16;op++) begin
          defaults(); q_f_mbytes=4'(bytes); f_step=4'(step); q_fxop=4'(op); check();
          cur_lin_nat=32'h1ff9; check();
          rd_full_line_q=0; shadow_valid_q=0; check();
          rd_armed=0; window_valid_q=0; check();
        end
    for (integer i=0;i<100000;i++) begin
      defaults();
      rng=rng^(rng<<13); rng=rng^(rng>>7); rng=rng^(rng<<17);
      {rst_n,c_we,cacheable,golden,flush_all,snoop_inv_valid,stream_path,
       early_armed,rd_armed,window_valid_q,shadow_valid_q,rd_full_line_q,
       c_next_req,code_access,rd_code_q,tag_current_hit,tag_prime_hit,
       st,c_wstrb,early_match,byp_match,code_word_reuse,c_hit_stream,c_rsp_valid,
       c_rsp_ready,cycle_mode,q_f_mem_read,q_f_mem_write,fsm_case_enabled,
       fx_eng,fx_start,fx_hold_e,fp_dbg_active,tf_at_issue,rf_at_issue,
       core_req,core_smram_deny,core_route_deny,dma_drain_stall}=45'(rng);
      c_addr=rng[31:0]; rd_addr_q=rng[4]?c_addr:c_addr^32'h20;
      shadow_line_addr_q=rng[5]?c_addr[31:5]:c_addr[31:5]^27'd1;
      q_f_mbytes=rng[9:6]; f_step=rng[13:10]; q_fxop=rng[17:14];
      cur_lin_nat=rng[63:32]; check();
    end
    if (!high_count || !primary_count || !shadow_count || !take_count ||
        !narrow_count || !second_count || !next_blocked)
      $fatal(1,"FP-HIGH-VALID-COVERAGE missing acceptance class");
    $display("FP-HIGH-VALID-OK checks=%0d high=%0d primary=%0d shadow=%0d take=%0d narrow=%0d second=%0d next_blocked=%0d",
             checks,high_count,primary_count,shadow_count,take_count,narrow_count,second_count,next_blocked);
    $finish;
  end
endmodule
