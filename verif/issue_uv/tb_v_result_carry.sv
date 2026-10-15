// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
module tb_v_result_carry;
  import ventium_pkg::*;
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
  logic [55:0] bytes_q, u_bytes;
  logic def16, cycle_mode;
  logic [31:0] flags, dst, src;
  fpd_t decoded, u_decoded, checked_decode, operand;
  logic [31:0] old_result, old_flags, new_result, new_flags, candidate_flags;
  logic pair_ok;
  logic pair_mem, pair_regmem, pair_store, pair_load_store;
  int mutant;
  longint unsigned decode_checks=0, alu_checks=0, rejected_cf=0, accepted_v=0;
  longint unsigned incdec_cf_one=0, byte_checks=0, word_checks=0, dword_checks=0;
  longint unsigned class_witness[5];
  decode decoder(.ib0(bytes_q[7:0]),.ib1(bytes_q[15:8]),.ib2(bytes_q[23:16]),
    .ib3(bytes_q[31:24]),.ib4(bytes_q[39:32]),.ib5(bytes_q[47:40]),.ib6(bytes_q[55:48]),
    .iflags(flags),.def16,.cycle_mode,.uop(decoded));
  decode u_decoder(.ib0(u_bytes[7:0]),.ib1(u_bytes[15:8]),.ib2(u_bytes[23:16]),
    .ib3(u_bytes[31:24]),.ib4(u_bytes[39:32]),.ib5(u_bytes[47:40]),.ib6(u_bytes[55:48]),
    .iflags(flags),.def16,.cycle_mode,.uop(u_decoded));
  always_comb begin
    checked_decode=decoded;
    // Required negative witness: a future bad decoder marks ADC V-capable.
    if(mutant==2 && decoded.simple && decoded.alu_op==ALU_ADC)
      checked_decode.pairs_second=1;
    candidate_flags=flags;
    if(mutant==1) candidate_flags[0]=0; // incorrect INC/DEC CF preservation
  end
  issue_uv issuer(.iu(u_decoded),.iv(checked_decode),.pair_ok
`ifdef VEN_P54_DUAL_LOAD_PAIR
    ,.pair_mem_ok(pair_mem)
`endif
`ifdef VEN_P54_REGMEM_PRIME
    ,.pair_regmem_ok(pair_regmem)
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
    ,.pair_store_ok(pair_store)
`endif
`ifdef VEN_P54_LOAD_STORE_PAIR
    ,.pair_load_store_ok(pair_load_store)
`endif
`ifdef VEN_PERF_PROFILE
    ,.pair_reason()
`endif
  );
