// Registered resident-read lookahead. Included at module scope in core.sv.
// No architectural PC is advanced here: mc_pc_q is an unissued candidate,
// and becomes the ordinary admitted memory owner only at mc_accept.
// This read-only lookahead consumes pipe_pair_base (the pre-store-sideband
// pairing decision). A U store cannot prime the next read, so feeding the
// store pair's final AXI acknowledgment back into this query would only close
// a combinational L1-ready -> pair-ack -> lookahead -> L1-ready loop.
`ifdef VEN_PIPE_MEM_CHAIN
`ifndef VEN_UOPCACHE
  initial $fatal(1, "VEN_PIPE_MEM_CHAIN requires VEN_UOPCACHE");
`endif
`ifndef VEN_L1_AXI
  initial $fatal(1, "VEN_PIPE_MEM_CHAIN requires VEN_L1_AXI");
`endif
  logic mc_valid_q, mc_pair_q, mc_dirty_q;
  logic [31:0] mc_pc_q, mc_ea_q, mc_lin_q, mc_phys_q;
  logic [2:0] mc_seg_q;
  fpd_t mc_u_q, mc_v_q;
  logic mc_accept, mc_any_accept, mc_offer, mc_chain_accept, mc_prime_offer;
  logic mc_prime_accept, mc_prime_base, mc_boundary_ok, mc_prepare_ok;
  logic mc_prime_branch, mc_prime_u_branch, mc_prime_v_branch;
  logic [31:0] mc_query_pc, mc_query_vpc, mc_query_ea, mc_query_lin;
  logic [31:0] mc_query_phys, mc_lookup_phys;
  logic [2:0] mc_query_seg, mc_lookup_perm;
  logic mc_lookup_hit, mc_lookup_dirty, mc_query_pair, mc_query_pair_ok;
`ifdef VEN_P54_DUAL_LOAD_PRIME
  logic mc_query_pair_mem_ok;
`endif
`ifdef VEN_P54_REGMEM_PRIME
  logic mc_query_pair_regmem_ok;
