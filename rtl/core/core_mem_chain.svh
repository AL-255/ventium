// Registered resident-read lookahead. Included at module scope in core.sv.
// No architectural PC is advanced here: mc_pc_q is an unissued candidate,
// and becomes the ordinary admitted memory owner only at mc_accept.
// This read-only lookahead consumes pipe_pair_lookahead (the pre-store-sideband
// pairing decision). A U store cannot prime the next read, so feeding the
// store pair's final AXI acknowledgment back into this query would only close
// a combinational L1-ready -> pair-ack -> lookahead -> L1-ready loop.
`ifdef VEN_PIPE_MEM_CHAIN
`ifndef VEN_UOPCACHE
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "VEN_PIPE_MEM_CHAIN requires VEN_UOPCACHE");
`endif
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
`ifdef VEN_P54_LOAD_STORE_PAIR
  logic mc_query_pair_load_store_ok;
`endif
`ifdef VEN_P54_REGMEM_PRIME
  logic mc_query_pair_regmem_ok;
`endif
  logic [7:0] mc_older_writes;
  fpd_t mc_query_u, mc_query_v;

`include "core_raw_held_prime.svh"
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "raw branch prime requires cache-only raw priming");
`endif
`ifndef VEN_IC_BRAM
  initial $fatal(1, "raw branch prime requires returned I-cache byte ownership");
`endif
`include "core_raw_branch_mov.svh"
`endif


`ifdef VEN_RAW_V_READ_PRIME
`ifdef VEN_UOPCACHE
  initial $fatal(1, "raw V read prime must use the ordinary raw decoders");
`endif
`ifndef VEN_PIPE_REG_LOAD_PRIME
  initial $fatal(1, "raw V read prime requires the resident prime port");
`endif
`ifdef VEN_PIPE_BRANCH_LOAD_PRIME
  initial $fatal(1, "raw V read prime does not decode branch successors");
`endif
  function automatic fpd_t mc_descriptor(input logic [31:0] pc);
    logic [31:0] lin;
    fpd_t d;
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
    fpd_t branch_d;
    logic [4:0] off;
`endif
    begin
      lin = seg_base[SG_CS] + pc;
      d = '0;
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
      branch_d = '0;
      off = {1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len};
      // Consume at most three bytes of the ALREADY RETURNED frontend span.
      // No third full decoder, extra cache read port, fetch, or saved uop.
      // The first/last ownership checks include physical way and collision.
      if (mc_prime_v_branch && off <= 5'd13 &&
          pc == eip + {27'd0,off} && lin[31:12] == flin[31:12]) begin
        branch_d = mc_raw_branch_mov(ic_front_bytes[off],
            ic_front_bytes[off+5'd1], ic_front_bytes[off+5'd2]);
        if (branch_d.len != 0 &&
            ({1'b0,lin[4:0]} + {2'd0,branch_d.len} <= 6'd32) &&
            ({1'b0,pc} + {29'd0,branch_d.len} - 33'd1 <=
                {1'b0,seg_limit[SG_CS]}) &&
`ifdef VEN_IC_RESIDENCY_SPAN
            // The outer guard proves pc=eip+off, off<=13. Thus lin=flin+off
            // modulo 2^32, and off+len<=28 even for an arbitrary 4-bit len.
            // Reuse the already returned frontend identities; neither a
            // present tag alone nor equal bytes establish buffer ownership.
            ic_res_buffered_offset({1'b0,off}) &&
            ic_res_buffered_end({1'b0,off}+{2'b0,branch_d.len}))
`else
            ic_buffered(lin) && ic_buffered(lin+{28'd0,branch_d.len}-32'd1))
`endif
          d = branch_d;
      end
`endif
      // The admitted current x87 descriptor already owns complete checked
      // frontend bytes. Only a full-in-line form can prime this cache window.
      if (mc_fp_self_prime && pc == eip &&
          ({1'b0, lin[4:0]} + {2'd0, pipe_u_eff.len} <= 6'd32) &&
          ({1'b0, pc} + {29'd0, pipe_u_eff.len} - 33'd1 <=
              {1'b0, seg_limit[SG_CS]})) d = pipe_u_eff;
      // Never retain a raw descriptor through an active memory owner. Only
      // the currently checked V bytes may lend their already decoded packet.
      if (!mc_fp_self_prime && !pipe_mem_active_q && !mc_valid_q && !pipe_pair_lookahead &&
          v_bytes_ok && pc == eip + {28'd0, u_d.len} &&
          lin[31:12] == flin[31:12] && v_d.len != 0 &&
          ({1'b0, lin[4:0]} + {2'd0, v_d.len} <= 6'd32) &&
          ({1'b0, pc} + {29'd0, v_d.len} - 33'd1 <=
              {1'b0, seg_limit[SG_CS]})) d = v_d;
      // A held U lends only its originally checked unpaired V descriptor.
      // The ordinary next-U path still performs translation and execution.
      if (mc_held_read_prime && pc == pipe_mem_eip_q + {28'd0, pipe_mem_u_q.len})
        d = pipe_mem_v_q;
      return d;
    end
  endfunction
`else
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

`endif

  logic mc_fp_self_prime;
`ifdef VEN_FP_RESIDENT_PRIME
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "FP resident prime requires cache-only raw priming");
`endif
`ifndef VEN_FP_MEM_ADMIT
  initial $fatal(1, "FP resident prime requires checked FP memory admission");
