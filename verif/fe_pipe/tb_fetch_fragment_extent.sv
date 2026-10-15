`timescale 1ns/1ps
module fetch_fragment_leaf (
  input logic is_fetch, boundary, allow_fetch, interior, write_kind,
  input logic [11:0] offset,
  input logic [4:0] need, valid_bytes,
  input logic [3:0] data_size, write_mask,
  output logic [2:0] size,
  output logic cross_page
);
  localparam S_FETCH = 1, S_OTHER = 0;
  wire state = is_fetch ? S_FETCH : S_OTHER;
  wire sfetch_boundary = boundary;
  wire sfetch_interior16 = interior;
  wire [4:0] d_fetch_need = need, sfetch_valid_q = valid_bytes;
  wire [31:0] sfetch_demand_addr = {20'd0, offset};
  wire sfetch_demand_req = is_fetch && boundary && allow_fetch && (valid_bytes < need);
  logic [2:0] sfetch_demand_size;
  /* SIZE */
  wire [3:0] cur_data_size = data_size;
  wire [3:0] cur_size = (is_fetch && boundary) ? {1'b0,sfetch_demand_size} : data_size;
  wire [31:0] cur_lin_nat = sfetch_demand_addr;
  logic bd_req, bd_we;
  logic [3:0] bd_wstrb;
  wire sfetch_fast = 1'b0, sfetch_uop_fast = 1'b0;
  wire sfetch_short_fast = 1'b0, sfetch_resident_fast = 1'b0;
  always_comb begin
    bd_req=1'b0; bd_we=1'b0; bd_wstrb=4'd0;
    case (state)
      /* BUS */
      default: begin bd_req=1'b1; bd_we=write_kind; bd_wstrb=write_mask; end
    endcase
  end
  logic [2:0] fx_wr_hi;
  always_comb begin
    fx_wr_hi=3'd0;
    for (int b=0; b<4; b++) if (bd_wstrb[b]) fx_wr_hi=3'(b);
  end
  logic [12:0] fx_rd_end;
  /* CROSS */
  assign size = sfetch_demand_size;
  assign cross_page = fx_cross;
endmodule

module tb_fetch_fragment_extent;
  logic is_fetch, boundary, allow_fetch, interior, write_kind;
  logic [11:0] offset;
  logic [4:0] need, valid_bytes;
  logic [3:0] data_size, write_mask;
  wire [2:0] old_size, fixed_size, bad_guard_size, bad_width_size;
  wire old_cross, fixed_cross, bad_guard_cross, bad_width_cross;
  integer mutant=0;
  wire [2:0] new_size = mutant==1 ? bad_guard_size : mutant==2 ? bad_width_size : fixed_size;
  wire new_cross = mutant==1 ? bad_guard_cross : mutant==2 ? bad_width_cross : fixed_cross;
  fetch_fragment_leaf_old old_dut(.*, .size(old_size), .cross_page(old_cross));
  fetch_fragment_leaf_new new_dut(.*, .size(fixed_size), .cross_page(fixed_cross));
  fetch_fragment_leaf_bad_guard guard_dut(.*, .size(bad_guard_size), .cross_page(bad_guard_cross));
  fetch_fragment_leaf_bad_width width_dut(.*, .size(bad_width_size), .cross_page(bad_width_cross));
  integer checks=0, clipped=0, idle=0, data_crossings=0;
  task automatic check;
    if (old_size !== new_size || old_cross !== new_cross)
      $fatal(1,"FETCH-FRAGMENT-MISMATCH checks=%0d fetch=%b boundary=%b off=%h need=%d valid=%d width=%d old=%b new=%b",
        checks,is_fetch,boundary,offset,need,valid_bytes,data_size,old_cross,new_cross);
    checks++;
    if (is_fetch && boundary && offset>12'hffc && old_size!=0) clipped++;
    if (is_fetch && boundary && old_size==0) idle++;
    if (!is_fetch && old_cross) data_crossings++;
  endtask
  initial begin
    if ($value$plusargs("mutant=%d",mutant)) begin end
    is_fetch=1; boundary=1; allow_fetch=1; write_kind=1; write_mask=4'hf;
    data_size=4'd4; interior=0; need=0; valid_bytes=0; offset=0;
    // Every byte offset and all 5-bit counts, including invalid decoder counts.
    for (int i=0;i<2;i++)
      for (int o=0;o<4096;o++)
        for (int n=0;n<32;n++)
          for (int v=0;v<32;v++) begin
            is_fetch=1; boundary=1; allow_fetch=1; data_size=4;
            write_kind=1; write_mask=4'hf;
            interior=1'(i); offset=12'(o); need=5'(n); valid_bytes=5'(v);
            #1; check();
          end
    // Arbitrary non-fetch widths and both read/write directions at page edges.
    is_fetch=0;
    for (int w=0;w<16;w++)
      for (int st=0;st<16;st++)
        for (int k=0;k<2;k++)
          for (int o=4076;o<4096;o++) begin
            is_fetch=0; boundary=0; allow_fetch=1; interior=0; need=0; valid_bytes=0;
            data_size=4'(w); write_mask=4'(st); write_kind=1'(k); offset=12'(o);
            #1; check();
          end
    // Disabled fetch requests, non-boundary fetches, and arbitrary widths.
    is_fetch=1; allow_fetch=0;
    for (int b=0;b<2;b++)
      for (int w=0;w<16;w++)
        for (int o=0;o<4096;o++) begin
          is_fetch=1; allow_fetch=0; interior=0; need=16; valid_bytes=0;
          write_kind=0; write_mask=0;
          boundary=1'(b); data_size=4'(w); offset=12'(o); #1; check();
        end
    if (checks!=8529920 || clipped==0 || idle==0 || data_crossings==0)
      $fatal(1,"FETCH-FRAGMENT-COVERAGE checks=%0d clipped=%0d idle=%0d data_crossings=%0d",
        checks,clipped,idle,data_crossings);
    $display("FETCH-FRAGMENT-OK checks=%0d clipped=%0d idle=%0d data_crossings=%0d",
      checks,clipped,idle,data_crossings);
    $finish;
  end
endmodule
