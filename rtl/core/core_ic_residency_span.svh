// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// PROPOSAL ONLY: module-scope helpers; not connected to the production core.
// Requires the existing VEN_IC_BRAM IC FRONT SPAN and returned-port signals.
// All helpers preserve the procedural raw lookup's default-zero treatment of
// an unknown arithmetic address. Do not turn their ordered ifs into ternaries.
`ifdef VEN_IC_BRAM
  wire [31:0] ic_res_prev_addr = flin - 32'd1;
  // One static backwards query, shared by zero-length end-point consumers.
  wire [IC_WAYW:0] ic_res_prev = ic_front_probe(ic_res_prev_addr);

  wire ic_res_a_buffered = ic_front_a[IC_WAYW] &&
      ((rdA_set_q == flin[5 +: IC_IDXW] &&
        rdA_way_q == ic_front_a[IC_WAYW-1:0] && !ic_rd_collA) ||
       (rdB_set_q == flin[5 +: IC_IDXW] &&
        rdB_way_q == ic_front_a[IC_WAYW-1:0] && !ic_rd_collB));
  wire ic_res_b_buffered = ic_front_b[IC_WAYW] &&
      ((rdA_set_q == flin_nl[5 +: IC_IDXW] &&
        rdA_way_q == ic_front_b[IC_WAYW-1:0] && !ic_rd_collA) ||
       (rdB_set_q == flin_nl[5 +: IC_IDXW] &&
        rdB_way_q == ic_front_b[IC_WAYW-1:0] && !ic_rd_collB));
  wire ic_res_prev_buffered = ic_res_prev[IC_WAYW] &&
      ((rdA_set_q == ic_res_prev_addr[5 +: IC_IDXW] &&
        rdA_way_q == ic_res_prev[IC_WAYW-1:0] && !ic_rd_collA) ||
       (rdB_set_q == ic_res_prev_addr[5 +: IC_IDXW] &&
        rdB_way_q == ic_res_prev[IC_WAYW-1:0] && !ic_rd_collB));

  // Contract: offset is 0..31, or contains X/Z. Address is flin+offset
  // with FULL 32-bit wrap. The six-bit sum never overflows for known inputs.
  function automatic logic ic_res_present_offset(input logic [5:0] offset);
    logic [5:0] pos;
    begin
      pos = {1'b0,flin[4:0]} + offset;
      ic_res_present_offset = 1'b0;
      if (pos < 6'd32) ic_res_present_offset = ic_front_a[IC_WAYW];
      else if (pos >= 6'd32) ic_res_present_offset = ic_front_b[IC_WAYW];
    end
  endfunction

  // Contract: count is 0..30, or contains X/Z. Address is flin+count-1.
  // count==0 is NOT silently treated as a positive instruction length.
  function automatic logic ic_res_present_end(input logic [5:0] count);
    logic [5:0] pos;
    begin
      pos = {1'b0,flin[4:0]} + count;
      ic_res_present_end = 1'b0;
      if (pos == 6'd0) ic_res_present_end = ic_res_prev[IC_WAYW];
      else if (pos <= 6'd32) ic_res_present_end = ic_front_a[IC_WAYW];
      else if (pos > 6'd32) ic_res_present_end = ic_front_b[IC_WAYW];
    end
  endfunction

  function automatic logic ic_res_buffered_offset(input logic [5:0] offset);
    logic [5:0] pos;
    begin
      pos = {1'b0,flin[4:0]} + offset;
      ic_res_buffered_offset = 1'b0;
      if (pos < 6'd32) ic_res_buffered_offset = ic_res_a_buffered;
      else if (pos >= 6'd32) ic_res_buffered_offset = ic_res_b_buffered;
    end
  endfunction

  function automatic logic ic_res_buffered_end(input logic [5:0] count);
    logic [5:0] pos;
    begin
      pos = {1'b0,flin[4:0]} + count;
      ic_res_buffered_end = 1'b0;
      if (pos == 6'd0) ic_res_buffered_end = ic_res_prev_buffered;
      else if (pos <= 6'd32) ic_res_buffered_end = ic_res_a_buffered;
      else if (pos > 6'd32) ic_res_buffered_end = ic_res_b_buffered;
    end
  endfunction
`endif