`endif
  // Select a cache-only query without consuming ACK-dependent admission.
  // The actual checked admission gates COMMIT, never the lookup address.
  // No integer memory owner or third decoded instruction is involved.
  // Only one-beat arithmetic can consume the shortened admission without
  // replacing its saved load clock with another execution/stack wait. Do not
  // perturb FLD/FILD scheduling or spend the hint on two-beat operands.
  assign mc_fp_self_prime = pipe_u_eff.is_fp && pipe_u_eff.fp_kind == FK_MEM &&
                           pipe_u_eff.fp_role == 3'd0 && !pipe_u_eff.fp_sti[0] &&
                           !pipe_u_eff.fp_aluop[1] &&
                           !mc_valid_q && !pipe_mem_active_q;
`else
  assign mc_fp_self_prime = 1'b0;
`endif

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
      pipe_pair_lookahead && pipe_v_eff.is_branch && pipe_v_eff.br_cond &&
      !pipe_v_eff.w16;
  assign mc_prime_branch = mc_prime_u_branch || mc_prime_v_branch;
`elsif VEN_RAW_BRANCH_FALLTHROUGH_PRIME
  // Only predicted FALLTHROUGH, with the actual outcome checked at COMMIT.
  // Never let an ALU/flags result select a query address: it can consume L1
  // response data. OFFER is a resident-only lookup, not a speculative read.
  assign mc_prime_u_branch = !mc_valid_q && !pipe_mem_active_q &&
      !pipe_pair_lookahead && !u_pred_taken && pipe_u_eff.simple &&
      pipe_u_eff.is_branch && pipe_u_eff.br_cond && !pipe_u_eff.w16;
  assign mc_prime_v_branch = !mc_valid_q && !pipe_mem_active_q &&
      pipe_u_eff.simple && !pipe_u_eff.is_mem && !pipe_u_eff.is_store &&
      !pipe_u_eff.is_stack && !pipe_u_eff.is_fp && !pipe_u_eff.is_branch &&
      pipe_pair_lookahead && !v_pred_taken && pipe_v_eff.simple &&
      pipe_v_eff.is_branch && pipe_v_eff.br_cond && !pipe_v_eff.w16;
  assign mc_prime_branch = mc_prime_u_branch || mc_prime_v_branch;
