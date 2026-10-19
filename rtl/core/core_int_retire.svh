// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// P5 RF belongs to the interrupted architectural instruction, not its decode
// attempt. Call only after every effect has succeeded, including a fused
// after-execute #DB, and AFTER any whole-EFLAGS assignment on this edge.
// A bit-select NBA preserves that same edge's new condition/control flags.
// IRET, task transfers and RSM install/preserve flags and do not call this.
task automatic complete_reference_rf();
  if (sys_mode) eflags[16] <= 1'b0;
endtask

// One normal integer retire/#DB authority. The caller has already validated
// every effect and supplies its final EIP/flags; GPRs remain owned by the single
// existing writeback driver. Shared by S_EXEC and optional plain MOV load ACK.
task automatic retire_reference_integer(input logic [31:0] cmt_eip,
                                       input logic flags_we,
                                       input logic [31:0] flags_val);
  logic [3:0] xbp;
  if (flags_we) eflags<=flags_val;
  // Keep the existing per-element REP retirement contract, qualified against
  // the pinned instruction-step oracle. A successful element consumes RF;
  // a failed acquisition/store or pre-execution diversion never reaches here.
  complete_reference_rf();
  eip<=cmt_eip;
  // Preserve the existing P5 #DB priority/fused-record semantics exactly:
  // next-PC instruction FAULT first, then issue-time TF single-step TRAP.
  xbp=(sys_mode && !rf_at_issue)
        ? dr_match(seg_base[SG_CS]+cmt_eip,1'b1) : 4'd0;
  if (sys_mode && xbp!=4'd0)
    arm_db({28'd0,xbp},q_pc,cmt_eip);
  else if (sys_mode && tf_at_issue)
    arm_db(32'd1 << DR6_BS,q_pc,cmt_eip);
  else begin
    retire_valid<=1'b1;
    state<=S_PIPE;
`ifdef VEN_P54_PREFIX_EX_CHAIN
    if (p54_prefix_ex_take) begin
      // Old EX owns this edge's WB/flags/PC. New q_* owns only the next edge.
      capture_reference_decode(next_eip);
      for (int i=0;i<IWORDS*4;i++)
`ifdef VEN_IC_PREFIX_SPAN
        ibuf[i]<=ic_prefix_bytes[i];
`else
        ibuf[i]<=ic_byte(p54_prefix_ex_flin+32'(i));
`endif
      fetch_word<=3'd0;
      sfetch_short_len_q<=4'd0;
`ifdef VEN_UOPCACHE
      sfetch_uop_q<=1'b0;
`endif
`ifdef VEN_SFETCH_RESIDENT
      sfetch_resident_q<=1'b0;
`endif
      state<=d_mem_read ? S_LOAD : S_EXEC;
    end
`endif
  end
endtask
