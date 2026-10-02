// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The DUT RHS expressions are extracted from core.sv, not copied here.
module tb_fetchguard;
  timeunit 1ns;
  timeprecision 1ps;
  localparam int SG_CS = 1;
  typedef enum logic [2:0] { S_FETCH, S_DECODE, S_PIPE, S_WALK, S_OTHER } state_e;
  typedef struct packed { logic [3:0] len; } length_s;
  state_e state;
  length_s pipe_u_eff;
  logic sys_mode, real_mode, v86, cur_is_d, paging_on;
  logic [7:0] seg_attr [6];
  logic [31:0] seg_base [6], seg_limit [6];
  logic [31:0] eip, cur_lin, flin;
  logic [3:0] d_len, cur_size;
  logic [2:0] fetch_word, sfetch_demand_size;
  logic sfetch_boundary, sfetch_demand_req;
  logic pipe_cs_issue_eligible, pipe_mem_active_q, if_auth_ok;
  logic d_fetch_overlong;
  logic [1:0] sfetch_header_fault_q;
  logic sfetch_early_nm, sfetch_early_gp;
  logic [4:0] d_fetch_fault_len;
  logic dbg_block_issue, smi_pending, smm_active, dbg_step_active;
  logic nmi_take, intr_take;
  logic pipe_fetch_checked_handoff, fetch_overlength_probe;
  logic [31:0] fetch_fault_linear, fetch_fault_page;
  logic cs_fetch_fault, cs_extent_fault;
  int checks;

  `include "production_predicates.svh"

  task automatic expect_bit(input string label_text, input logic actual, expected);
    checks++;
    if (actual !== expected)
      $fatal(1, "FETCHGUARD mismatch: %s actual=%b expected=%b", label_text, actual, expected);
  endtask

  task automatic defaults;
    state = S_FETCH;
    sys_mode = 1;
    real_mode = 0;
    v86 = 0;
    cur_is_d = 0;
    paging_on = 1;
    eip = 32'h100;
    cur_lin = 32'h400100;
    flin = cur_lin;
    d_len = 1;
    cur_size = 1;
    fetch_word = 0;
    sfetch_demand_size = 1;
    sfetch_boundary = 1;
    sfetch_demand_req = 1;
    pipe_cs_issue_eligible = 1;
    pipe_mem_active_q = 0;
    pipe_u_eff.len = 1;
    if_auth_ok = 1;
    d_fetch_overlong = 0;
    sfetch_header_fault_q = 0;
    sfetch_early_nm = 0;
    sfetch_early_gp = 0;
    d_fetch_fault_len = 16;
    dbg_block_issue = 0;
    smi_pending = 0;
    smm_active = 0;
    dbg_step_active = 0;
    nmi_take = 0;
    intr_take = 0;
    for (int i = 0; i < 6; i++) begin
      seg_attr[i] = 8'h80;
      seg_base[i] = 32'h400000;
      seg_limit[i] = 32'hffff;
    end

  endtask

  initial begin : tests
    bit expected;
    logic [32:0] first_byte, last_byte;
    defaults();

    // A legal last byte has been accepted. Completion has no access, even
    // though the cursor points one byte beyond the inclusive CS limit.
    for (int limit_off = 16; limit_off <= 47; limit_off++) begin
      seg_limit[SG_CS] = 32'(limit_off);
      cur_lin = seg_base[SG_CS] + 32'(limit_off + 1);
      eip = 32'(limit_off);
      sfetch_demand_req = 0;
      sfetch_demand_size = 0;
      cur_size = 0;
      #1;
      expect_bit("completion cursor is not another fetch", cs_fetch_fault, 0);
      state = S_DECODE;
      d_len = 1;
      #1;
      expect_bit("legal last-byte decoded extent", cs_extent_fault, 0);
      state = S_FETCH;
    end

    // Essential beats must authorize both their first and inclusive last
    // byte. Base addition can wrap; the checked segment offset cannot.
    for (int base_case = 0; base_case < 3; base_case++) begin
      seg_base[SG_CS] = (base_case == 0) ? 32'h400000 :
                        (base_case == 1) ? 32'hfffffff0 : 32'h7ffffff0;
      for (int limit_off = 16; limit_off <= 31; limit_off++) begin
        seg_limit[SG_CS] = 32'(limit_off);
        for (int delta = -4; delta <= 2; delta++) begin
          for (int size = 1; size <= 4; size++) begin
            sfetch_demand_req = 1;
            sfetch_demand_size = 3'(size);
            cur_size = 4'(size);
            cur_lin = seg_base[SG_CS] + 32'(limit_off + delta);
            first_byte = 33'(limit_off + delta);
            last_byte = first_byte + 33'(size) - 33'd1;
            expected = (first_byte > {1'b0,seg_limit[SG_CS]}) ||
                       (last_byte > {1'b0,seg_limit[SG_CS]});
            #1;
            expect_bit("essential first/last byte extent", cs_fetch_fault, expected);
          end
        end
      end
    end

    defaults();
    seg_base[SG_CS] = 0;
    seg_limit[SG_CS] = 32'hfffffffe;
    cur_lin = 32'hfffffffc;
    sfetch_demand_size = 3;
    #1;
    expect_bit("last byte at top-of-offset-space limit", cs_fetch_fault, 0);
    sfetch_demand_size = 4;
    #1;
    expect_bit("last byte beyond top-of-offset-space limit", cs_fetch_fault, 1);
    seg_limit[SG_CS] = 32'hffffffff;
    cur_lin = 32'hfffffffe;
    #1;
    expect_bit("33-bit essential extent rejects offset wrap", cs_fetch_fault, 1);

    defaults();
    state = S_DECODE;
    eip = 0;
    seg_limit[SG_CS] = 0;
    d_len = 0;
    #1;
    expect_bit("zero overlength d_len is not a wrapped extent", cs_extent_fault, 0);
    for (int len = 1; len <= 15; len++) begin
      d_len = 4'(len);
      eip = 32'hfff0;
      seg_limit[SG_CS] = eip + 32'(len) - 1;
      #1;
      expect_bit("decoded instruction ending at limit", cs_extent_fault, 0);
      seg_limit[SG_CS]--;
      #1;
      expect_bit("decoded instruction one byte past limit", cs_extent_fault, 1);
    end
    state = S_PIPE;
    pipe_u_eff.len = 15;
    eip = 32'hfff0;
    seg_limit[SG_CS] = 32'hfff0;
    pipe_cs_issue_eligible = 0;
    #1;
    expect_bit("unadmitted raw pipeline length is not judged", cs_extent_fault, 0);
    state = S_DECODE;
    d_len = 15;
    for (int fault_kind = 1; fault_kind <= 3; fault_kind++) begin
      sfetch_header_fault_q = 2'(fault_kind);
      #1;
      expect_bit("early header fault is not a decoded extent", cs_extent_fault, 0);
    end
    sfetch_header_fault_q = 0;
    for (int fault_kind = 1; fault_kind <= 3; fault_kind++) begin
      sfetch_early_nm = 1'(fault_kind >> 0);
      sfetch_early_gp = 1'(fault_kind >> 1);
      #1;
      expect_bit("live interior header fault is not a decoded extent", cs_extent_fault, 0);
    end

    // Enumerate the actual boundary-event acceptance conditions, including
    // pending-but-masked SMI and debugger single stepping.
    defaults();
    state = S_DECODE;
    flin = 32'h401ff0;
    d_fetch_fault_len = 17;
    d_fetch_overlong = 1;
    for (int mask = 0; mask < 64; mask++) begin
      dbg_block_issue = 1'(mask >> 0);
      smi_pending = 1'(mask >> 1);
      smm_active = 1'(mask >> 2);
      dbg_step_active = 1'(mask >> 3);
      nmi_take = 1'(mask >> 4);
      intr_take = 1'(mask >> 5);
      expected = !dbg_block_issue &&
        !(smi_pending && !smm_active && !dbg_step_active) &&
        !(nmi_take && !dbg_step_active) &&
        !(intr_take && !dbg_step_active);
      #1;
      expect_bit("overlength probe yields to accepted boundary event", fetch_overlength_probe, expected);
      expect_bit("atomic endpoint page is page base", fetch_fault_page == 32'h402000, 1);
    end
    dbg_block_issue = 0;
    smi_pending = 0;
    nmi_take = 0;
    intr_take = 0;
    for (int fault_kind = 1; fault_kind <= 3; fault_kind++) begin
      sfetch_header_fault_q = 2'(fault_kind);
      #1;
      expect_bit("early header fault does not access overlength page", fetch_overlength_probe, 0);
    end
    sfetch_header_fault_q = 0;
    sfetch_boundary = 0;
    for (int fault_kind = 1; fault_kind <= 3; fault_kind++) begin
      sfetch_early_nm = 1'(fault_kind >> 0);
      sfetch_early_gp = 1'(fault_kind >> 1);
      #1;
      expect_bit("live interior header fault does not probe EA page", fetch_overlength_probe, 0);
    end
    defaults();
    state = S_DECODE;
    d_fetch_overlong = 1;
    flin = 32'h401fee;
    d_fetch_fault_len = 18;
    #1;
    expect_bit("mapped first overrun field does not probe later page", fetch_overlength_probe, 0);
    state = S_OTHER;
    flin = 32'h401ff0;
    d_fetch_fault_len = 17;
    #1;
    expect_bit("no probe outside decode owner", fetch_overlength_probe, 0);
    state = S_DECODE;
    paging_on = 0;
    #1;
    expect_bit("paging-disabled instruction does not probe", fetch_overlength_probe, 0);
    paging_on = 1;
    sys_mode = 0;
    #1;
    expect_bit("functional non-system execution does not probe", fetch_overlength_probe, 0);
    sys_mode = 1;
    d_fetch_overlong = 0;
    #1;
    expect_bit("ordinary instruction does not probe", fetch_overlength_probe, 0);

    // A previously admitted held memory packet is not withdrawn by a later
    // boundary classification or code authorization change.
    defaults();
    state = S_PIPE;
    for (int mask = 0; mask < 8; mask++) begin
      pipe_mem_active_q = 1'(mask >> 0);
      sfetch_boundary = 1'(mask >> 1);
      if_auth_ok = 1'(mask >> 2);
      expected = !pipe_mem_active_q && (sfetch_boundary || !if_auth_ok);
      #1;
      expect_bit("held packet handoff exemption", pipe_fetch_checked_handoff, expected);
    end
    $display("FETCHGUARD-LEAF-OK checks=%0d", checks);
    $finish;
  end
endmodule