`endif
  logic [7:0] mc_older_writes;
  fpd_t mc_query_u, mc_query_v;

  // Read the *existing returned* uop windows, with the same physical-source
  // identity checks as ordinary U/V. A sparse boundary, third code line,
  // collided BRAM return or absent tag is a rejection, never another fetch.
  function automatic fpd_t mc_descriptor(input logic [31:0] pc);
    logic [31:0] lin;
    logic [IC_IDXW-1:0] set;
    logic [IC_WAYW-1:0] way;
    logic in_a, in_b, valid;
    logic [3:0] slot;
    fpd_t d;
    begin
      lin = seg_base[SG_CS] + pc;
      set = lin[5 +: IC_IDXW]; way = ic_hit_way(lin);
      in_a = rdA_set_q == set && rdA_way_q == way && !ic_rd_collA;
      in_b = rdB_set_q == set && rdB_way_q == way && !ic_rd_collB;
      // Stay in the current checked code page. A prefetched descriptor in
      // another virtual page alone is not a fresh execute-permission proof.
      valid = (lin[31:12] == flin[31:12]) && ic_present(lin) &&
              ((in_a && uc_pdvA && uc_bvA[lin[4:0]]) ||
               (!in_a && in_b && uc_pdvB && uc_bvB[lin[4:0]]));
      slot = in_a ? uc_bsA[lin[4:0]] : uc_bsB[lin[4:0]];
      d = '0;
      if (valid) begin
        if (slot[3])
          d = in_a ? uc_tailA[slot[UC_TAIL_IDXW-1:0]]
                   : uc_tailB[slot[UC_TAIL_IDXW-1:0]];
        else
          d = in_a ? uc_baseA[slot[2:0]] : uc_baseB[slot[2:0]];
      end
      // A resident first byte is not proof of an instruction's complete span.
      // This first implementation uses complete-in-line descriptors only.
      if ((d.len == 0) || ({1'b0, lin[4:0]} + {2'd0, d.len} > 6'd32) ||
          ({1'b0, pc} + {29'd0, d.len} - 33'd1 > {1'b0, seg_limit[SG_CS]}))
        d = '0;
      return d;
    end
  endfunction

  // While a candidate is waiting, prepare its successor independently of
  // response data. On consume+replace its AGU/translation result is registered
  // for the following cycle. No response-data -> AGU -> cache-array path.
`ifdef VEN_PIPE_BRANCH_LOAD_PRIME
`ifndef VEN_PIPE_REG_LOAD_PRIME
  initial $fatal(1, "VEN_PIPE_BRANCH_LOAD_PRIME requires VEN_PIPE_REG_LOAD_PRIME");
`endif
  // A predicted U or paired V conditional branch may lend its commit edge to
  // a checked resident load on its predicted successor. Speculative TAG lookup
  // does not capture data or mutate cache state. The actual branch decision
  // gates c_next_commit below: a misprediction creates no new owner. Keeping
  // the speculative address independent of U's ALU result is essential: the
  // ordinary ALU input mux also reads mem_rdata, and a result-driven address
  // would close a real query -> L1 data -> U flags -> query comb cycle.
  assign mc_prime_u_branch = !mc_valid_q && !pipe_mem_active_q &&
      pipe_u_eff.simple && pipe_u_eff.is_branch && pipe_u_eff.br_cond &&
      !pipe_u_eff.w16;
  assign mc_prime_v_branch = !mc_valid_q && !pipe_mem_active_q &&
      pipe_u_eff.simple && !pipe_u_eff.is_mem && !pipe_u_eff.is_store &&
      !pipe_u_eff.is_stack && !pipe_u_eff.is_fp && !pipe_u_eff.is_branch &&
      pipe_pair_base && pipe_v_eff.is_branch && pipe_v_eff.br_cond &&
      !pipe_v_eff.w16;
  assign mc_prime_branch = mc_prime_u_branch || mc_prime_v_branch;
