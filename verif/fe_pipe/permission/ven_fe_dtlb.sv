// Experimental registered-translation cache. This is NOT an architectural TLB:
// every parent D-TLB fill/replacement and every context flush must invalidate
// all entries. Raw permission bits belong to the same captured parent result;
// current privilege, write intent and CR0.WP are NEVER cached. Miss results
// are cached too, so the next cycle can divert to the page walker.
module ven_fe_dtlb #(
    parameter int ENTRIES = 8,
    parameter int INDEX_W = $clog2(ENTRIES)
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
  logic [ENTRIES-1:0] valid;
  logic [19:0] page [ENTRIES], phys [ENTRIES];
  logic [2:0] perm [ENTRIES];
  logic [ENTRIES-1:0] hit, dirty;
  logic [INDEX_W-1:0] victim, write_index;
  logic capture_match;

  initial begin
    if (ENTRIES < 2 || ENTRIES != (1 << INDEX_W))
      $fatal(1, "ven_fe_dtlb requires a power-of-two entry count >= 2");
  end
  always_comb begin
    query_valid = 1'b0;
    query_hit = 1'b0;
    query_dirty = 1'b0;
    query_phys = 20'd0;
    query_perm = 3'd0;
    for (int i = 0; i < ENTRIES; i++) begin
      if (valid[i] && page[i] == query_page) begin
        query_valid = 1'b1;
        query_hit |= hit[i];
        query_dirty |= dirty[i];
        query_phys |= phys[i];
        query_perm |= perm[i];
      end
    end
  end
  always_comb begin
    write_index = victim;
    // Use invalid slots before evicting a live translation. Repeated captures
    // of the same page update its owner in place, never create a duplicate.
    for (int i = ENTRIES-1; i >= 0; i--)
      if (!valid[i]) write_index = INDEX_W'(i);
    capture_match = 1'b0;
    for (int i = 0; i < ENTRIES; i++) begin
      if (valid[i] && page[i] == capture_page) begin
        capture_match = 1'b1;
        write_index = INDEX_W'(i);
      end
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n || invalidate) begin
      valid <= '0;
      victim <= '0;
    end else if (capture) begin
      valid[write_index] <= 1'b1;
      page[write_index] <= capture_page;
      phys[write_index] <= capture_phys;
      perm[write_index] <= capture_perm;
      hit[write_index] <= capture_hit;
      dirty[write_index] <= capture_dirty;
      if (!capture_match) victim <= write_index + 1'b1;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      for (int i = 0; i < ENTRIES; i++)
        for (int j = i+1; j < ENTRIES; j++)
          assert (!(valid[i] && valid[j] && page[i] == page[j]))
            else $fatal(1, "duplicate registered-translation owner");
    end
  end
`endif
endmodule
