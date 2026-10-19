// Experimental banked registered-translation cache, NOT production RTL.
// Sixteen sets / four ways retain the ordinary parent's 64-page capacity
// without a 64-entry fully associative compare/OR tree. Parent fill, context
// flush and reset still invalidate every child before any capture.
module ven_fe_dtlb #(
    parameter int SETS = 16,
    parameter int WAYS = 4,
    parameter int SET_W = $clog2(SETS),
    parameter int WAY_W = $clog2(WAYS)
) (
    input logic clk, rst_n,
    input logic invalidate,
    input logic [19:0] query_page,
    output logic query_valid, query_hit, query_dirty,
    output logic [19:0] query_phys,
    output logic [2:0] query_perm,
    input logic capture,
    input logic [19:0] capture_page, capture_phys,
    input logic [2:0] capture_perm,
    input logic capture_hit, capture_dirty
);
  localparam int TAG_W = 20-SET_W;
  logic [WAYS-1:0] valid [SETS];
  logic [WAY_W-1:0] victim [SETS];
  // Each generate bank owns a one-dimensional RAM. Read it unconditionally
  // before applying the hit mask: a conditional read of the old 2-D payload
  // array was flattened into 1,600 flip-flops despite its ram_style hint.
  logic [TAG_W-1:0] query_tag [WAYS], capture_tag [WAYS];
  logic [24:0] query_payload [WAYS];
`ifndef SYNTHESIS
  wire [TAG_W-1:0] debug_tags [WAYS][SETS];
`endif
  logic [SET_W-1:0] query_set, capture_set;
  logic [WAY_W-1:0] write_way;
  logic capture_match;
  assign query_set = query_page[SET_W-1:0];
  assign capture_set = capture_page[SET_W-1:0];

  initial begin
    if (SETS < 2 || WAYS < 2 || SETS != (1 << SET_W) ||
        WAYS != (1 << WAY_W) || SET_W >= 20)
      $fatal(1, "banked ven_fe_dtlb requires power-of-two sets/ways >= 2");
  end
  always_comb begin
    query_valid = 1'b0;
    query_hit = 1'b0;
    query_dirty = 1'b0;
    query_phys = '0;
    query_perm = '0;
    for (int w=0; w<WAYS; w++) begin
      if (valid[query_set][w] && query_tag[w] == query_page[19:SET_W]) begin
        query_valid = 1'b1;
        {query_hit,query_dirty,query_phys,query_perm} |= query_payload[w];
      end
    end
  end
  always_comb begin
    write_way = victim[capture_set];
    for (int w=WAYS-1; w>=0; w--)
      if (!valid[capture_set][w]) write_way = WAY_W'(w);
    capture_match = 1'b0;
    for (int w=0; w<WAYS; w++) begin
      if (valid[capture_set][w] && capture_tag[w] == capture_page[19:SET_W]) begin
        capture_match = 1'b1;
        write_way = WAY_W'(w);
      end
    end
  end
  for (genvar w=0; w<WAYS; w++) begin : g_bank
    (* ram_style = "distributed" *) logic [TAG_W-1:0] tags [SETS];
    (* ram_style = "distributed" *) logic [24:0] payload [SETS];
    assign query_tag[w] = tags[query_set];
    assign capture_tag[w] = tags[capture_set];
    assign query_payload[w] = payload[query_set];
    always_ff @(posedge clk) begin
      if (rst_n && !invalidate && capture && write_way == WAY_W'(w)) begin
        tags[capture_set] <= capture_page[19:SET_W];
        payload[capture_set] <= {capture_hit,capture_dirty,capture_phys,capture_perm};
      end
    end
`ifndef SYNTHESIS
    for (genvar s=0; s<SETS; s++) begin : g_debug_tag
      assign debug_tags[w][s] = tags[s];
    end
`endif
  end
  always_ff @(posedge clk) begin
    if (!rst_n || invalidate) begin
      for (int s=0; s<SETS; s++) begin
        valid[s] <= '0;
        victim[s] <= '0;
      end
    end else if (capture) begin
      valid[capture_set][write_way] <= 1'b1;
      if (!capture_match) victim[capture_set] <= write_way + 1'b1;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      for (int s=0; s<SETS; s++)
        for (int a=0; a<WAYS; a++)
          for (int b=a+1; b<WAYS; b++)
            assert (!(valid[s][a] && valid[s][b] && debug_tags[a][s] == debug_tags[b][s]))
              else $fatal(1, "duplicate banked translation owner");
    end
  end
`endif
endmodule
