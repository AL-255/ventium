`default_nettype none
// Two bounded response slots for checked resident D-cache hits. A caller must
// first prove physical translation, cacheability, tag hit, extent, and fault
// freedom for each request. A rejected request has no cache/backing side effect.
// The hit/data inputs are abstract: this module neither implements bank SRAMs
// nor establishes the physical lookup timing. Do not infer a one-cycle FPGA
// cache from this response-slot test. The optional dual-load owner in core.sv
// consumes lane 1 only after a checked U capture and separate V translation.
module ven_p54_hit_return #(
    parameter int OWNER_W = 16
) (
    input  wire logic clk,
    input  wire logic rst_n,
    input  wire logic flush,
    input  wire logic [1:0] req_valid,
    input  wire logic [1:0] req_hit,
    input  wire logic [1:0][OWNER_W-1:0] req_owner,
    input  wire logic [1:0][31:0] req_paddr,
    input  wire logic [1:0][1:0] req_size_log2,
    input  wire logic [1:0][31:0] req_data,
    input  wire logic [7:0] bank_ready,
    output      logic [1:0] req_ready,
    output      logic [1:0] req_split,
    output      logic [1:0][7:0] req_bank_mask,
    output      logic bank_conflict,
    output      logic [1:0] rsp_valid,
    output      logic [1:0] rsp_cancel,
    input  wire logic [1:0] rsp_ready,
    output      logic [1:0][OWNER_W-1:0] rsp_owner,
    output      logic [1:0][31:0] rsp_paddr,
    output      logic [1:0][31:0] rsp_data
);
  logic [1:0] bank_grant, valid_q;
  logic [7:0] used_banks;
  logic [1:0][OWNER_W-1:0] owner_q;
  logic [1:0][31:0] addr_q, data_q;

  ven_p54_bank_arb u_banks (
      .req_valid, .req_paddr, .req_size_log2, .bank_ready,
      .req_grant(bank_grant), .req_split, .req_banks(req_bank_mask),
      .used_banks, .bank_conflict);

  always_comb begin
    rsp_valid = valid_q & {2{!flush}};
    rsp_cancel = valid_q & {2{flush}};
    rsp_owner = owner_q;
    rsp_paddr = addr_q;
    rsp_data = data_q;
    req_ready = '0;
    req_ready[0] = !flush && bank_grant[0] && req_hit[0] &&
                   (!valid_q[0] || rsp_ready[0]);
    req_ready[1] = !flush && bank_grant[1] && req_hit[1] &&
                   (!req_valid[0] || req_ready[0]) &&
                   (!valid_q[1] || rsp_ready[1]);
  end

  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      valid_q <= '0;
      owner_q <= '0;
      addr_q <= '0;
      data_q <= '0;
    end else begin
      for (int lane = 0; lane < 2; lane++) begin
        if (req_valid[lane] && req_ready[lane]) begin
          valid_q[lane] <= 1'b1;
          owner_q[lane] <= req_owner[lane];
          addr_q[lane] <= req_paddr[lane];
          data_q[lane] <= req_data[lane];
        end else if (rsp_valid[lane] && rsp_ready[lane]) begin
          valid_q[lane] <= 1'b0;
        end
      end
    end
  end
endmodule
`default_nettype wire
