// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// One ordered FXCH admission slot, optionally shared with acquired scalar m32
// commands. No speculative stack mutation or replicated arithmetic. Accepted
// commands execute only when the existing leaf interlocks permit them.
// Core integration must track the queued command as a deferred response owner.
`default_nettype none
module ven_fp_fxch_queue
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_decode_pkg::*;
(
    input  wire logic         clk,
    input  wire logic         rst_n,

`ifdef VEN_SNAPSHOT_RESTORE
    // Reset-only simulation checkpoint input.  The full FPU environment is
    // carried so a post-init profile cannot hide a state-restore defect.
    input  wire logic         init_restore,
    input  wire logic [2:0]   init_top,
    input  wire logic [15:0]  init_status,
    input  wire logic [15:0]  init_control,
    input  wire logic [7:0]   init_tag,
    input  wire logic [31:0]  init_fip,
    input  wire logic [15:0]  init_fcs,
    input  wire logic [31:0]  init_fdp,
    input  wire logic [15:0]  init_fds,
    input  wire logic [639:0] init_regs_phys,
`endif

    input  wire logic         cmd_valid,
    output      logic         cmd_ready,
    // Asserted only for an accepted command whose architectural result is
    // completely committed on the acceptance edge and has no response payload
    // that the adapter must consume.  The producer may retire this command on that
    // edge; stores and FNSTSW AX must still await rsp_valid.
    output      logic         cmd_accept_retire,
    // One-cycle-ahead notification for a normal shared-ALU result.  It is
    // registered here, and means the state-file will commit that result on the
    // *current consumer edge*.  It is deliberately not a response/data path:
    // payload-producing, SRT, misc, BCD, and transcendental commands continue
    // to retire solely through rsp_valid.
    output      logic         alu_commit_retire,
    input  wire fxop_e        cmd_op,
    input  wire logic [2:0]   cmd_aluop,
    input  wire logic [2:0]   cmd_sti,
    input  wire logic         cmd_pop,
    input  wire logic [2:0]   cmd_constant,
    input  wire logic [79:0]  cmd_mem,
    input  wire logic [3:0]   cmd_mem_bytes,
    input  wire logic         cmd_fdiv_bug,
    input  wire logic         cmd_fist_bug,
    input  wire logic         cmd_env16,
    input  wire logic         cmd_real_mode,
    input  wire logic [863:0] cmd_env_image,
    input  wire logic         cmd_update_fip,
    input  wire logic [31:0]  cmd_fip,
    input  wire logic [15:0]  cmd_fcs,
    input  wire logic         cmd_update_fdp,
    input  wire logic [31:0]  cmd_fdp,
    input  wire logic [15:0]  cmd_fds,

    output      logic         busy,
    output      logic         rsp_valid,
    output      logic         rsp_unsupported,
    output      logic         rsp_stack_fault,
    output      logic [84:0]  rsp_arith,
    output      logic         rsp_store_valid,
    output      logic [863:0] rsp_store_data,
    output      logic [7:0]   rsp_store_bytes,
    output      logic         rsp_ax_valid,
    output      logic [15:0]  rsp_ax,

    // Architectural observation ports.  These also form the eventual
    // FNSTENV/FNSAVE integration boundary.
    output      logic [2:0]   ftop_o,
    output      logic [15:0]  fstat_o,
    output      logic [15:0]  fctrl_o,
    output      logic [7:0]   fptag_o,
    output      logic [31:0]  fip_o,
    output      logic [15:0]  fcs_o,
    output      logic [31:0]  fdp_o,
    output      logic [15:0]  fds_o,
    output      logic [639:0] fpr_phys_flat_o,
    output      logic [639:0] st_flat_o
);

  logic queued, leaf_valid, leaf_ready, leaf_accept_retire, leaf_busy;
  logic [2:0] saved_sti;
  logic saved_update_fip, saved_update_fdp;
  logic [31:0] saved_fip, saved_fdp;
  logic [15:0] saved_fcs, saved_fds;
  logic may_enqueue;
`ifdef VEN_FP_MEM_QUEUE
  // Reuse the ordered FXCH slot for a completely acquired scalar source.
  // Only command data is buffered: the leaf resolves ST0/TOP/tags when the
  // command executes. No speculative stack map or extra arithmetic unit.
  fxop_e saved_op;
  logic [2:0] saved_aluop;
  logic [31:0] saved_mem;
  logic saved_fdiv_bug;
  logic mem_queue_shape;
  assign mem_queue_shape = (cmd_mem_bytes == 4'd4) && !cmd_pop &&
      ((cmd_op == FX_FLD_M32) || (cmd_op == FX_FILD_M32) ||
       ((cmd_op == FX_AR_M32) &&
        ((cmd_aluop == 3'd0) || (cmd_aluop == 3'd1) ||
         (cmd_aluop >= 3'd4))));
`endif
  // Unmasked exceptions/status-control changes must not cross an unfinished
  // command. Stack emptiness is evaluated by the leaf at execution, in order.
  assign may_enqueue = !queued && leaf_busy && !leaf_ready &&
      ((cmd_op == FX_FXCH)
`ifdef VEN_FP_MEM_QUEUE
       || mem_queue_shape
`endif
      ) && !cmd_pop &&
      (fctrl_o[5:0] == 6'h3f) && !fstat_o[7];
  assign cmd_ready = !queued && (leaf_ready || may_enqueue);
  assign leaf_valid = queued || (cmd_valid && !may_enqueue);
  assign cmd_accept_retire = !queued && leaf_accept_retire;
  assign busy = queued || leaf_busy;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      queued <= 0; saved_sti <= 0;
      saved_update_fip <= 0; saved_update_fdp <= 0;
      saved_fip <= 0; saved_fdp <= 0; saved_fcs <= 0; saved_fds <= 0;
`ifdef VEN_FP_MEM_QUEUE
      saved_op <= FX_NONE; saved_aluop <= 0; saved_mem <= 0;
      saved_fdiv_bug <= 0;
`endif
    end else if (queued) begin
      if (leaf_ready) queued <= 0;
    end else if (cmd_valid && may_enqueue) begin
      queued <= 1; saved_sti <= cmd_sti;
      saved_update_fip <= cmd_update_fip; saved_update_fdp <= cmd_update_fdp;
      saved_fip <= cmd_fip; saved_fcs <= cmd_fcs;
      saved_fdp <= cmd_fdp; saved_fds <= cmd_fds;
`ifdef VEN_FP_MEM_QUEUE
      saved_op <= cmd_op; saved_aluop <= cmd_aluop;
      saved_mem <= cmd_mem[31:0]; saved_fdiv_bug <= cmd_fdiv_bug;
`endif
    end
  end
  ven_fp_top u_fp (
    .clk(clk),
    .rst_n(rst_n),
`ifdef VEN_SNAPSHOT_RESTORE
    .init_restore(init_restore),
    .init_top(init_top),
    .init_status(init_status),
    .init_control(init_control),
    .init_tag(init_tag),
    .init_fip(init_fip),
    .init_fcs(init_fcs),
    .init_fdp(init_fdp),
    .init_fds(init_fds),
    .init_regs_phys(init_regs_phys),
`endif
    .cmd_valid(leaf_valid),
    .cmd_ready(leaf_ready),
    .cmd_accept_retire(leaf_accept_retire),
    .alu_commit_retire(alu_commit_retire),
`ifdef VEN_FP_MEM_QUEUE
    .cmd_op(queued ? saved_op : cmd_op),
    .cmd_aluop(queued ? saved_aluop : cmd_aluop),
`else
    .cmd_op(queued ? FX_FXCH : cmd_op),
    .cmd_aluop(cmd_aluop),
`endif
    .cmd_sti(queued ? saved_sti : cmd_sti),
    .cmd_pop(queued ? 1'b0 : cmd_pop),
    .cmd_constant(cmd_constant),
`ifdef VEN_FP_MEM_QUEUE
    .cmd_mem(queued ? {48'd0, saved_mem} : cmd_mem),
    .cmd_mem_bytes(queued ? 4'd4 : cmd_mem_bytes),
    .cmd_fdiv_bug(queued ? saved_fdiv_bug : cmd_fdiv_bug),
`else
    .cmd_mem(cmd_mem),
    .cmd_mem_bytes(cmd_mem_bytes),
    .cmd_fdiv_bug(cmd_fdiv_bug),
`endif
    .cmd_fist_bug(cmd_fist_bug),
    .cmd_env16(cmd_env16),
    .cmd_real_mode(cmd_real_mode),
    .cmd_env_image(cmd_env_image),
    .cmd_update_fip(queued ? saved_update_fip : cmd_update_fip),
    .cmd_fip(queued ? saved_fip : cmd_fip),
    .cmd_fcs(queued ? saved_fcs : cmd_fcs),
    .cmd_update_fdp(queued ? saved_update_fdp : cmd_update_fdp),
    .cmd_fdp(queued ? saved_fdp : cmd_fdp),
    .cmd_fds(queued ? saved_fds : cmd_fds),
    .busy(leaf_busy),
    .rsp_valid(rsp_valid),
    .rsp_unsupported(rsp_unsupported),
    .rsp_stack_fault(rsp_stack_fault),
    .rsp_arith(rsp_arith),
    .rsp_store_valid(rsp_store_valid),
    .rsp_store_data(rsp_store_data),
    .rsp_store_bytes(rsp_store_bytes),
    .rsp_ax_valid(rsp_ax_valid),
    .rsp_ax(rsp_ax),
    .ftop_o(ftop_o),
    .fstat_o(fstat_o),
    .fctrl_o(fctrl_o),
    .fptag_o(fptag_o),
    .fip_o(fip_o),
    .fcs_o(fcs_o),
    .fdp_o(fdp_o),
    .fds_o(fds_o),
    .fpr_phys_flat_o(fpr_phys_flat_o),
    .st_flat_o(st_flat_o)
  );
endmodule
`default_nettype wire