`ifndef VEN_P54_DUAL_LOAD_PAIR
  assign pair_mem=0;
`endif
`ifndef VEN_P54_REGMEM_PRIME
  assign pair_regmem=0;
`endif
`ifndef VEN_P54_DUAL_STORE_PAIR
  assign pair_store=0;
`endif
`ifndef VEN_P54_LOAD_STORE_PAIR
  assign pair_load_store=0;
`endif
  v_pipe_parent reference(.v_d(operand),.v_dst_val(dst),.v_src_val(src),.eflags(flags),
    .v_alu(old_result),.v_flags(old_flags));
  v_pipe candidate(.v_d(operand),.v_dst_val(dst),.v_src_val(src),.eflags(candidate_flags),
    .v_alu(new_result),.v_flags(new_flags));

  task automatic decoder_check;
    bit cf_consumer;
    #1;
    decode_checks++;
    cf_consumer=checked_decode.alu_op==ALU_ADC || checked_decode.alu_op==ALU_SBB;
    if(checked_decode.simple && cf_consumer) begin
      rejected_cf++;
      if(checked_decode.pairs_second || pair_ok || pair_mem || pair_regmem || pair_store || pair_load_store)
        $fatal(1,"V-CARRY-ELIGIBILITY op=%02x bytes=%014x d16=%0b",checked_decode.alu_op,bytes_q,def16);
    end
    if(pair_ok || pair_mem || pair_regmem || pair_store || pair_load_store) begin
      accepted_v++;
      if(!checked_decode.pairs_second || cf_consumer) $fatal(1,"V-CARRY-ELIGIBILITY accepted bad V");
    end
    class_witness[0]+=longint'(pair_ok);class_witness[1]+=longint'(pair_mem);
    class_witness[2]+=longint'(pair_regmem);class_witness[3]+=longint'(pair_store);
    class_witness[4]+=longint'(pair_load_store);
  endtask

  task automatic arithmetic_check;
    #1;alu_checks++;
    if(new_result!==old_result || new_flags!==old_flags)
      $fatal(1,"V-CARRY-DATAPATH op=%0d width=%0d cf=%0b dst=%08x src=%08x result=%08x/%08x flags=%08x/%08x",
        operand.alu_op,fp_operand_width(operand),flags[0],dst,src,new_result,old_result,new_flags,old_flags);
    if((operand.alu_op==ALU_INC || operand.alu_op==ALU_DEC) && flags[0]) begin
      incdec_cf_one++;
      if(!new_flags[0]) $fatal(1,"V-CARRY-DATAPATH INC/DEC lost forwarded CF");
    end
    case(fp_operand_width(operand))
      1:byte_checks++;
      2:word_checks++;
      4:dword_checks++;
      default:$fatal(1,"bad test width");
    endcase
  endtask

  function automatic logic [31:0] corner(input int index);
    case(index)
      0:return 0;1:return 1;2:return 32'hffffffff;3:return 32'h7fffffff;
      4:return 32'h80000000;5:return 32'h0000ffff;6:return 32'h00008000;
      7:return 32'h00007fff;8:return 32'h000000ff;9:return 32'h00000080;
      10:return 32'h0000007f;11:return 32'h55555555;12:return 32'haaaaaaaa;
      13:return 32'h0000000f;14:return 32'h00000010;
      default:return (32'd1 << ((index-15)%32)) ^ (index>=47?32'hffffffff:32'd0);
    endcase
  endfunction

  initial begin
    mutant=0;void'($value$plusargs("mutant=%d",mutant));
    flags=2;dst=0;src=0;operand='0;bytes_q=0;u_bytes=56'h90;def16=0;cycle_mode=1;
    for(int i=0;i<5;i++)class_witness[i]=0;
    // All opcodes / ModR/M / applicable SIB encodings, both defaults and
    // cycle modes. Nonzero tail bytes exercise immediate/displacement decode.
    for(int mode=0;mode<4;mode++) begin
      def16=mode[0];cycle_mode=mode[1];
      // Settle and observe the leader explicitly before timed task calls.
      // Otherwise a passing decoder-only sweep can hide an inactive U input.
      u_bytes=56'h90;#1;
      if(!u_decoded.simple || !u_decoded.pairs_first || !u_decoded.is_nop)
        $fatal(1,"V-CARRY-FIXTURE: broad sweep has no decoded NOP leader");
      for(int op=0;op<256;op++)
        for(int mr=0;mr<256;mr++)
          for(int sib=0;sib<(((mr&7)==4 && (mr>>6)!=3)?256:1);sib++) begin
            bytes_q={32'h76543281,8'(sib),8'(mr),8'(op)};
            decoder_check();
          end
    end
    if(accepted_v<1000) $fatal(1,"V-CARRY-FIXTURE: broad sweep never exercised pairing");
    // Real decoded inputs exercise every enabled issuer class, not manually
    // fabricated pairability bits. Higher-level address/ACK admission is not
    // modeled by this leaf and remains a whole-core regression requirement.
    def16=0;cycle_mode=1;
    u_bytes=56'h90;bytes_q=56'h43;decoder_check();
    bytes_q=56'h001000001d8b;decoder_check();
    u_bytes=56'h00200000058b;decoder_check();
    u_bytes=56'h002000000589;bytes_q=56'h001000001d89;decoder_check();
    u_bytes=56'h00200000058b;decoder_check();
    if(class_witness[0]==0 || rejected_cf==0) $fatal(1,"missing pair/ADC controls");
`ifdef VEN_P54_DUAL_LOAD_PAIR
    if(class_witness[1]==0) $fatal(1,"missing dual-read witness");
`endif
`ifdef VEN_P54_REGMEM_PRIME
    if(class_witness[2]==0) $fatal(1,"missing register/read witness");
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
    if(class_witness[3]==0) $fatal(1,"missing dual-store witness");
`endif
`ifdef VEN_P54_LOAD_STORE_PAIR
    if(class_witness[4]==0) $fatal(1,"missing load/store witness");
`endif
    // Exhaustive byte operands; wide corners, carry/sign/parity boundaries
    // and upper-lane contamination, immediate vs register, both CF values.
    for(int width=0;width<3;width++)
      for(int op=0;op<32;op++) if(op!=int'(ALU_ADC) && op!=int'(ALU_SBB))
        for(int imm=0;imm<2;imm++)
          for(int cf=0;cf<2;cf++)
            for(int a=0;a<(width==0?256:79);a++)
              for(int b=0;b<(width==0?256:79);b++) begin
                operand='0;operand.alu_op=5'(op);operand.use_imm=imm[0];
                operand.w8=(width==0);operand.w16=(width==1);
                dst=width==0?(32'ha5ff0000|32'(a)):corner(a);
                src=width==0?(32'h5aff0000|32'(b)):corner(b);
                operand.imm=src;
                flags=32'h00550ad6|32'(cf);
                arithmetic_check();
              end
    if(incdec_cf_one==0 || byte_checks==0 || word_checks==0 || dword_checks==0)
      $fatal(1,"missing arithmetic coverage");
    $display("V-RESULT-CARRY-OK decode=%0d alu=%0d rejected_cf=%0d accepted_v=%0d incdec_cf_one=%0d bytes=%0d words=%0d dwords=%0d classes=%0d,%0d,%0d,%0d,%0d",
      decode_checks,alu_checks,rejected_cf,accepted_v,incdec_cf_one,byte_checks,word_checks,dword_checks,
      class_witness[0],class_witness[1],class_witness[2],class_witness[3],class_witness[4]);
    $finish;
  end
endmodule
