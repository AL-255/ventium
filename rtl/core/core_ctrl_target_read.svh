// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Optional address steering for the EXISTING two synchronous I-cache ports.
// The slow control owner has already resolved its target before its final
// execute/store edge. Read that target while the old instruction still owns
// the FSM, instead of waiting for EIP's NBA and adding a BRAM turnaround.
// This performs no fetch, allocation, LRU/BTB update, decode, or retirement.
// Returned set/way/collision and current presence checks remain authoritative.
`ifndef VEN_IC_BRAM
  initial $fatal(1, "VEN_P54_CTRL_TARGET_READ requires VEN_IC_BRAM");
`endif

logic p54_ctrl_target_read;
logic [31:0] p54_ctrl_target_addr, p54_ctrl_target_next_line;
always_comb begin
  p54_ctrl_target_read = 1'b0;
  p54_ctrl_target_addr = flin;
  // The first implementation is deliberately flat/user-only: the existing
  // returned-buffer permission checks must not be bypassed by virtual or
  // segmented targets. Reading an absent line is harmless; it grants no hit.
`ifdef VEN_P54_CTRL_TARGET_SYSTEM
  // Read addresses only: no request, translation, allocation, LRU touch or
  // instruction admission. The returned set/way/collision and normal fetch
  // permissions still own consumption after the architectural redirect.
  if (cycle_mode && !def16 && !smm_active &&
      ((!sys_mode && !soc_en && !cosim_en && !paging_on && fbase==32'd0) ||
       (sys_mode && sys_fp_ok && !real_mode && !v86 && cs_d &&
        !fp_dbg_active && !dbg_block_issue)) && (q_kind == K_CTRL)) begin
`else
  if (cycle_mode && !sys_mode && !soc_en && !cosim_en && !def16 &&
      !paging_on && !smm_active && (fbase == 32'd0) &&
      (q_kind == K_CTRL)) begin
`endif
    if (state == S_EXEC) begin
      if (q_ct inside {CT_RETN, CT_RETN_IMM}) begin
        p54_ctrl_target_read = 1'b1;
`ifdef VEN_P54_CTRL_TARGET_SYSTEM
        p54_ctrl_target_addr = fbase + ((q_w == 3'd2)
                                ? {16'd0, mem_load_data[15:0]} : mem_load_data);
`else
        p54_ctrl_target_addr = (q_w == 3'd2)
                                ? {16'd0, mem_load_data[15:0]} : mem_load_data;
`endif
      end else if (q_ct == CT_JMPIND) begin
        p54_ctrl_target_read = 1'b1;
        p54_ctrl_target_addr =
`ifdef VEN_P54_CTRL_TARGET_SYSTEM
                              fbase +
`endif
                              call_target;
      end
    end else if ((state == S_STORE) &&
                 (q_ct inside {CT_CALLREL, CT_CALLIND})) begin
      p54_ctrl_target_read = 1'b1;
      p54_ctrl_target_addr =
`ifdef VEN_P54_CTRL_TARGET_SYSTEM
                              fbase +
`endif
                              call_target;
    end
  end
  p54_ctrl_target_next_line = {p54_ctrl_target_addr[31:5], 5'd0} + 32'd32;
end
