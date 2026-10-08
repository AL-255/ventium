// Local physical cost probe, NOT a CPU model or a CPU timing constraint.
// Identical registered stimulus and result boundaries for all three variants.
// PERM_CUT selects captured raw U permissions; current access policy stays live.
// The independent parent V lookup remains in every variant.
module tlb_cut_probe #(parameter int CUT = 0, parameter bit PERM_CUT = 0) (
    input logic clk, rst_n, data_access, fill_en, fill_big, fill_dirty, flush_en,
    input logic user_access, write_access, write_protect,
    input logic [31:0] query_lin, pair_lin, fill_lin,
    input logic [19:0] fill_pfn,
    input logic [2:0] fill_perm,
    output logic [31:0] phys_o, pair_phys_o,
    output logic [2:0] perm_o, pair_perm_o,
    output logic valid_o, hit_o, dirty_o, parent_hit_o, parent_dirty_o,
    output logic pair_hit_o, pair_dirty_o, perm_fault_o
);
  logic rst_q, access_q, fill_en_q, fill_big_q, fill_dirty_q, flush_q;
  logic [31:0] query_q, pair_q, fill_lin_q;
  logic [19:0] fill_pfn_q;
  logic [2:0] fill_perm_q;
  logic parent_hit, parent_dirty, pair_hit, pair_dirty;
  logic [31:0] parent_phys, pair_phys;
  logic [2:0] parent_perm, pair_perm;
  logic child_valid, child_hit, child_dirty;
  logic [19:0] child_phys;
  logic [2:0] child_perm, selected_perm;
  logic selected_hit, user_q, write_q, wp_q;
  assign selected_perm = PERM_CUT ? child_perm : parent_perm;
  assign selected_hit = PERM_CUT ? child_valid && child_hit : parent_hit;
  always_ff @(posedge clk) begin
    user_q <= user_access; write_q <= write_access; wp_q <= write_protect;
    rst_q <= rst_n; access_q <= data_access;
    query_q <= query_lin; pair_q <= pair_lin;
    fill_en_q <= fill_en; fill_big_q <= fill_big;
    fill_dirty_q <= fill_dirty; flush_q <= flush_en;
    fill_lin_q <= fill_lin; fill_pfn_q <= fill_pfn; fill_perm_q <= fill_perm;
    phys_o <= child_valid && child_hit ? {child_phys,query_q[11:0]} : query_q;
    perm_o <= selected_perm; parent_hit_o <= parent_hit; parent_dirty_o <= parent_dirty;
    perm_fault_o <= access_q && selected_hit &&
        ((user_q && !selected_perm[2]) ||
         (write_q && !selected_perm[1] && (user_q || wp_q)));
    valid_o <= child_valid; hit_o <= child_hit; dirty_o <= child_dirty;
    pair_phys_o <= pair_phys; pair_perm_o <= pair_perm;
    pair_hit_o <= pair_hit; pair_dirty_o <= pair_dirty;
  end
  tlb_assoc #(.IS_D(1'b1), .TLB_SETS(16), .TLB_WAYS(4), .P54_LARGE(1'b1)) parent (
    .clk(clk), .rst_n(rst_q), .lk_lin(query_q), .lk_hit(parent_hit),
    .lk_phys(parent_phys), .lk_perm(parent_perm), .lk_dirty(parent_dirty),
    .pair_lin(pair_q), .pair_hit(pair_hit), .pair_phys(pair_phys),
    .pair_perm(pair_perm), .pair_dirty(pair_dirty),
    .fill_en(fill_en_q), .fill_lin(fill_lin_q), .fill_pfn(fill_pfn_q),
    .fill_perm(fill_perm_q), .fill_big(fill_big_q), .fill_dirty(fill_dirty_q),
    .flush_en(flush_q)
  );
  generate
    if (CUT == 0) begin : g_direct
      assign child_valid = 1'b1;
      assign child_hit = parent_hit;
      assign child_dirty = parent_dirty;
      assign child_phys = parent_phys[31:12];
      assign child_perm = parent_perm;
    end else if (CUT == 1) begin : g_one
      logic valid_q, hit_q, dirty_q;
      logic [19:0] page_q, phys_q;
      logic [2:0] perm_q;
      assign child_perm = perm_q;
      assign child_valid = valid_q && page_q == query_q[31:12];
      assign child_hit = hit_q;
      assign child_dirty = dirty_q;
      assign child_phys = phys_q;
      always_ff @(posedge clk) begin
        if (!rst_q || flush_q || fill_en_q) valid_q <= 1'b0;
        else if (access_q && !child_valid) begin
          valid_q <= 1'b1; page_q <= query_q[31:12];
          phys_q <= parent_phys[31:12]; hit_q <= parent_hit; dirty_q <= parent_dirty;
          perm_q <= parent_perm;
        end
      end
    end else if (CUT == 8) begin : g_eight
      ven_fe_dtlb #(.ENTRIES(8)) child (
        .clk(clk), .rst_n(rst_q), .invalidate(flush_q || fill_en_q),
        .query_page(query_q[31:12]), .query_valid(child_valid),
        .query_hit(child_hit), .query_dirty(child_dirty), .query_phys(child_phys),
        .query_perm(child_perm), .capture_perm(parent_perm),
        .capture(access_q && !child_valid), .capture_page(query_q[31:12]),
        .capture_phys(parent_phys[31:12]), .capture_hit(parent_hit), .capture_dirty(parent_dirty)
      );
    end else begin : g_bad
      initial $fatal(1, "CUT must be 0, 1 or 8");
    end
  endgenerate
endmodule
