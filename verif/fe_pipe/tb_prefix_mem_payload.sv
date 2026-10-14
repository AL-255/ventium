// Actual decoder + complete original/rewritten PREFIX66 payloads. This is a
// combinational leaf comparison, not a whole-core or guest acceptance test.
module tb_prefix_mem_payload;
  import ventium_decode_pkg::*;
  logic [7:0] ub[7];
  logic [31:0] eflags;
  logic def16,cycle_mode,p54_prefix66_context_ok;
  logic pipe_mem_active_q,fp_async_pending,fp_occ_pending,xp_pend,xs_act,fx_act;
  fpd_t parent_payload,fixed_payload,parent_base,fixed_base;
  logic parent_candidate,fixed_candidate;
  int unsigned checks=0,accepted=0,unshifted_memory=0,mutant=0;
  logic [31:0] rng=32'h51b38a72;
  prefix_payload_parent parent_dut(.*,.u_d(parent_payload),
    .raw_base(parent_base),.admitted(parent_candidate));
  prefix_payload_fixed fixed_dut(.*,.u_d(fixed_payload),
    .raw_base(fixed_base),.admitted(fixed_candidate));

  function automatic logic [31:0] random_word();
    rng ^= rng<<13; rng ^= rng>>17; rng ^= rng<<5;
    return rng;
  endfunction
  task automatic defaults;
    def16=0;cycle_mode=1;p54_prefix66_context_ok=1;
    {pipe_mem_active_q,fp_async_pending,fp_occ_pending,xp_pend,xs_act,fx_act}=0;
    eflags=32'h202;
    foreach(ub[i])ub[i]=8'h90;
  endtask
  task automatic check;
    fpd_t observed;
    #1;
    observed=fixed_payload;
    // Diagnostic negative variants: each corrupts a specific proposed
    // cofactor. The complete comparison must reject it without field masks.
    if(mutant==1)observed.is_mem=(!def16 && ub[0]==8'h66) ? fixed_base.is_mem : 1'b0;
    if(mutant==2)observed.mem_ss=0;
    if(mutant==3)observed.base=fixed_payload.mem_index;
    if(parent_candidate!==fixed_candidate || parent_base!==fixed_base)
      $fatal(1,"PREFIX-PAYLOAD-ADMISSION check=%0d",checks);
    if(parent_payload!==observed)
      $fatal(1,"PREFIX-PAYLOAD-MISMATCH check=%0d bytes=%h %h %h def16=%b mutant=%0d old=%h new=%h",
        checks,ub[0],ub[1],ub[2],def16,mutant,parent_payload,observed);
    if(parent_candidate)begin
      if({parent_base.w8,parent_base.is_mem,parent_base.is_store,parent_base.is_stack,
          parent_base.is_lea,parent_base.is_branch,parent_base.is_fp,parent_base.shift_cl,
          parent_base.is_load,parent_base.is_moffs,parent_base.base,parent_base.mem_base_en,
          parent_base.mem_index,parent_base.mem_index_en,parent_base.mem_disp,
          parent_base.mem_scale,parent_base.mem_ss,parent_base.mem_lhs,parent_base.addr_mask} !== '0)
        $fatal(1,"PREFIX-PAYLOAD-METADATA check=%0d bytes=%h %h %h",checks,ub[0],ub[1],ub[2]);
      accepted++;
    end
    if(!(!def16 && ub[0]==8'h66) && parent_payload.is_mem)unshifted_memory++;
    checks++;
  endtask
  initial begin
    if($value$plusargs("mutant=%d",mutant))begin end
    defaults();
    // An ordinary non-EAX SS-based load distinguishes all three mutants.
    ub[0]=8'h8b;ub[1]=8'h45;ub[2]=8'h08;check();
    // Exhaust opcode/ModRM/SIB-or-immediate bytes under enabled PREFIX66.
    // Remaining immediates and flags vary deterministically, not all 2^56
    // possible byte strings. Do not call this a formal full-decoder proof.
    defaults();ub[0]=8'h66;
    for(int opcode=0;opcode<256;opcode++)
      for(int modrm=0;modrm<256;modrm++)
        for(int third=0;third<256;third++)begin
          ub[1]=8'(opcode);ub[2]=8'(modrm);ub[3]=8'(third);
          ub[4]=8'(random_word());ub[5]=8'(random_word());ub[6]=8'(random_word());
          eflags=random_word();check();
        end
    // Every older-owner and context veto, 16-bit defaults, non-cycle mode,
    // and unprefixed decode. All outputs, including invalid payloads, compare.
    for(int context_id=0;context_id<10;context_id++)
      for(int opcode=0;opcode<256;opcode++)
        for(int modrm=0;modrm<256;modrm++)begin
          defaults();ub[0]=8'h66;ub[1]=8'(opcode);ub[2]=8'(modrm);
          case(context_id)
            0:pipe_mem_active_q=1;1:fp_async_pending=1;2:fp_occ_pending=1;
            3:xp_pend=1;4:xs_act=1;5:fx_act=1;
            6:p54_prefix66_context_ok=0;7:cycle_mode=0;8:def16=1;
            9:begin ub[0]=8'(opcode);ub[1]=8'(modrm);ub[2]=8'(random_word());end
          endcase
          ub[3]=8'(random_word());ub[4]=8'(random_word());
          ub[5]=8'(random_word());ub[6]=8'(random_word());eflags=random_word();check();
        end
    // Mixed owners/default widths and random full windows for extra controls.
    for(int n=0;n<100000;n++)begin
      {def16,cycle_mode,p54_prefix66_context_ok,pipe_mem_active_q,
       fp_async_pending,fp_occ_pending,xp_pend,xs_act,fx_act}=9'(random_word());
      foreach(ub[i])ub[i]=8'(random_word());
      eflags=random_word();check();
    end
    if(accepted==0 || unshifted_memory==0 || checks!=17532577)
      $fatal(1,"PREFIX-PAYLOAD-COVERAGE checks=%0d accepted=%0d memory=%0d",checks,accepted,unshifted_memory);
    $display("PREFIX-PAYLOAD-OK checks=%0d accepted=%0d memory=%0d",checks,accepted,unshifted_memory);
    $finish;
  end
endmodule
