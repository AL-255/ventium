`default_nettype none
// Eight 32-bit P54 D-cache banks. This is only the combinational admission
// contract; accepted requests still need owner-tagged response storage and
// checked U/V translation before the core may enable V-memory pairing.
module ven_p54_bank_arb (
    input  wire logic [1:0]       req_valid,
    input  wire logic [1:0][31:0] req_paddr,
    input  wire logic [1:0][1:0]  req_size_log2, // 1, 2, 4 or 8 bytes
    input  wire logic [7:0]       bank_ready,
    output      logic [1:0]       req_grant,
    output      logic [1:0]       req_split,
    output      logic [1:0][7:0] req_banks,
    output      logic [7:0]       used_banks,
    output      logic             bank_conflict
);
  function automatic logic [7:0] bank_extent(
      input logic [4:0] offset, input logic [1:0] size_log2);
    logic [5:0] last_byte;
    logic [7:0] mask;
    begin
      last_byte = {1'b0, offset} + (6'd1 << size_log2) - 6'd1;
      mask = '0;
      for (int bank = 0; bank < 8; bank++)
        if ((bank >= int'(offset[4:2])) && (bank <= int'(last_byte[4:2])))
          mask[bank] = 1'b1;
      return mask;
    end
  endfunction

  always_comb begin
    for (int lane = 0; lane < 2; lane++) begin
      req_split[lane] = ({1'b0, req_paddr[lane][4:0]} +
                         (6'd1 << req_size_log2[lane])) > 6'd32;
      req_banks[lane] = req_split[lane] ? '0 :
          bank_extent(req_paddr[lane][4:0], req_size_log2[lane]);
    end
    req_grant = '0;
    req_grant[0] = req_valid[0] && !req_split[0] &&
                   ((req_banks[0] & bank_ready) == req_banks[0]);
    // A blocked U is older and may not be overtaken by V. A same-bank V
    // remains pending for the next cycle; a distinct-bank V can enter now.
    bank_conflict = req_valid[0] && req_valid[1] && !req_split[0] &&
                    !req_split[1] && ((req_banks[0] & req_banks[1]) != 0);
    req_grant[1] = req_valid[1] && !req_split[1] &&
                   (!req_valid[0] || req_grant[0]) &&
                   ((req_banks[1] & bank_ready) == req_banks[1]) &&
                   (!req_grant[0] || !bank_conflict);
    used_banks = (req_grant[0] ? req_banks[0] : 8'd0) |
                 (req_grant[1] ? req_banks[1] : 8'd0);
  end
endmodule
`default_nettype wire
