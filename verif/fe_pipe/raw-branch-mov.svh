// Cache-only successor hint, NOT an execution decoder. No retained descriptor.
// Keep this deliberately smaller than decode.sv: unprefixed MOV r32,[base]
// and MOV r32,[base+disp8], no SIB, literal address, or ESP destination.
// Compare every accepted bit against the real decoder in the leaf test.
function automatic fpd_t mc_raw_branch_mov(input logic [7:0] b0, b1, b2);
  fpd_t d;
  logic [2:0] base, dst;
  begin
    d = '0;
    base = b1[2:0]; dst = b1[5:3];
    if (b0 == 8'h8b && !b1[7] && base != 3'd4 && dst != 3'd4 &&
        !(b1[7:6] == 2'b00 && base == 3'd5)) begin
      d.simple = 1'b1; d.alu_op = ALU_ADD;
      d.len = b1[6] ? 4'd3 : 4'd2;
      d.is_load = 1'b1; d.is_mem = 1'b1; d.wreg = 1'b1;
      d.dst = dst; d.base = base;
      d.mem_base_en = 1'b1; d.mem_ss = (base == 3'd5);
      d.mem_disp = b1[6] ? {{24{b2[7]}},b2} : 32'd0;
      d.reads = 8'b1 << base; d.addr_mask = 8'b1 << base;
      d.writes = 8'b1 << dst;
      d.pairs_first = 1'b1; d.pairs_second = 1'b1;
    end
    return d;
  end
endfunction