`else
  assign mc_prime_u_branch = 1'b0;
  assign mc_prime_v_branch = 1'b0;
  assign mc_prime_branch = 1'b0;
`endif
  assign mc_query_pc = mc_fp_self_prime ? eip : mc_valid_q
      ? mc_pc_q + {28'd0, mc_u_q.len} + (mc_pair_q ? {28'd0, mc_v_q.len} : 32'd0)
      : (mc_prime_u_branch && u_pred_taken) ? u_target
      : (mc_prime_v_branch && v_pred_taken) ? v_target
      : pipe_commit_eip + {28'd0, pipe_u_eff.len}
          + (pipe_pair_lookahead ? {28'd0, pipe_v_eff.len} : 32'd0);
  assign mc_query_u = mc_descriptor(mc_query_pc);
  assign mc_query_vpc = mc_query_pc + {28'd0, mc_query_u.len};
  assign mc_query_v = mc_fp_self_prime ? '0 : mc_descriptor(mc_query_vpc);
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
`ifdef VEN_P54_LOAD_STORE_PAIR
                      , .pair_load_store_ok(mc_query_pair_load_store_ok)
`endif
`ifdef VEN_PERF_PROFILE
                      , .pair_reason()
`endif
                     );
  assign mc_query_pair = mc_query_pair_ok && mc_query_v.simple &&
      !mc_query_v.is_mem && !mc_query_v.is_stack && !mc_query_v.is_fp &&
      !mc_query_v.is_branch && !mc_query_v.w16 && (mc_query_v.len != 0);
  `include "core_ref_operand_prime.svh"
  `include "core_agi_resident_prime.svh"

  // Prepare only the address fields before the descriptor's late byte,
  // code-span and segment validation. mc_query_u remains the checked owner:
  // its nonzero length and memory kind still gate every ordinary prime offer.
  // Held, FP-self and paired-branch sources are mutually exclusive by their
  // existing admission equations; the ordinary unpaired V is the default.
  fpd_t mc_address_payload;
`ifdef VEN_RAW_V_READ_PRIME
  always_comb begin
    mc_address_payload = v_d;
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
    // A live V branch cannot itself be a memory/FP descriptor. If it
    // does not pair, its query cannot offer a memory access. Prepare the
    // third-slot address from this early shape; the original checked
    // mc_prime_v_branch still gates descriptor validity and every offer.
    if (v_d.is_branch) begin
      mc_address_payload = '0;
      if ({1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len} <= 5'd13)
        mc_address_payload = mc_raw_branch_mov(
            ic_front_bytes[{1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len}],
            ic_front_bytes[{1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len} + 5'd1],
            ic_front_bytes[{1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len} + 5'd2]);
    end
`endif
    if (mc_fp_self_prime) mc_address_payload = pipe_u_eff;
    if (mc_held_read_prime) mc_address_payload = pipe_mem_v_q;
  end
`else
  assign mc_address_payload = mc_query_u;
`endif
  assign mc_query_seg = agi_prime_select ? pipe_mem_seg : ref_prime_select ? d_seg : mc_address_payload.mem_ss ? 3'(SG_SS) : 3'(SG_DS);
  assign mc_query_ea = agi_prime_select ? pipe_load_addr : ref_prime_select ? d_ea : (mc_address_payload.mem_base_en ? gpr_o[mc_address_payload.base] : 32'd0)
      + mc_address_payload.mem_disp
      + (mc_address_payload.mem_index_en ?
          (gpr_o[mc_address_payload.mem_index] << mc_address_payload.mem_scale) : 32'd0);

`ifndef SYNTHESIS
`ifdef VEN_RAW_V_READ_PRIME
  always_ff @(posedge clk) if (rst_n && !agi_prime_select && !ref_prime_select &&
                              mc_query_u.len != 0 && (mc_query_u.is_mem || mc_query_u.is_fp)) begin
    assert ({mc_query_u.mem_ss, mc_query_u.mem_base_en, mc_query_u.base,
             mc_query_u.mem_disp, mc_query_u.mem_index_en,
             mc_query_u.mem_index, mc_query_u.mem_scale} ==
            {mc_address_payload.mem_ss, mc_address_payload.mem_base_en, mc_address_payload.base,
             mc_address_payload.mem_disp, mc_address_payload.mem_index_en,
             mc_address_payload.mem_index, mc_address_payload.mem_scale})
      else $fatal(1, "raw prime address payload disagrees with checked descriptor");
  end
  // Required decoder invariant, checked independently of whether a hint
  // is accepted. Held and FP-self payloads retain their overriding priority.
  always_ff @(posedge clk) if (rst_n && v_d.is_branch)
    assert (!v_d.is_mem && !v_d.is_fp)
      else $fatal(1, "branch address shape: branch has memory/FP semantics");
`endif
`endif
  assign mc_query_lin = seg_base[mc_query_seg] + mc_query_ea;
  assign mc_query_phys = paging_on ? mc_lookup_phys : mc_query_lin;
  // The query uses pre-retirement GPRs. Exclude address dependencies on BOTH
  // the oldest owner and the candidate whose successor is being prepared.
  assign mc_older_writes = pipe_u_eff.writes |
      (pipe_pair_lookahead ? pipe_v_eff.writes : 8'd0) |
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
  assign mc_prime_base = mc_fp_self_prime || mc_held_read_prime || mc_fresh_read_prime || (!mc_valid_q && !pipe_mem_active_q &&
      !pipe_new_mem_req && pipe_u_eff.simple && !pipe_u_eff.is_mem &&
      !pipe_u_eff.is_store && !pipe_u_eff.is_stack && !pipe_u_eff.is_fp &&
      (!pipe_u_eff.is_branch || mc_prime_u_branch) &&
      !(pipe_pair_lookahead && (pipe_v_eff.is_mem || pipe_v_eff.is_store ||
                          pipe_v_eff.is_stack || pipe_v_eff.is_fp ||
                          (pipe_v_eff.is_branch && !mc_prime_v_branch))));
`else
  assign mc_prime_base = 1'b0;
`endif
  always_comb begin
    mc_prepare_ok = !agi_prime_select && !ref_prime_select && mc_boundary_ok &&
`ifdef VEN_RAW_V_READ_PRIME
        // Cache-window warmup only; never retain/execute the hint descriptor.
        mc_prime_base &&
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
        (!pipe_pair_lookahead || mc_prime_v_branch) &&
`else
        !pipe_pair_lookahead &&
`endif
`endif
        !fp_is_ext_load(pipe_u_eff) && !fp_is_ext_load(mc_query_u) &&
        (pipe_mem_active_q || pipe_new_load_req || mc_prime_base) &&
        !pipe_u_eff.is_store &&
        (!pipe_u_eff.is_branch || mc_prime_u_branch) &&
        !(pipe_pair_lookahead && pipe_v_eff.is_branch && !mc_prime_v_branch) &&
        ((mc_fp_self_prime && mc_query_u.is_fp && mc_query_u.fp_kind == FK_MEM) ||
         (mc_query_u.simple && mc_query_u.is_mem && !mc_query_u.is_fp)) &&
        !mc_query_u.is_store && !mc_query_u.is_stack && !mc_query_u.is_branch &&
        !mc_query_u.w16 && (mc_query_u.len != 0) &&
        ((mc_query_u.addr_mask & mc_older_writes) == 8'd0) &&
        ({1'b0, mc_query_ea} + ((mc_fp_self_prime && mc_query_u.fp_sti[0]) ?
            33'd7 : (mc_query_u.w8 ? 33'd0 : 33'd3))
             <= {1'b0, seg_limit[mc_query_seg]}) &&
        // Use the physical line extent, not the segment-relative low bits.
        (mc_query_u.w8 || (mc_query_lin[4:0] <=
            ((mc_fp_self_prime && mc_query_u.fp_sti[0]) ? 5'd24 : 5'd28))) &&
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
                         + (pipe_pair_lookahead ? {28'd0, pipe_v_eff.len} : 32'd0));
  assign mc_prime_offer = mc_prime_base && mc_prepare_ok;
  assign mem_next_req = agi_prime_offer || ref_prime_offer || mc_offer || mc_prime_offer;
// Diagnostic only: observe the unmodified request equation in the RAW profile.
// No internal forcing, arbitration changes, new synthesis flag or performance claim.
`ifndef SYNTHESIS
`ifdef VEN_RAW_V_READ_PRIME
`ifdef VEN_P54_LOAD_STORE_PAIR
  longint unsigned np_clocks, np_agi, np_ref, np_retained, np_prime;
  longint unsigned np_intent, np_request, np_accept, np_shape_only;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      np_clocks <= 0; np_agi <= 0; np_ref <= 0; np_retained <= 0;
      np_prime <= 0; np_intent <= 0; np_request <= 0;
      np_accept <= 0; np_shape_only <= 0;
    end else begin
      np_clocks <= np_clocks + 1;
      if (agi_prime_offer) np_agi <= np_agi + 1;
      if (ref_prime_offer) np_ref <= np_ref + 1;
      if (mc_offer) np_retained <= np_retained + 1;
      if (mc_prime_offer) np_prime <= np_prime + 1;
      if (pipe_load_req && pipe_store_pair_shape) np_intent <= np_intent + 1;
      if (pipe_load_req && mem_store_pair_req) np_request <= np_request + 1;
      if (pipe_load_req && pipe_store_pair_accept) np_accept <= np_accept + 1;
      if (pipe_store_pair_shape && mem_next_req) begin
        np_shape_only <= np_shape_only + 1;
        if (np_shape_only == 0)
          $display("NEXT-PAIR-SHAPE pc=%h load=%b agi=%b ref=%b retained=%b prime=%b",
                   eip, pipe_load_req, agi_prime_offer, ref_prime_offer, mc_offer, mc_prime_offer);
        if ($test$plusargs("next_pair_reject_shape"))
          $fatal(1,"NEXT-PAIR-BROAD: shape-only exclusion loses a real hint");
      end
      assert (!mc_valid_q)
        else $fatal(1,"NEXT-PAIR-RETAINED: RAW profile retained a next-read owner");
      assert (!(pipe_load_req && pipe_store_pair_shape && mem_next_req))
        else $fatal(1,"NEXT-PAIR-OVERLAP pc=%h agi=%b ref=%b retained=%b prime=%b held=%b",
                    eip, agi_prime_offer, ref_prime_offer, mc_offer, mc_prime_offer, mc_held_read_prime);
    end
  end
  final $display("NEXT-PAIR-PROBE clocks=%0d agi=%0d ref=%0d retained=%0d prime=%0d intent=%0d request=%0d accept=%0d shape_only=%0d",
                 np_clocks,np_agi,np_ref,np_retained,np_prime,np_intent,np_request,np_accept,np_shape_only);
`endif
`endif
`endif
  // Read-only hint commit: avoid the unrelated backing-store ACK mux.
  // No architectural retirement, actual ACK, cache owner or cycle changes.
  logic mc_readonly_int_commit;
  assign mc_readonly_int_commit = (state == S_PIPE) && fsm_case_enabled &&
                           !fp_issue_block && !pipe_store_req && (!pipe_load_req || mem_read_ack) &&
                           (pipe_mem_active_q ||
                            (!pipe_mem_active_q && exec_issue_ok && pipe_frontend_ready &&
                             (stall_cnt == 7'd0) && (pending_mem_pen == 7'd0)
`ifdef VEN_FP_PIPE
                             && !fp_pipe_rd_haz
`endif
                             && !pipe_u_eff.is_fp && !fp_sys_bail &&
                             (mispred_bubbles == 3'd0) && !pipe_agi));
  // AGI/reference-only hints never create a pipeline successor owner.
  // mc_offer has mc_valid_q; their selectors require !mc_valid_q.
  // mc_prime_offer requires !agi_prime_select && !ref_prime_select.
  // Preserve the public OR below, but do not feed unrelated hint completion
  // (including live own-store snoop recovery) back into pipeline owner bits.
  // A V-branch prime requires a register-only U instruction. Prepare
  // its flags from the already lane-selected GPR operands, without importing
  // the unrelated memory-response mux into next-read capture qualification.
  // The execution ALU and actual branch/retirement consumers stay unchanged.
  // Only flags are observable from this copy; no second shifter is connected.
  logic [31:0] mc_reg_u_flags, mc_reg_branch_flags;
  logic mc_reg_v_br_taken;
  u_pipe u_mc_reg_branch_flags (
    .u_d(pipe_u_eff), .u_dst_val(u_dst_reg_val), .u_src_val(u_src_reg_val),
    .eflags(eflags), .u_alu(), .u_flags(mc_reg_u_flags),
    .u_sh(), .u_shm1(), .u_shcf(), .u_shcnt()
  );
  always_comb begin
    mc_reg_branch_flags = pipe_u_eff.wflags ? mc_reg_u_flags : eflags;
    if (pipe_u_eff.is_shift)
      mc_reg_branch_flags = fast_shift_flags(pipe_u_eff.shrot, pipe_u_eff.shimm,
          u_sh, u_shm1, u_shcf, eflags, fp_operand_width(pipe_u_eff));
    mc_reg_v_br_taken = pipe_v_eff.br_cond
                     ? cond_true(pipe_v_eff.cc, mc_reg_branch_flags) : 1'b1;
  end

  logic mc_pipeline_commit;
  assign mc_pipeline_commit = ((mc_offer ||
      (mc_prime_offer && (!mc_prime_branch ||
          (mc_prime_u_branch ? (pipe_u_eff.br_taken == u_pred_taken)
                             : (mc_reg_v_br_taken == v_pred_taken))))) &&
      (mc_readonly_int_commit || (mc_fp_self_prime && fp_shared_mem_admit)));
`ifndef SYNTHESIS
  logic mc_pipeline_commit_before_reg_flags;
  assign mc_pipeline_commit_before_reg_flags = ((mc_offer ||
      (mc_prime_offer && (!mc_prime_branch ||
          (mc_prime_u_branch ? (pipe_u_eff.br_taken == u_pred_taken)
                             : (v_br_taken_eff == v_pred_taken))))) &&
      (mc_readonly_int_commit || (mc_fp_self_prime && fp_shared_mem_admit)));

  longint unsigned mc_reg_prime_offers, mc_reg_prime_commits, mc_reg_prime_rejects;
  longint unsigned mc_reg_prime_alu, mc_reg_prime_shift, mc_reg_prime_preserve;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mc_reg_prime_offers <= 0; mc_reg_prime_commits <= 0; mc_reg_prime_rejects <= 0;
      mc_reg_prime_alu <= 0; mc_reg_prime_shift <= 0; mc_reg_prime_preserve <= 0;
    end else begin
      assert (mc_pipeline_commit === mc_pipeline_commit_before_reg_flags)
        else $fatal(1,"PRIME-REG-FLAGS: complete pipeline hint commit changed");
      if (mc_prime_v_branch)
        assert (mc_reg_v_br_taken === v_br_taken_eff)
          else $fatal(1,"PRIME-REG-FLAGS: non-memory branch outcome changed");
      if (mc_prime_offer && mc_prime_v_branch && mc_readonly_int_commit) begin
        mc_reg_prime_offers <= mc_reg_prime_offers + 1;
        if (mc_pipeline_commit) mc_reg_prime_commits <= mc_reg_prime_commits + 1;
        else mc_reg_prime_rejects <= mc_reg_prime_rejects + 1;
        if (pipe_u_eff.is_shift) mc_reg_prime_shift <= mc_reg_prime_shift + 1;
        else if (pipe_u_eff.wflags) mc_reg_prime_alu <= mc_reg_prime_alu + 1;
        else mc_reg_prime_preserve <= mc_reg_prime_preserve + 1;
      end
    end
  end
  final $display("PRIME-REG-FLAGS offers=%0d commits=%0d rejects=%0d alu=%0d shift=%0d preserve=%0d",
      mc_reg_prime_offers,mc_reg_prime_commits,mc_reg_prime_rejects,
      mc_reg_prime_alu,mc_reg_prime_shift,mc_reg_prime_preserve);
`endif
  assign mem_next_commit = agi_prime_commit || ref_prime_commit || mc_pipeline_commit;
`ifndef SYNTHESIS
  logic mc_commit_before_read_cut;
  assign mc_commit_before_read_cut = agi_prime_commit || ref_prime_commit || ((mc_offer ||
      (mc_prime_offer && (!mc_prime_branch ||
          (mc_prime_u_branch ? (pipe_u_eff.br_taken == u_pred_taken)
                             : (v_br_taken_eff == v_pred_taken))))) &&
      (pipe_int_commit || (mc_fp_self_prime && fp_shared_mem_admit)));

  always_ff @(posedge clk) if (rst_n)
    assert (mem_next_commit === mc_commit_before_read_cut)
      else $fatal(1,"MC-READ-COMMIT: hint commit changed");
`endif
  // OFFER still owns admission. Retained versus live payload selection
  // depends only on the registered owner: every live prime excludes it,
  // and every retained offer requires it. AGI/reference selectors keep
  // their original priority. Do not put late permission/branch/decode
  // qualification before the downstream address-region comparison.
  assign mem_next_addr = (agi_prime_select || ref_prime_select || !mc_valid_q) ? mc_query_phys : mc_phys_q;
`ifndef SYNTHESIS
  logic [31:0] prime_payload_old_addr;
  logic [3:0] prime_payload_old_strb;
  assign prime_payload_old_addr = (agi_prime_select || ref_prime_select || mc_prime_offer) ? mc_query_phys : mc_phys_q;
  assign prime_payload_old_strb = agi_prime_select ? ((agi_prime_width == 3'd1) ? 4'h1 : 4'hf) :
      ref_prime_select ? ref_prime_strb :
      (mc_prime_offer ? mc_query_u.w8 : mc_u_q.w8)
      ? 4'b0001 : 4'b1111;
  always_ff @(posedge clk) if (rst_n) begin
    assert (!mem_next_commit || mem_next_req)
      else $fatal(1, "PRIME-PAYLOAD: commit without request");
    if (mem_next_req) begin
      assert ({mem_next_addr,mem_next_wstrb} ===
              {prime_payload_old_addr,prime_payload_old_strb})
        else $fatal(1, "PRIME-PAYLOAD: offered address/width changed");
      assert (!mc_prime_offer || !mc_valid_q)
        else $fatal(1, "PRIME-PAYLOAD: live prime collided with retained owner");
    end
  end
`endif
  assign mem_next_wstrb = agi_prime_select ? ((agi_prime_width == 3'd1) ? 4'h1 : 4'hf) :
      ref_prime_select ? ref_prime_strb :
      (!mc_valid_q ? mc_query_u.w8 : mc_u_q.w8)
      ? 4'b0001 : 4'b1111;
  assign mc_chain_accept = mc_offer && mc_pipeline_commit && mem_next_ready;
`ifndef SYNTHESIS
  logic mc_chain_accept_before_local_commit;
  assign mc_chain_accept_before_local_commit = mc_offer && mem_next_commit && mem_next_ready;

  always_ff @(posedge clk) if (rst_n)
    assert (mc_chain_accept === mc_chain_accept_before_local_commit)
      else $fatal(1,"MC-LOCAL-COMMIT: mc_chain_accept");
`endif
  assign mc_prime_accept = mc_prime_offer && mc_pipeline_commit && mem_next_ready;
`ifndef SYNTHESIS
  logic mc_prime_accept_before_local_commit;
  assign mc_prime_accept_before_local_commit = mc_prime_offer && mem_next_commit && mem_next_ready;

  always_ff @(posedge clk) if (rst_n)
    assert (mc_prime_accept === mc_prime_accept_before_local_commit)
      else $fatal(1,"MC-LOCAL-COMMIT: mc_prime_accept");
`endif
  // Preserve mc_accept's existing meaning for the TLB owner and profilers.
  assign mc_accept = mc_chain_accept;
  assign mc_any_accept = mc_chain_accept || mc_prime_accept;

`ifdef VEN_RAW_V_READ_PRIME
  // RAW hints warm a cache window only. The unchanged preparation equation
  // implies mc_prime_base; retained capture requires !mc_prime_base. All ten
  // registers therefore stay at reset zero. Make that invariant structural
  // instead of retaining a nonexistent successor and its commit/AGU muxes.
  // Live AGI, reference, ordinary/held-V, branch and FP hints are unchanged.
  assign mc_valid_q = '0;
  assign mc_pair_q = '0;
  assign mc_dirty_q = '0;
  assign mc_pc_q = '0;
  assign mc_ea_q = '0;
  assign mc_lin_q = '0;
  assign mc_phys_q = '0;
  assign mc_seg_q = '0;
  assign mc_u_q = '0;
  assign mc_v_q = '0;
`ifndef SYNTHESIS
  // Execute the original state machine in simulation: a future change that
  // admits retained storage in RAW mode must fail, not silently lose an owner.
  logic raw_storage_ref_mc_valid_q, raw_storage_ref_mc_pair_q, raw_storage_ref_mc_dirty_q;
  logic [31:0] raw_storage_ref_mc_pc_q, raw_storage_ref_mc_ea_q;
  logic [31:0] raw_storage_ref_mc_lin_q, raw_storage_ref_mc_phys_q;
  logic [2:0] raw_storage_ref_mc_seg_q;
  fpd_t raw_storage_ref_mc_u_q, raw_storage_ref_mc_v_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      raw_storage_ref_mc_valid_q <= 1'b0; raw_storage_ref_mc_pair_q <= 1'b0; raw_storage_ref_mc_dirty_q <= 1'b0;
      raw_storage_ref_mc_pc_q <= 0; raw_storage_ref_mc_ea_q <= 0; raw_storage_ref_mc_lin_q <= 0; raw_storage_ref_mc_phys_q <= 0;
      raw_storage_ref_mc_seg_q <= 0; raw_storage_ref_mc_u_q <= '0; raw_storage_ref_mc_v_q <= '0;
    end else begin
      // Raw TLB flush/fill contain mem_ack in their task-switch/walk cones.
      // Keep them out of combinational offer/ACK feedback. They can occur
      // only outside S_PIPE (already blocked above); clear the lookahead on
      // their actual edge as well. exec_flush_all carries registered flush
      // into the first subsequent executable boundary.
      if (!mc_boundary_ok || tlb_flush || tlb_fill_en || pipe_mem_abort_now ||
          mc_prime_accept ||
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
          pipe_v_pair_now_accept ||
`endif
          (pipe_int_commit && !mc_any_accept))
        raw_storage_ref_mc_valid_q <= 1'b0;
      else if (!raw_storage_ref_mc_valid_q || mc_any_accept) begin
        // A stand-alone query is offered only on the current register packet;
        // never retain it as if it were the successor of an active read.  A
        // rejected hit probe must not poison the following load's chain slot.
        raw_storage_ref_mc_valid_q <= mc_prepare_ok && !mc_prime_base;
        if (mc_prepare_ok && !mc_prime_base) begin
          raw_storage_ref_mc_pc_q <= mc_query_pc; raw_storage_ref_mc_ea_q <= mc_query_ea;
          raw_storage_ref_mc_lin_q <= mc_query_lin; raw_storage_ref_mc_phys_q <= mc_query_phys;
          raw_storage_ref_mc_seg_q <= mc_query_seg; raw_storage_ref_mc_dirty_q <= mc_lookup_dirty;
          raw_storage_ref_mc_u_q <= mc_query_u; raw_storage_ref_mc_v_q <= mc_query_v; raw_storage_ref_mc_pair_q <= mc_query_pair;
        end
      end
    end
  end
  always_ff @(posedge clk) if (rst_n)
    assert ({raw_storage_ref_mc_valid_q, raw_storage_ref_mc_pair_q, raw_storage_ref_mc_dirty_q, raw_storage_ref_mc_pc_q, raw_storage_ref_mc_ea_q, raw_storage_ref_mc_lin_q, raw_storage_ref_mc_phys_q, raw_storage_ref_mc_seg_q, raw_storage_ref_mc_u_q, raw_storage_ref_mc_v_q} === '0)
      else $fatal(1,"RAW-PRIME-STORAGE: retained owner/payload became reachable");
`endif
`else
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
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
          pipe_v_pair_now_accept ||
`endif
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
`endif

`ifndef SYNTHESIS
`ifdef VEN_RAW_V_READ_PRIME
  always_ff @(posedge clk) if (rst_n && mc_prime_accept) begin
    assert (!mc_valid_q && !mc_chain_accept && (!pipe_mem_active_q || mc_held_read_prime) &&
            (!pipe_pair_lookahead || mc_prime_v_branch) && mc_query_v.len == 0 &&
            mc_query_pc == (mc_fp_self_prime ? eip : pipe_commit_eip +
                {28'd0,pipe_u_eff.len} + (mc_prime_v_branch ? {28'd0,pipe_v_eff.len} : 32'd0)) &&
            !(mc_query_u.addr_mask & mc_older_writes))
      else $fatal(1, "raw V read prime descriptor/address ownership");
    if (mc_fp_self_prime) begin
      assert (fp_shared_mem_admit && mc_query_u.is_fp && mc_query_u.fp_kind == FK_MEM &&
              !pipe_int_commit && !pipe_new_mem_req && !mc_query_u.is_mem)
        else $fatal(1, "FP resident prime is not cache-only admission");
      if (ven_fetchdbg_en)
        $display("[FETCHDBG:FPPRIME] eip=%08x addr=%08x wide=%0d",
                 eip, mc_query_phys, mc_query_u.fp_sti[0]);
    end else if (mc_prime_branch && ven_fetchdbg_en)
      $display("[FETCHDBG:RAWBRANCHPRIME] eip=%08x next=%08x addr=%08x v=%0d",
               eip, mc_query_pc, mc_query_phys, mc_prime_v_branch);
    else if ((mc_held_read_prime || mc_fresh_read_prime) && ven_fetchdbg_en)
      $display("[FETCHDBG:HELDPRIME] eip=%08x next=%08x addr=%08x",
               pipe_commit_eip, mc_query_pc, mc_query_phys);
    else if (ven_fetchdbg_en)
      $display("[FETCHDBG:RAWPRIME] eip=%08x next=%08x addr=%08x",
               eip, mc_query_pc, mc_query_phys);
  end
`endif
  always_ff @(posedge clk) if (rst_n && mc_chain_accept) begin
    assert (pipe_int_commit && pipe_mem_active_q && !pipe_mem_we_q &&
            !fx_act && !exec_flush_all && !tlb_flush && !tlb_fill_en &&
            !smi_take && !nmi_take && !intr_take && !irq_shadow)
      else $fatal(1, "memory-chain ownership/event violation");
    assert (mc_pc_q == pipe_commit_eip + {28'd0, pipe_u_eff.len}
                         + (pipe_pair_lookahead ? {28'd0, pipe_v_eff.len} : 32'd0))
      else $fatal(1, "memory-chain nonsequential owner");
  end
`ifdef VEN_PIPE_REG_LOAD_PRIME
  always_ff @(posedge clk) if (rst_n && mc_prime_accept) begin
    assert ((pipe_int_commit || (mc_fp_self_prime && fp_shared_mem_admit)) &&
            (mc_held_read_prime || mc_fresh_read_prime || (!pipe_mem_active_q && !pipe_new_mem_req)) &&
            !fx_act && !exec_flush_all && !tlb_flush && !tlb_fill_en &&
            !smi_take && !nmi_take && !intr_take && !irq_shadow)
      else $fatal(1, "register-load prime ownership/event violation");
    assert ((mc_fp_self_prime && mc_query_pc == eip) || mc_prime_branch ||
            mc_query_pc == pipe_commit_eip + {28'd0, pipe_u_eff.len}
                         + (pipe_pair_lookahead ? {28'd0, pipe_v_eff.len} : 32'd0))
      else $fatal(1, "register-load prime nonsequential owner");
    if (mc_prime_branch)
      assert ((mc_prime_u_branch && pipe_u_eff.is_branch &&
               (pipe_u_eff.br_taken == u_pred_taken) &&
               mc_query_pc == (u_pred_taken ? u_target :
                   pipe_commit_eip + {28'd0, pipe_u_eff.len} +
                   (pipe_pair_lookahead ? {28'd0, pipe_v_eff.len} : 32'd0))) ||
              (mc_prime_v_branch && pipe_pair_lookahead && pipe_v_eff.is_branch &&
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

`ifdef VEN_RAW_HELD_READ_PRIME
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "held read prime requires raw V read prime");
`endif
`ifndef VEN_PIPE_MEM_CHAIN
  initial $fatal(1, "held read prime requires the registered next-read port");
`endif
`endif
