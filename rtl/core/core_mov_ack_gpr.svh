// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Raw S_LOAD writeback fragment, included only inside the existing GPR driver.
// Kept separate so the focused leaf can exercise this exact new writer.
if (p54_mov_ack_take) begin
  gpr_we[q_dst_reg]=1'b1;
  gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg],p54_mov_ack_load_value,
                             q_w,q_dst_high8);
end
