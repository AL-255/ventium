`default_nettype none
// Feasibility macro for one 32-bit word-position bank of the P54 8 KiB D$.
// Port A is read or byte-write; port B is read-only. Both reads are registered.
// A fill/store write and a B read of the same row must be serialized by the
// caller: FPGA read-during-write collision data is not an architectural value.
module ven_p54_bram_bank #(
    parameter int ROWS = 256,
    parameter int ROW_BITS = $clog2(ROWS)
) (
    input  wire logic                clk,
    input  wire logic                a_en,
    input  wire logic [ROW_BITS-1:0] a_row,
    input  wire logic [3:0]          a_wstrb,
    input  wire logic [31:0]         a_wdata,
    output      logic [31:0]         a_rdata,
    input  wire logic                b_en,
    input  wire logic [ROW_BITS-1:0] b_row,
    output      logic [31:0]         b_rdata
);
  (* ram_style = "block" *) logic [31:0] words [ROWS];

  always_ff @(posedge clk) begin
    if (a_en) begin
      for (int byte_lane = 0; byte_lane < 4; byte_lane++)
        if (a_wstrb[byte_lane])
          words[a_row][8*byte_lane +: 8] <= a_wdata[8*byte_lane +: 8];
      a_rdata <= words[a_row];
    end
    if (b_en)
      b_rdata <= words[b_row];
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (a_en && (|a_wstrb) && b_en && a_row == b_row)
      $fatal(1, "ven_p54_bram_bank: same-row write/read collision must be arbitrated");
`endif
endmodule
`default_nettype wire
