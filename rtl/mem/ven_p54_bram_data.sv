`default_nettype none
// FPGA data-array feasibility leaf for the eight 32-bit P54 D-cache banks.
// Addresses are already translated and tag-checked. This module does not
// admit misses, split extents or MMIO, and is not connected to the core yet.
// Port A of each BRAM serves U or a fill/store write; port B serves V. A
// same-bank write excludes reads, and same-bank U/V reads serialize to retain
// the P54 bank-conflict contract. Responses own the BRAM output register and
// may be held under backpressure without another operation changing that port.
module ven_p54_bram_data #(
    parameter int OWNER_W = 16
) (
    input  wire logic clk,
    input  wire logic rst_n,
    input  wire logic flush,
    input  wire logic wr_valid,
    input  wire logic [2:0] wr_bank,
    input  wire logic [7:0] wr_row,
    input  wire logic [3:0] wr_wstrb,
    input  wire logic [31:0] wr_data,
    output      logic wr_ready,
    input  wire logic u_req_valid,
    input  wire logic [2:0] u_req_bank,
    input  wire logic [7:0] u_req_row,
    input  wire logic [OWNER_W-1:0] u_req_owner,
    output      logic u_req_ready,
    output      logic u_rsp_valid,
    output      logic u_rsp_cancel,
    input  wire logic u_rsp_ready,
    output      logic [OWNER_W-1:0] u_rsp_owner,
    output      logic [31:0] u_rsp_data,
    input  wire logic v_req_valid,
    input  wire logic [2:0] v_req_bank,
    input  wire logic [7:0] v_req_row,
    input  wire logic [OWNER_W-1:0] v_req_owner,
    output      logic v_req_ready,
    output      logic v_bank_conflict,
    output      logic v_rsp_valid,
    output      logic v_rsp_cancel,
    input  wire logic v_rsp_ready,
    output      logic [OWNER_W-1:0] v_rsp_owner,
    output      logic [31:0] v_rsp_data
);
  logic u_valid_q, v_valid_q;
  logic [2:0] u_bank_q, v_bank_q;
  logic [OWNER_W-1:0] u_owner_q, v_owner_q;
  logic [31:0] a_data [8];
  logic [31:0] b_data [8];
  logic u_take, v_take, wr_take;

  assign u_rsp_valid = u_valid_q && !flush;
  assign v_rsp_valid = v_valid_q && !flush;
  assign u_rsp_cancel = u_valid_q && flush;
  assign v_rsp_cancel = v_valid_q && flush;
  assign u_rsp_owner = u_owner_q;
  assign v_rsp_owner = v_owner_q;
  assign u_rsp_data = a_data[u_bank_q];
  assign v_rsp_data = b_data[v_bank_q];

  // A held U response lives in port A's output register for its bank. Do not
  // overwrite that register with a write to the same bank until it is consumed.
  assign wr_ready = rst_n && !flush &&
      !(u_valid_q && !u_rsp_ready && wr_bank == u_bank_q);
  assign wr_take = wr_valid && wr_ready;
  assign u_req_ready = rst_n && !flush && (!u_valid_q || u_rsp_ready) &&
      !(wr_take && wr_bank == u_req_bank);
  assign u_take = u_req_valid && u_req_ready;
  assign v_bank_conflict = u_req_valid && v_req_valid &&
      (u_req_bank == v_req_bank);
  assign v_req_ready = rst_n && !flush && (!v_valid_q || v_rsp_ready) &&
      (!u_req_valid || u_take) && !v_bank_conflict &&
      !(wr_take && wr_bank == v_req_bank);
  assign v_take = v_req_valid && v_req_ready;

  for (genvar bank = 0; bank < 8; bank++) begin : g_bank
    logic bank_write, bank_u, bank_v;
    assign bank_write = wr_take && (wr_bank == 3'(bank));
    assign bank_u = u_take && (u_req_bank == 3'(bank));
    assign bank_v = v_take && (v_req_bank == 3'(bank));
    ven_p54_bram_bank u_ram (
        .clk,
        .a_en(bank_write || bank_u),
        .a_row(bank_write ? wr_row : u_req_row),
        .a_wstrb(bank_write ? wr_wstrb : 4'd0),
        .a_wdata(wr_data),
        .a_rdata(a_data[bank]),
        .b_en(bank_v),
        .b_row(v_req_row),
        .b_rdata(b_data[bank])
    );
  end

  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      u_valid_q <= 1'b0;
      v_valid_q <= 1'b0;
      u_bank_q <= 3'd0;
      v_bank_q <= 3'd0;
      u_owner_q <= '0;
      v_owner_q <= '0;
    end else begin
      if (u_take) begin
        u_valid_q <= 1'b1;
        u_bank_q <= u_req_bank;
        u_owner_q <= u_req_owner;
      end else if (u_rsp_valid && u_rsp_ready) begin
        u_valid_q <= 1'b0;
      end
      if (v_take) begin
        v_valid_q <= 1'b1;
        v_bank_q <= v_req_bank;
        v_owner_q <= v_req_owner;
      end else if (v_rsp_valid && v_rsp_ready) begin
        v_valid_q <= 1'b0;
      end
    end
  end
endmodule
`default_nettype wire
