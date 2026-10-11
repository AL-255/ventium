  // Source selection is derived from the real prime predicates, not assumed
  // mutually exclusive by the test. Mocked cache ownership is a 32-bit table.
  integer samples=0, live=0, idle_changes=0, accepted[4], seed, discarded;
  function automatic fpd_t random_descriptor;
    return {$urandom,$urandom,$urandom,$urandom,$urandom,$urandom,
            $urandom,$urandom,$urandom,$urandom,$urandom,$urandom};
  endfunction
  initial begin
    seed=32'h19781123; discarded=$urandom(seed);
    for(integer m=0;m<4;m++) accepted[m]=0;
    for(integer n=0;n<65536;n++) begin
      pipe_u_eff=random_descriptor(); pipe_v_eff=random_descriptor();
      v_d=random_descriptor(); pipe_mem_u_q=random_descriptor();
      pipe_mem_v_q=random_descriptor();
      eip=32'h200+32'(n%4096); pipe_mem_eip_q=eip^32'h40;
      mc_valid_q=0; pipe_mem_active_q=0; pipe_pair_lookahead=0;
      u_pred_taken=0; v_pred_taken=0; state=S_PIPE;
      mc_held_v_valid_q=1; pipe_mem_we_q=0; pipe_mem_pair_q=0;
      v_bytes_ok=1;
      pipe_u_eff.is_fp=0;
      pipe_mem_u_q.is_stack=0; pipe_mem_u_q.is_fp=0; pipe_mem_u_q.is_branch=0;
      for(integer k=0;k<6;k++) begin
        seg_base[k]=32'h10fff000+32'(k*4096);
        seg_limit[k]=32'hffffffff;
      end
      for(integer k=0;k<8;k++) gpr_o[k]=($urandom^32'hffffff80);
      for(integer k=0;k<16;k++) ic_front_bytes[k]=8'($urandom);
      returned_mask=32'hffffffff;
      // The four actual producers, including held V and the tiny third-slot
      // branch hint. Vary descriptor payloads even when admission is denied.
      case(n%4)
        0: begin end
        1: begin
          pipe_u_eff.is_fp=1; pipe_u_eff.fp_kind=FK_MEM;
          pipe_u_eff.fp_role=0; pipe_u_eff.fp_sti[0]=0;
          pipe_u_eff.fp_aluop[1]=0;
        end
        2: pipe_mem_active_q=1;
        3: begin
          pipe_pair_lookahead=1;
          pipe_u_eff.simple=1; pipe_u_eff.is_mem=0; pipe_u_eff.is_store=0;
          pipe_u_eff.is_stack=0; pipe_u_eff.is_branch=0;
          pipe_v_eff.simple=1; pipe_v_eff.is_branch=1;
          pipe_v_eff.br_cond=1; pipe_v_eff.w16=0;
          // Exercise every possible 5-bit offset, including out-of-range.
          pipe_u_eff.len=4'((n/4)%16); pipe_v_eff.len=4'((n/64)%16);
          if (({1'b0,pipe_u_eff.len}+{1'b0,pipe_v_eff.len})<=5'd13) begin
            ic_front_bytes[int'(pipe_u_eff.len)+int'(pipe_v_eff.len)]=8'h8b;
            ic_front_bytes[int'(pipe_u_eff.len)+int'(pipe_v_eff.len)+1]=8'h50;
            ic_front_bytes[int'(pipe_u_eff.len)+int'(pipe_v_eff.len)+2]=8'($urandom);
          end
        end
      endcase
      u_d=pipe_u_eff;
      // Target the matching owner PC; periodically request an unrelated PC.
      case(n%4)
        0: mc_query_pc=eip+{28'd0,u_d.len};
        1: mc_query_pc=eip;
        2: mc_query_pc=pipe_mem_eip_q+{28'd0,pipe_mem_u_q.len};
        3: mc_query_pc=eip+{28'd0,pipe_u_eff.len}+{28'd0,pipe_v_eff.len};
      endcase
      // Controls which invalidate the checked descriptor must NOT authorize
      // any different payload. Other groups keep the original valid case.
      case((n/256)%16)
        0:mc_query_pc=mc_query_pc+32'd97;
        1:returned_mask=$urandom;
        2:seg_limit[SG_CS]=eip;
        3:seg_limit[SG_CS]=eip+32'd3;
        4:v_bytes_ok=0;
        5:mc_valid_q=1;
        6:pipe_mem_we_q=1;
        7:pipe_mem_pair_q=1;
        8:mc_held_v_valid_q=0;
        9:state=0;
        10:begin u_pred_taken=1;v_pred_taken=1;end
        default:begin end
      endcase
      agi_prime_select=(n%17)==0; ref_prime_select=(n%13)==0;
      pipe_mem_seg=3'(n%6); d_seg=3'((n+1)%6);
      pipe_load_addr=$urandom; d_ea=$urandom;
      #1;
      mc_query_u=mc_descriptor(mc_query_pc);
      #1;
      if(mc_query_u.len!=0 || agi_prime_select || ref_prime_select) begin
        if(old_ea!==mc_query_ea || old_seg!==mc_query_seg)
          $fatal(1,"MC_ADDRESS_PAYLOAD_MISMATCH sample=%0d mode=%0d desc_len=%0d old=%h/%h new=%h/%h",
                 n,n%4,mc_query_u.len,old_seg,old_ea,mc_query_seg,mc_query_ea);
        live++;
        if(mc_query_u.len!=0 && !agi_prime_select && !ref_prime_select) accepted[n%4]++;
      end else if(old_ea!==mc_query_ea || old_seg!==mc_query_seg) idle_changes++;
      samples++;
    end
    if(samples!=65536 || live==0 || idle_changes==0) $fatal(1,"MC_ADDRESS_PAYLOAD_VACUOUS");
    for(integer m=0;m<4;m++) if(accepted[m]==0) $fatal(1,"MC_ADDRESS_SOURCE_NOT_TESTED mode=%0d",m);
    $display("MC-ADDRESS-PAYLOAD-OK samples=%0d live=%0d idle_changes=%0d normal=%0d fp=%0d held=%0d branch=%0d",
             samples,live,idle_changes,accepted[0],accepted[1],accepted[2],accepted[3]);
    $finish;
  end