`else
  assign mc_prime_u_branch = 1'b0;
  assign mc_prime_v_branch = 1'b0;
  assign mc_prime_branch = 1'b0;
`endif
  assign mc_query_pc = mc_valid_q
      ? mc_pc_q + {28'd0, mc_u_q.len} + (mc_pair_q ? {28'd0, mc_v_q.len} : 32'd0)
      : (mc_prime_u_branch && u_pred_taken) ? u_target
      : (mc_prime_v_branch && v_pred_taken) ? v_target
      : pipe_commit_eip + {28'd0, pipe_u_eff.len}
          + (pipe_pair_base ? {28'd0, pipe_v_eff.len} : 32'd0);
  assign mc_query_u = mc_descriptor(mc_query_pc);
  assign mc_query_vpc = mc_query_pc + {28'd0, mc_query_u.len};
  assign mc_query_v = mc_descriptor(mc_query_vpc);
  issue_uv u_mc_issue (.iu(mc_query_u), .iv(mc_query_v), .pair_ok(mc_query_pair_ok)
`ifdef VEN_P54_DUAL_LOAD_PAIR
`ifdef VEN_P54_DUAL_LOAD_PRIME
                      , .pair_mem_ok(mc_query_pair_mem_ok)
`else
                      , .pair_mem_ok()
`endif
`endif
`ifdef VEN_P54_REGMEM_PRIME
                      , .pair_regmem_ok(mc_query_pair_regmem_ok)
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
                      , .pair_store_ok()
`endif
`ifdef VEN_PERF_PROFILE
                      , .pair_reason()
`endif
                     );
  assign mc_query_pair = mc_query_pair_ok && mc_query_v.simple &&
      !mc_query_v.is_mem && !mc_query_v.is_stack && !mc_query_v.is_fp &&
      !mc_query_v.is_branch && !mc_query_v.w16 && (mc_query_v.len != 0);
  assign mc_query_seg = mc_query_u.mem_ss ? 3'(SG_SS) : 3'(SG_DS);
  assign mc_query_ea = (mc_query_u.mem_base_en ? gpr_o[mc_query_u.base] : 32'd0)
      + mc_query_u.mem_disp
      + (mc_query_u.mem_index_en ?
          (gpr_o[mc_query_u.mem_index] << mc_query_u.mem_scale) : 32'd0);
  assign mc_query_lin = seg_base[mc_query_seg] + mc_query_ea;
  assign mc_query_phys = paging_on ? mc_lookup_phys : mc_query_lin;
  // The query uses pre-retirement GPRs. Exclude address dependencies on BOTH
  // the oldest owner and the candidate whose successor is being prepared.
  assign mc_older_writes = pipe_u_eff.writes |
      (pipe_pair_base ? pipe_v_eff.writes : 8'd0) |
      (mc_valid_q ? (mc_u_q.writes | (mc_pair_q ? mc_v_q.writes : 8'd0)) : 8'd0);

  // Raw pending events, not fp_irq_divert (which is masked by active owner),
  // force a normal empty-owner boundary. This prevents an infinite hit stream
  // from starving interrupts. Likewise host debug's raw issue block matters.
  assign mc_boundary_ok = cycle_mode && real_bus && (state == S_PIPE) &&
      !def16 && a20_on && !irq_shadow && !fp_dbg_active &&
      (pending_mem_pen == 0) && (stall_cnt == 0) && (mispred_bubbles == 0) &&
      // real_bus retirement does not create modeled misalignment debt.
      // Candidate extent checks below still forbid a split-line request.
      !dbg_step_active && !fp_issue_block && !smi_take && !nmi_take && !intr_take &&
      // Port 2 may carry this same clock's paired V store. A store already
      // excludes read lookahead below, and feeding its acceptance back here
      // would close ready -> store -> snoop -> ready.
      !exec_flush_all && !ic_snoop_valid && !ic_snoop_valid1 &&
      !fx_act && !fx_abort_q && !bus_err
`ifdef VEN_DBG_CORE
      && !dbg_block_issue && !dbg_bp_en
`endif
      ;
`ifdef VEN_PIPE_REG_LOAD_PRIME
  // A committed, side-effect-free integer packet (or a predicted taken branch
  // with an outcome-checked commit) can lend its otherwise idle D-cache lookup
  // slot to the next checked resident load. This is never a
  // backing transaction: MMIO, TLB misses and dependent addresses fall back
  // to ordinary admission on the following clock.
  assign mc_prime_base = !mc_valid_q && !pipe_mem_active_q &&
      !pipe_new_mem_req && pipe_u_eff.simple && !pipe_u_eff.is_mem &&
      !pipe_u_eff.is_store && !pipe_u_eff.is_stack && !pipe_u_eff.is_fp &&
      (!pipe_u_eff.is_branch || mc_prime_u_branch) &&
      !(pipe_pair_base && (pipe_v_eff.is_mem || pipe_v_eff.is_store ||
                          pipe_v_eff.is_stack || pipe_v_eff.is_fp ||
                          (pipe_v_eff.is_branch && !mc_prime_v_branch)));
`else
  assign mc_prime_base = 1'b0;
`endif
  always_comb begin
    mc_prepare_ok = mc_boundary_ok &&
        !fp_is_ext_load(pipe_u_eff) && !fp_is_ext_load(mc_query_u) &&
        (pipe_mem_active_q || pipe_new_load_req || mc_prime_base) &&
        !pipe_u_eff.is_store &&
        (!pipe_u_eff.is_branch || mc_prime_u_branch) &&
        !(pipe_pair_base && pipe_v_eff.is_branch && !mc_prime_v_branch) &&
        mc_query_u.simple && mc_query_u.is_mem && !mc_query_u.is_store &&
        !mc_query_u.is_stack && !mc_query_u.is_fp && !mc_query_u.is_branch &&
        !mc_query_u.w16 && (mc_query_u.len != 0) &&
        ((mc_query_u.addr_mask & mc_older_writes) == 8'd0) &&
        ({1'b0, mc_query_ea} + (mc_query_u.w8 ? 33'd0 : 33'd3)
             <= {1'b0, seg_limit[mc_query_seg]}) &&
        // Use the physical line extent, not the segment-relative low bits.
        (mc_query_u.w8 || (mc_query_lin[4:0] <= 5'd28)) &&
        (!paging_on || (mc_lookup_hit && mc_lookup_perm[0] &&
                        ((eff_cpl != 2'd3) || mc_lookup_perm[2])));
    if (sys_mode) begin
`ifdef VEN_SYS_FASTLOAD_FLAT
      mc_prepare_ok = mc_prepare_ok && sys_fp_ok && !real_mode && cs_d &&
          seg_pm_loaded[mc_query_seg] && (seg_sel[mc_query_seg][15:2] != 14'd0) &&
          seg_attr[mc_query_seg][7] && seg_attr[mc_query_seg][4] &&
          !seg_attr[mc_query_seg][3] && seg_attr[mc_query_seg][1] &&
          !seg_attr[mc_query_seg][2] &&
          ((seg_limit[mc_query_seg] == 32'hffff_ffff)
`ifdef VEN_SYS_FASTLOAD_BOUNDED
           || ((mc_query_seg == 3'(SG_DS)) &&
               (mc_query_ea[31:12] < seg_limit[mc_query_seg][31:12]) &&
               (mc_query_u.w8 || mc_query_ea[11:0] <= 12'hffc))
`endif
          );
`else
      mc_prepare_ok = 1'b0;
`endif
    end
  end

  // OFFER is independent of old ACK. COMMIT alone authorizes replacement.
  // The leaf can reject a miss/MMIO/flush without starting backing traffic.
  assign mc_offer = mc_valid_q && mc_boundary_ok && pipe_mem_active_q &&
      !fp_is_ext_load(pipe_u_eff) && !fp_is_ext_load(mc_u_q) &&
      !pipe_mem_we_q && (mc_pc_q == pipe_commit_eip + {28'd0, pipe_u_eff.len}
                         + (pipe_pair_base ? {28'd0, pipe_v_eff.len} : 32'd0));
  assign mc_prime_offer = mc_prime_base && mc_prepare_ok;
  assign mem_next_req = mc_offer || mc_prime_offer;
  assign mem_next_commit = (mc_offer ||
      (mc_prime_offer && (!mc_prime_branch ||
          (mc_prime_u_branch ? (pipe_u_eff.br_taken == u_pred_taken)
                             : (v_br_taken_eff == v_pred_taken))))) &&
      pipe_int_commit;
  assign mem_next_addr = mc_prime_offer ? mc_query_phys : mc_phys_q;
  assign mem_next_wstrb = (mc_prime_offer ? mc_query_u.w8 : mc_u_q.w8)
      ? 4'b0001 : 4'b1111;
  assign mc_chain_accept = mc_offer && mem_next_commit && mem_next_ready;
  assign mc_prime_accept = mc_prime_offer && mem_next_commit && mem_next_ready;
  // Preserve mc_accept's existing meaning for the TLB owner and profilers.
  assign mc_accept = mc_chain_accept;
  assign mc_any_accept = mc_chain_accept || mc_prime_accept;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mc_valid_q <= 1'b0; mc_pair_q <= 1'b0; mc_dirty_q <= 1'b0;
      mc_pc_q <= 0; mc_ea_q <= 0; mc_lin_q <= 0; mc_phys_q <= 0;
      mc_seg_q <= 0; mc_u_q <= '0; mc_v_q <= '0;
    end else begin
      // Raw TLB flush/fill contain mem_ack in their task-switch/walk cones.
      // Keep them out of combinational offer/ACK feedback. They can occur
      // only outside S_PIPE (already blocked above); clear the lookahead on
      // their actual edge as well. exec_flush_all carries registered flush
      // into the first subsequent executable boundary.
      if (!mc_boundary_ok || tlb_flush || tlb_fill_en || pipe_mem_abort_now ||
          mc_prime_accept ||
          (pipe_int_commit && !mc_any_accept))
        mc_valid_q <= 1'b0;
      else if (!mc_valid_q || mc_any_accept) begin
        // A stand-alone query is offered only on the current register packet;
        // never retain it as if it were the successor of an active read.  A
        // rejected hit probe must not poison the following load's chain slot.
        mc_valid_q <= mc_prepare_ok && !mc_prime_base;
        if (mc_prepare_ok && !mc_prime_base) begin
          mc_pc_q <= mc_query_pc; mc_ea_q <= mc_query_ea;
          mc_lin_q <= mc_query_lin; mc_phys_q <= mc_query_phys;
          mc_seg_q <= mc_query_seg; mc_dirty_q <= mc_lookup_dirty;
          mc_u_q <= mc_query_u; mc_v_q <= mc_query_v; mc_pair_q <= mc_query_pair;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && mc_chain_accept) begin
    assert (pipe_int_commit && pipe_mem_active_q && !pipe_mem_we_q &&
            !fx_act && !exec_flush_all && !tlb_flush && !tlb_fill_en &&
            !smi_take && !nmi_take && !intr_take && !irq_shadow)
      else $fatal(1, "memory-chain ownership/event violation");
    assert (mc_pc_q == pipe_commit_eip + {28'd0, pipe_u_eff.len}
                         + (pipe_pair_base ? {28'd0, pipe_v_eff.len} : 32'd0))
      else $fatal(1, "memory-chain nonsequential owner");
  end
`ifdef VEN_PIPE_REG_LOAD_PRIME
  always_ff @(posedge clk) if (rst_n && mc_prime_accept) begin
    assert (pipe_int_commit && !pipe_mem_active_q && !pipe_new_mem_req &&
            !fx_act && !exec_flush_all && !tlb_flush && !tlb_fill_en &&
            !smi_take && !nmi_take && !intr_take && !irq_shadow)
      else $fatal(1, "register-load prime ownership/event violation");
    assert (mc_prime_branch ||
            mc_query_pc == pipe_commit_eip + {28'd0, pipe_u_eff.len}
                         + (pipe_pair_base ? {28'd0, pipe_v_eff.len} : 32'd0))
      else $fatal(1, "register-load prime nonsequential owner");
    if (mc_prime_branch)
      assert ((mc_prime_u_branch && pipe_u_eff.is_branch &&
               (pipe_u_eff.br_taken == u_pred_taken) &&
               mc_query_pc == (u_pred_taken ? u_target :
                   pipe_commit_eip + {28'd0, pipe_u_eff.len} +
                   (pipe_pair_base ? {28'd0, pipe_v_eff.len} : 32'd0))) ||
              (mc_prime_v_branch && pipe_pair_base && pipe_v_eff.is_branch &&
               (v_br_taken_eff == v_pred_taken) &&
               mc_query_pc == (v_pred_taken ? v_target :
                   pipe_commit_eip + {28'd0, pipe_u_eff.len} +
                   {28'd0, pipe_v_eff.len})))
        else $fatal(1, "branch-successor load prime lost predicted owner");
  end
`endif
`endif
`endif
`ifdef VEN_PIPE_REG_LOAD_PRIME
`ifndef VEN_PIPE_MEM_CHAIN
  initial $fatal(1, "VEN_PIPE_REG_LOAD_PRIME requires VEN_PIPE_MEM_CHAIN");
`endif
`endif
