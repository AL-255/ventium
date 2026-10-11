  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
  fpd_t pipe_u_eff, pipe_v_eff;
  logic [31:0] eflags, u_flags, reference_flags, candidate_flags;
  logic [31:0] selected_flags, a, b, old_alu, new_alu, old_flags, new_flags;
  logic [4:0] u_shift_cnt;
  logic u_shcf, pipe_pair_eff;
  bit mutant_carry, mutant_zero;
  longint unsigned samples, paired_samples, unpaired_differences;
  // SOURCE_EXTRACTED_CARRY_BLOCKS
  always_comb begin
    selected_flags = candidate_flags;
    if (mutant_carry) selected_flags[0] = eflags[0];
    if (mutant_zero && pipe_u_eff.wflags && pipe_u_eff.is_shift)
      selected_flags[0] = u_shcf;
  end
  v_pipe control(.v_d(pipe_v_eff), .v_dst_val(a), .v_src_val(b),
    .eflags(reference_flags), .v_alu(old_alu), .v_flags(old_flags));
  v_pipe candidate(.v_d(pipe_v_eff), .v_dst_val(a), .v_src_val(b),
    .eflags(selected_flags), .v_alu(new_alu), .v_flags(new_flags));
  initial begin
    samples=0; paired_samples=0; unpaired_differences=0;
    pipe_u_eff='0; pipe_v_eff='0; eflags=0; u_flags=0;
    u_shift_cnt=0; u_shcf=0; pipe_pair_eff=0; a=0; b=0;
    mutant_carry=$test$plusargs("mutant_carry");
    mutant_zero=$test$plusargs("mutant_zero");
    for (int controls=0; controls<64; controls++)
      for (int count=0; count<32; count++)
        for (int op=0; op<14; op++)
          for (int width=0; width<3; width++)
            for (int pattern=0; pattern<8; pattern++) begin
              pipe_pair_eff=controls[0];
              pipe_u_eff.wflags=controls[1];
              pipe_u_eff.is_shift=controls[2];
              eflags=32'h02450ad4 | {31'd0,controls[3]};
              u_flags=32'h00df0800 | {31'd0,controls[4]};
              u_shcf=controls[5]; u_shift_cnt=5'(count);
              pipe_v_eff='0; pipe_v_eff.alu_op=5'(op);
              pipe_v_eff.w8=(width==0); pipe_v_eff.w16=(width==1);
              pipe_v_eff.use_imm=pattern[0];
              case (pattern)
                0: begin a=0; b=0; end
                1: begin a=32'hffffffff; b=1; end
                2: begin a=32'h80000000; b=32'h7fffffff; end
                3: begin a=32'h000000ff; b=1; end
                4: begin a=32'h00008000; b=32'h00007fff; end
                5: begin a=32'h0000ffff; b=1; end
                6: begin a=32'h55555555; b=32'haaaaaaaa; end
                7: begin a=32'h0000007f; b=1; end
              endcase
              pipe_v_eff.imm=b;
              #1;
              samples++;
              if (pipe_pair_eff) begin
                paired_samples++;
                assert ({old_alu,old_flags} === {new_alu,new_flags})
                  else $fatal(1,"V_CARRY_PAYLOAD_EQ controls=%0d count=%0d op=%0d width=%0d pattern=%0d",
                              controls,count,op,width,pattern);
              end else if ({old_alu,old_flags} !== {new_alu,new_flags})
                unpaired_differences++;
            end
    assert(samples==688128 && paired_samples==344064 && unpaired_differences>0)
      else $fatal(1,"V_CARRY_COVERAGE samples=%0d paired=%0d unused_different=%0d",
                  samples,paired_samples,unpaired_differences);
    $display("V-CARRY-PAYLOAD-OK samples=%0d paired=%0d unused_different=%0d",
             samples,paired_samples,unpaired_differences);
    $finish;
  end
