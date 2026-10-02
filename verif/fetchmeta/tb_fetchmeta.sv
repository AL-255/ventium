// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
module tb_fetchmeta;
  import ventium_pkg::*;
  logic [7:0] ibuf [16];
  logic [4:0] ibuf_valid;
  logic [31:0] gpr [NUM_GPR];
  logic [31:0] eflags;
  logic sys_mode, def16, seg_real, smm_active, paging_on, cosim_en, soc_en;
  logic [3:0] d_len;
  logic [4:0] d_fetch_need, d_fetch_len, d_fetch_fault_len;
  logic d_fetch_modrm, d_fetch_meta_ready, d_fetch_overlong;
  logic d_fetch_header_ready, d_fetch_header_x87, d_fetch_header_cpl0;
  logic d_is_x87, d_unknown, d_smsw, d_writes_reg;
  sysop_e d_sysop;
  logic [2:0] d_w, d_sys_creg, d_dst_reg;
  int checks=0;

  // Every port is named, including intentionally unobserved semantic outputs.
  // This keeps structural PINMISSING checking active as the decoder evolves.
  decode_stages dut (
    .ibuf(ibuf),
    .ibuf_valid(ibuf_valid),
    .gpr(gpr),
    .eflags(eflags),
    .sys_mode(sys_mode),
    .def16(def16),
    .seg_real(seg_real),
    .smm_active(smm_active),
    .paging_on(paging_on),
    .cosim_en(cosim_en),
    .soc_en(soc_en),
    .modrm_reg(),
    .pfx_rep(),
    .pfx_seg(),
    .pfx_lock(),
    .pfx_addr(),
    .eff_opsize(),
    .eff_addr(),
    .d_len(d_len),
    .d_fetch_need(d_fetch_need),
    .d_fetch_len(d_fetch_len),
    .d_fetch_modrm(d_fetch_modrm),
    .d_fetch_meta_ready(d_fetch_meta_ready),
    .d_fetch_overlong(d_fetch_overlong),
    .d_fetch_header_ready(d_fetch_header_ready),
    .d_fetch_header_x87(d_fetch_header_x87),
    .d_fetch_header_cpl0(d_fetch_header_cpl0),
    .d_fetch_fault_len(d_fetch_fault_len),
    .d_halt(),
    .d_cacheinv(),
    .d_lock(),
    .d_is_fwait(),
    .d_int80(),
    .d_unknown(d_unknown),
    .d_int(),
    .d_int_vec(),
    .d_int_imm(),
    .d_int_cond_of(),
    .d_iret(),
    .d_ud2(),
    .d_rsm(),
    .d_f00f(),
    .d_is_branch(),
    .d_branch_taken(),
    .d_rel(),
    .d_alu_op(),
    .d_writes_reg(d_writes_reg),
    .d_writes_flags(),
    .d_mem_read(),
    .d_mem_write(),
    .d_mem_dst(),
    .d_dst_reg(d_dst_reg),
    .d_src_reg(),
    .d_imm(),
    .d_use_imm(),
    .d_is_push(),
    .d_is_pop(),
    .d_is_lea(),
    .d_is_mov(),
    .d_is_nop(),
    .d_ea(),
    .d_addr_mask(),
    .d_addr_mask_known(),
    .d_w(d_w),
    .d_dst_high8(),
    .d_src_high8(),
    .d_kind(),
    .d_shrot(),
    .d_shift_cl(),
    .d_shift_one(),
    .d_shift_imm(),
    .d_shrd(),
    .d_md(),
    .d_imul_3op(),
    .d_imul_imm(),
    .d_ext_signed(),
    .d_ext_srcw(),
    .d_cc(),
    .d_bit_imm(),
    .d_bit_op(),
    .d_conv_cdq(),
    .d_sm(),
    .d_st(),
    .d_str_loadsi(),
    .d_str_storedi(),
    .d_str_scandi(),
    .d_ct(),
    .d_ret_imm(),
    .d_cld(),
    .d_std(),
    .d_clc(),
    .d_stc(),
    .d_cmc(),
    .d_cli(),
    .d_sti(),
    .d_cnt16(),
    .d_br16(),
    .d_io(),
    .d_io_write(),
    .d_io_imm(),
    .d_io_port_imm(),
    .d_io_w(),
    .d_seg(),
    .d_sysop(d_sysop),
    .d_sys_sreg(),
    .d_sys_creg(d_sys_creg),
    .d_clts(),
    .d_smsw(d_smsw),
    .d_ljmp_off(),
    .d_ljmp_sel(),
    .d_seg_load(),
    .d_lseg(),
    .d_push_sreg(),
    .d_pop_sreg(),
    .d_seg_load_lo(),
    .d_store_sreg(),
    .d_xlat(),
    .d_callf_mem(),
    .d_jmpf_mem(),
    .d_pfx_seg_en(),
    .d_pfx_seg_idx(),
    .d_fxop(),
    .d_is_x87(d_is_x87),
    .d_f_mem_read(),
    .d_f_mem_write(),
    .d_f_msize(),
    .d_f_mbytes(),
    .d_f_pop(),
    .d_f_pop2(),
    .d_f_sti(),
    .d_f_aluop(),
    .d_f_const()
  );

  task automatic clear_bytes();
    for (int i=0;i<16;i++) ibuf[i]=8'ha5;
    ibuf_valid=0;
    seg_real=0;
    def16=0;
  endtask

  task automatic prefixes(input int count);
    for (int i=0;i<count;i++) ibuf[i]=8'h2e;
  endtask

  task automatic check_meta(
      input string label,
      input int need, len, modrm, ready, overlong, fault_len,
      input int header, x87_header, cpl0_header);
    #1;
    checks++;
    if (d_fetch_need!==5'(need) ||
        (len>=0 && d_fetch_len!==5'(len)) ||
        d_fetch_modrm!==1'(modrm) ||
        d_fetch_meta_ready!==1'(ready) ||
        d_fetch_overlong!==1'(overlong) ||
        d_fetch_fault_len!==5'(fault_len) ||
        d_fetch_header_ready!==1'(header) ||
        d_fetch_header_x87!==1'(x87_header) ||
        d_fetch_header_cpl0!==1'(cpl0_header))
      $fatal(1,"%s valid=%0d need=%0d len=%0d modrm=%0d meta=%0d over=%0d fault=%0d header=%0d x87=%0d cpl0=%0d",
             label,ibuf_valid,d_fetch_need,d_fetch_len,d_fetch_modrm,
             d_fetch_meta_ready,d_fetch_overlong,d_fetch_fault_len,
             d_fetch_header_ready,d_fetch_header_x87,d_fetch_header_cpl0);
    if (len>=0 && d_len!==((len<=15)?4'(len):4'd0))
      $fatal(1,"%s legal ABI length=%0d wide=%0d",label,d_len,d_fetch_len);
  endtask

  function automatic logic [63:0] metadata_signature();
    return {21'd0,d_len,d_fetch_need,d_fetch_len,d_fetch_fault_len,
            d_fetch_modrm,d_fetch_meta_ready,d_fetch_overlong,
            d_fetch_header_ready,d_fetch_header_x87,d_fetch_header_cpl0,
            d_is_x87,d_unknown,d_smsw,d_sysop,d_w,d_writes_reg,d_sys_creg,d_dst_reg};
  endfunction

  task automatic check_suffix_independence(input string label);
    logic [63:0] expected;
    #1;
    expected=metadata_signature();
    for (int pattern=0;pattern<8;pattern++) begin
      for (int i=0;i<16;i++)
        if (i>=int'(ibuf_valid))
          case (pattern)
            0: ibuf[i]=8'h00;
            1: ibuf[i]=8'hff;
            2: ibuf[i]=8'h2e;
            3: ibuf[i]=8'h0f;
            4: ibuf[i]=8'hd8;
            5: ibuf[i]=8'h20;
            6: ibuf[i]=8'h67;
            default: ibuf[i]=8'(i*37+19);
          endcase
      #1;
      checks++;
      if (metadata_signature()!==expected)
        $fatal(1,"%s unrequested suffix changed fetch metadata pattern=%0d",label,pattern);
    end
  endtask

  task automatic check_smsw(input string label, input int width, dst);
    #1;
    checks++;
    if (!d_smsw || d_unknown || d_sysop!=SYS_MOVCR_FROM ||
        !d_writes_reg || d_w!==3'(width) || d_dst_reg!==3'(dst) ||
        d_sys_creg!==3'd0 || d_fetch_header_cpl0)
      $fatal(1,"%s SMSW alias/size/class mismatch width=%0d dst=%0d smsw=%0d cpl0=%0d",
             label,d_w,d_dst_reg,d_smsw,d_fetch_header_cpl0);
    check_suffix_independence(label);
  endtask

  task automatic check_group_matrix();
    int group, mod_bits, rm, expected_need;
    bit privileged, recognized, ea_shape, missing_sib;
    string label;
    // Every ModR/M byte, in protected and real/V86 decode modes, with and
    // without the system-mode interface. No new memory LLDT/LTR execution is
    // enabled: their CPL3 classification still precedes the deferred opcode.
    for (int system=0;system<2;system++) begin
      for (int real_seg=0;real_seg<2;real_seg++) begin
        for (int m=0;m<256;m++) begin
          clear_bytes(); sys_mode=1'(system); seg_real=1'(real_seg);
          ibuf[0]=8'h0f; ibuf[1]=8'h00; ibuf[2]=8'(m); ibuf_valid=2;
          label=$sformatf("0F00 system=%0d real=%0d mrm=%02x",system,real_seg,m);
          check_meta({label," missing MRM"},3,-1,1,0,0,16,1,0,0);
          check_suffix_independence({label," missing MRM"});
          ibuf[2]=8'(m); ibuf_valid=3;
          group=(m>>3)&7; mod_bits=m>>6; rm=m&7;
          privileged=(system!=0 && real_seg==0 && (group==2 || group==3));
          recognized=(system!=0 && real_seg==0 &&
                      (group==4 || group==5 || (mod_bits==3 && group<=3)));
          ea_shape=(recognized && mod_bits!=3 && (group==4 || group==5));
          missing_sib=(ea_shape && rm==4);
          expected_need=3;
          if (missing_sib || (ea_shape && mod_bits==1)) expected_need=4;
          else if (ea_shape && (mod_bits==2 || (mod_bits==0 && rm==5))) expected_need=7;
          #1; checks++;
          if (!d_fetch_header_ready || d_fetch_header_cpl0!==privileged ||
              d_fetch_header_x87 || d_smsw || d_unknown!==!recognized ||
              d_fetch_need!==5'(expected_need) ||
              d_fetch_meta_ready!==!missing_sib || d_fetch_overlong)
            $fatal(1,"%s known MRM: cpl0=%0d unknown=%0d need=%0d meta=%0d",
                   label,d_fetch_header_cpl0,d_unknown,d_fetch_need,d_fetch_meta_ready);
          check_suffix_independence({label," known MRM"});
        end
      end
    end
    sys_mode=1;
    // Every 0F01 ModR/M: early CPL0 comes from the known group/mod fields,
    // before any SIB/displacement, not from the provisional SYS_* alias.
    for (int m=0;m<256;m++) begin
      clear_bytes(); ibuf[0]=8'h0f; ibuf[1]=8'h01; ibuf[2]=8'(m); ibuf_valid=2;
      label=$sformatf("0F01 mrm=%02x",m);
      check_meta({label," missing MRM"},3,-1,1,0,0,16,1,0,0);
      check_suffix_independence({label," missing MRM"});
      ibuf[2]=8'(m); ibuf_valid=3;
      group=(m>>3)&7; mod_bits=m>>6; rm=m&7;
      privileged=(group==6 || (mod_bits!=3 && (group==2 || group==3 || group==7)));
      ea_shape=(mod_bits!=3 && (group==0 || group==1 || group==2 || group==3 || group==7));
      recognized=(ea_shape || (mod_bits==3 && group==4));
      missing_sib=(ea_shape && rm==4);
      expected_need=3;
      if (missing_sib || (ea_shape && mod_bits==1)) expected_need=4;
      else if (ea_shape && (mod_bits==2 || (mod_bits==0 && rm==5))) expected_need=7;
      #1; checks++;
      if (!d_fetch_header_ready || d_fetch_header_cpl0!==privileged ||
          d_fetch_header_x87 || d_smsw!==(mod_bits==3 && group==4) ||
          d_unknown!==!recognized || d_fetch_need!==5'(expected_need) ||
          d_fetch_meta_ready!==!missing_sib || d_fetch_overlong)
        $fatal(1,"%s known MRM: cpl0=%0d unknown=%0d smsw=%0d need=%0d meta=%0d",
               label,d_fetch_header_cpl0,d_unknown,d_smsw,d_fetch_need,d_fetch_meta_ready);
      if (mod_bits==3 && (group==2 || group==3) &&
          (d_sysop!=SYS_NONE || d_fetch_len!=5'd3))
        $fatal(1,"%s invalid register LGDT/LIDT consumed an EA or sysop",label);
      check_suffix_independence({label," known MRM"});
    end
  endtask

  initial begin
    eflags=32'h2;
    sys_mode=1;
    smm_active=0;
    paging_on=1;
    cosim_en=0;
    soc_en=0;
    for (int i=0;i<NUM_GPR;i++) gpr[i]=0;

    clear_bytes(); ibuf[0]=8'hd8;
    check_meta("empty ignores stale x87",1,-1,1,0,0,16,0,0,0);
    check_suffix_independence("empty");
    clear_bytes(); ibuf[0]=8'h2e; ibuf[1]=8'hd8; ibuf_valid=1;
    check_meta("prefix only",2,-1,1,0,0,16,0,0,0);
    check_suffix_independence("prefix only");

    // Header classes must not depend on an absent or unsupported ModR/M.
    for (int op=32'hd8;op<=32'hdf;op++) begin
      clear_bytes(); ibuf[0]=8'(op); ibuf_valid=1;
      check_meta("x87 missing ModRM",2,2,1,0,0,16,1,1,0);
      check_suffix_independence("x87 missing ModRM");
    end
    clear_bytes(); ibuf[0]=8'hd9; ibuf[1]=8'hd1; ibuf_valid=2;
    check_meta("unsupported x87 keeps raw escape",2,2,1,1,0,16,1,1,0);
    if (!d_unknown || d_is_x87)
      $fatal(1,"unsupported semantic x87 case did not exercise raw/semantic distinction");
    checks++;

    clear_bytes(); ibuf[0]=8'h0f; ibuf[1]=8'h20; ibuf_valid=1;
    check_meta("0F missing second opcode",2,-1,1,0,0,16,0,0,0);
    check_suffix_independence("0F missing second opcode");
    for (int op=32'h20;op<=32'h23;op++) begin
      clear_bytes(); ibuf[0]=8'h0f; ibuf[1]=8'(op); ibuf_valid=2;
      check_meta("CR/DR header missing ModRM",3,-1,1,0,0,16,1,0,1);
      check_suffix_independence("CR/DR missing ModRM");
    end
    clear_bytes(); ibuf[0]=8'h0f; ibuf[1]=8'h31; ibuf_valid=2;
    check_meta("RDTSC is not CR/DR header",2,2,0,1,0,16,1,0,0);
    clear_bytes(); ibuf[0]=8'h20; ibuf_valid=1;
    check_meta("one-byte AND is not CR/DR",2,2,1,0,0,16,1,0,0);

    clear_bytes(); prefixes(14); ibuf[14]=8'hd8; ibuf_valid=14;
    check_meta("x87 opcode15 absent",15,-1,1,0,0,16,0,0,0);
    check_suffix_independence("x87 opcode15 absent");
    ibuf[14]=8'hd8; ibuf_valid=15;
    check_meta("x87 opcode15 authorized",16,16,1,0,0,16,1,1,0);
    check_suffix_independence("x87 opcode15 ready");
    ibuf_valid=16;
    check_meta("x87 ModRM16 does not hide ready header",16,16,1,1,1,16,1,1,0);

    clear_bytes(); prefixes(13); ibuf[13]=8'h0f; ibuf[14]=8'h20; ibuf_valid=14;
    check_meta("CR opcode15 absent",15,-1,1,0,0,16,0,0,0);
    check_suffix_independence("CR opcode15 absent");
    ibuf[14]=8'h20; ibuf_valid=15;
    check_meta("CR opcode15 authorized",16,-1,1,0,0,16,1,0,1);
    check_suffix_independence("CR opcode15 ready");
    ibuf_valid=16;
    check_meta("CR ModRM16 retains header",16,-1,1,1,1,16,1,0,1);

    clear_bytes(); prefixes(15); ibuf[15]=8'hd8; ibuf_valid=15;
    check_meta("opcode16 absent",16,-1,1,0,0,16,0,0,0);
    check_suffix_independence("opcode16 absent");
    ibuf[15]=8'hd8; ibuf_valid=16;
    check_meta("opcode16 is not early x87 header",16,-1,1,1,1,16,0,0,0);
    clear_bytes(); prefixes(14); ibuf[14]=8'h0f; ibuf[15]=8'h20; ibuf_valid=15;
    check_meta("second opcode16 absent",16,-1,1,0,0,16,0,0,0);
    ibuf_valid=16;
    check_meta("second opcode16 not early CR header",16,-1,1,1,1,16,0,0,0);
    clear_bytes(); prefixes(15); ibuf[15]=8'h2e; ibuf_valid=16;
    check_meta("sixteen prefixes",16,-1,0,1,1,16,0,0,0);

    // Same-arm body lengths and first atomic-overrun endpoints must be unchanged.
    clear_bytes(); ibuf[0]=8'he8; ibuf_valid=1;
    check_meta("CALL needs exact five-byte body",5,5,0,1,0,16,1,0,0);
    check_suffix_independence("CALL immediate suffix");
    ibuf_valid=5;
    check_meta("CALL body authorized",5,5,0,1,0,16,1,0,0);
    clear_bytes(); ibuf[0]=8'h90; ibuf_valid=1;
    check_meta("NOP exact one byte",1,1,0,1,0,16,1,0,0);
    check_suffix_independence("NOP unused suffix");

    clear_bytes(); ibuf[0]=8'h8b; ibuf_valid=1;
    check_meta("MOV missing ModRM",2,2,1,0,0,16,1,0,0);
    check_suffix_independence("MOV missing ModRM");
    ibuf[1]=8'h04; ibuf_valid=2;
    check_meta("MOV missing SIB",3,3,1,0,0,16,1,0,0);
    check_suffix_independence("MOV missing SIB");
    ibuf[2]=8'h25; ibuf_valid=3;
    check_meta("SIB base5 requires disp32",7,7,1,1,0,16,1,0,0);
    check_suffix_independence("MOV displacement suffix");

    clear_bytes(); ibuf[0]=8'hf7; ibuf[1]=8'h04; ibuf_valid=2;
    check_meta("group3 TEST missing SIB",3,7,1,0,0,16,1,0,0);
    ibuf[2]=8'h25; ibuf_valid=3;
    check_meta("group3 TEST disp32 plus imm32",11,11,1,1,0,16,1,0,0);
    check_suffix_independence("group3 immediate suffix");
    ibuf[1]=8'h14;
    check_meta("group3 NOT has no immediate",7,7,1,1,0,16,1,0,0);

    clear_bytes(); prefixes(12); ibuf[12]=8'hb8; ibuf_valid=13;
    check_meta("B8 atomic immediate endpoint17 before byte16",16,17,0,1,0,17,1,0,0);
    check_suffix_independence("B8 overrun suffix");
    ibuf_valid=16;
    check_meta("B8 atomic immediate endpoint17",16,17,0,1,1,17,1,0,0);
    clear_bytes(); prefixes(12); ibuf[12]=8'hc7; ibuf[13]=8'h05; ibuf_valid=14;
    check_meta("C7 first displacement endpoint18",16,22,1,1,0,18,1,0,0);
    check_suffix_independence("C7 displacement suffix");
    ibuf_valid=16;
    check_meta("C7 displacement first not later immediate22",16,22,1,1,1,18,1,0,0);
    clear_bytes(); prefixes(13); ibuf[13]=8'hc8; ibuf_valid=16;
    check_meta("ENTER alloc16 before level8",16,17,0,1,1,16,1,0,0);
    clear_bytes(); prefixes(12); ibuf[12]=8'h9a; ibuf_valid=16;
    check_meta("far CALL offset before selector",16,19,0,1,1,17,1,0,0);
    clear_bytes(); prefixes(12); ibuf[12]=8'hea; ibuf_valid=16;
    check_meta("far JMP offset before selector",16,19,0,1,1,17,1,0,0);

    clear_bytes(); ibuf[0]=8'h0f; ibuf[1]=8'h02; ibuf_valid=2; seg_real=1;
    check_meta("real-mode LAR rejects before ModRM",2,2,0,1,0,16,1,0,0);
    seg_real=0;
    check_meta("protected-mode LAR requires ModRM",3,-1,1,0,0,16,1,0,0);

    check_group_matrix();

    // The opcode header itself is ready before a group can be classified.
    // A known ModR/M at byte15 may cause pre-EA #GP, but one at byte16 must
    // instead retain the overlength/#PF ordering.
    clear_bytes(); prefixes(12); ibuf[12]=8'h0f; ibuf[13]=8'h01;
    ibuf[14]=8'h14; ibuf_valid=14;
    check_meta("LGDT MRM15 absent",15,-1,1,0,0,16,1,0,0);
    check_suffix_independence("LGDT MRM15 absent");
    ibuf[14]=8'h14; ibuf_valid=15;
    check_meta("LGDT MRM15 ready before SIB16",16,16,1,0,0,16,1,0,1);
    check_suffix_independence("LGDT SIB16 unrequested");
    ibuf_valid=16;
    check_meta("LGDT known MRM15 remains privileged",16,-1,1,1,1,16,1,0,1);
    clear_bytes(); prefixes(13); ibuf[13]=8'h0f; ibuf[14]=8'h01;
    ibuf[15]=8'h14; ibuf_valid=15;
    check_meta("LGDT MRM16 absent",16,-1,1,0,0,16,1,0,0);
    check_suffix_independence("LGDT MRM16 absent");
    ibuf[15]=8'h14; ibuf_valid=16;
    check_meta("LGDT MRM16 cannot select early privilege",16,-1,1,1,1,16,1,0,0);

    clear_bytes(); prefixes(12); ibuf[12]=8'h0f; ibuf[13]=8'h00;
    ibuf[14]=8'h14; ibuf_valid=15;
    check_meta("LLDT MRM15 selects privilege without SIB",15,14,1,1,0,16,1,0,1);
    seg_real=1;
    check_meta("real-mode LLDT MRM15 selects UD not privilege",15,14,1,1,0,16,1,0,0);
    clear_bytes(); prefixes(13); ibuf[13]=8'h0f; ibuf[14]=8'h00;
    ibuf[15]=8'hd0; ibuf_valid=16;
    check_meta("LLDT register MRM16 cannot select privilege",16,16,1,1,1,16,1,0,0);

    clear_bytes(); ibuf[0]=8'h0f; ibuf[1]=8'h01; ibuf[2]=8'he3; ibuf_valid=3;
    check_meta("SMSW default32 metadata",3,3,1,1,0,16,1,0,0);
    check_smsw("SMSW default32",4,3);
    clear_bytes(); ibuf[0]=8'h66; ibuf[1]=8'h0f; ibuf[2]=8'h01; ibuf[3]=8'he2; ibuf_valid=4;
    check_meta("SMSW prefix66 metadata",4,4,1,1,0,16,1,0,0);
    check_smsw("SMSW prefix66",2,2);
    clear_bytes(); def16=1; ibuf[0]=8'h0f; ibuf[1]=8'h01; ibuf[2]=8'he1; ibuf_valid=3;
    check_smsw("SMSW default16",2,1);
    clear_bytes(); def16=1; ibuf[0]=8'h66; ibuf[1]=8'h0f; ibuf[2]=8'h01; ibuf[3]=8'he0; ibuf_valid=4;
    check_smsw("SMSW default16 prefix66",4,0);
    clear_bytes(); ibuf[0]=8'h66; ibuf[1]=8'h66; ibuf[2]=8'h0f; ibuf[3]=8'h01; ibuf[4]=8'he7; ibuf_valid=5;
    check_smsw("SMSW duplicate66 presence",2,7);
    clear_bytes(); ibuf[0]=8'h0f; ibuf[1]=8'h20; ibuf[2]=8'hc0; ibuf_valid=3;
    check_meta("MOV CR stays privileged",3,3,1,1,0,16,1,0,1);
    if (d_smsw) $fatal(1,"MOV CR must not claim SMSW identity");
    checks++;

    clear_bytes(); ibuf[0]=8'hd8; ibuf_valid=17;
    check_meta("invalid valid-count fails closed",16,-1,1,0,0,16,0,0,0);
    check_suffix_independence("invalid valid-count");

    $display("FETCHMETA-GATE-OK checks=%0d",checks);
    $finish;
  end
endmodule
