// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Private permission-only shadow, not an instruction/data/translation cache.
// Independent read address is flin; a data operand must not steer authorization.
// Entries contain raw U/S and a linear page, never a cached CPL0 allow result.
// Every parent I-TLB replacement invalidates all entries. Context invalidation
// has the same raw sequential edge as the parent; it never enters the comb
// request/ack/flush dependency. Normal byte ownership and CS checks are intact.
`ifdef VEN_ITLB_ASSOC_4WAY
`ifdef VEN_PIPE_MEM_CHAIN
// With the 32-entry 4-way associative P54C I-TLB, query u_itlb's independent
// flin lookup port directly. An I-TLB miss fill updates only one victim way
// without wiping authorization across the remaining 31 resident code pages,
// and newly walked pages are authorized immediately without an S_FETCH detour.
assign if_auth_ok = !paging_on ||
    (itlb_flin_hit && ((eff_cpl != 2'd3) || itlb_flin_perm[2]));
wire _unused_itlb_flin_perm = &{1'b0, itlb_flin_perm[1:0]};
`else
localparam int IF_AUTH_ENTRIES = 16;
logic [IF_AUTH_ENTRIES-1:0] if_auth_multi_valid;
logic [19:0] if_auth_multi_page [IF_AUTH_ENTRIES];
logic if_auth_multi_user [IF_AUTH_ENTRIES];
wire [3:0] if_auth_query_index = flin[15:12];
wire [3:0] if_auth_capture_index = cur_lin[15:12];

assign if_auth_ok = !paging_on ||
    (if_auth_multi_valid[if_auth_query_index] &&
     if_auth_multi_page[if_auth_query_index] == flin[31:12] &&
     ((eff_cpl != 2'd3) || if_auth_multi_user[if_auth_query_index]));

always_ff @(posedge clk) begin
  if (!rst_n || tlb_flush || (tlb_fill_en && !tlb_fill_is_d)) begin
    if_auth_multi_valid <= '0;
  end else if (paging_on && fe_translatable && !cur_is_d &&
               fsm_case_enabled && itlb_lk_hit &&
               !xlate_miss && !perm_fault && !fe_xlate_pend) begin
    if_auth_multi_valid[if_auth_capture_index] <= 1'b1;
    if_auth_multi_page[if_auth_capture_index] <= cur_lin[31:12];
    if_auth_multi_user[if_auth_capture_index] <= itlb_lk_perm[2];
  end
end
`endif
`else
localparam int IF_AUTH_ENTRIES = 16;
logic [IF_AUTH_ENTRIES-1:0] if_auth_multi_valid;
logic [19:0] if_auth_multi_page [IF_AUTH_ENTRIES];
logic if_auth_multi_user [IF_AUTH_ENTRIES];
wire [3:0] if_auth_query_index = flin[15:12];
wire [3:0] if_auth_capture_index = cur_lin[15:12];

assign if_auth_ok = !paging_on ||
    (if_auth_multi_valid[if_auth_query_index] &&
     if_auth_multi_page[if_auth_query_index] == flin[31:12] &&
     ((eff_cpl != 2'd3) || if_auth_multi_user[if_auth_query_index]));

always_ff @(posedge clk) begin
  if (!rst_n || tlb_flush || (tlb_fill_en && !tlb_fill_is_d)) begin
    if_auth_multi_valid <= '0;
  end else if (paging_on && fe_translatable && !cur_is_d &&
               fsm_case_enabled && itlb_lk_hit &&
               !xlate_miss && !perm_fault && !fe_xlate_pend) begin
    if_auth_multi_valid[if_auth_capture_index] <= 1'b1;
    if_auth_multi_page[if_auth_capture_index] <= cur_lin[31:12];
    if_auth_multi_user[if_auth_capture_index] <= itlb_lk_perm[2];
  end
end
`endif
