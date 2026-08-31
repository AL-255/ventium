// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_fp_state.sv -- compact x87 architectural state for the shared FPU.
//
// The eight 80-bit data words live in a bank.  A small permutation table maps
// architectural physical register numbers onto that bank.  FXCH therefore
// exchanges two 3-bit pointers rather than moving 160 data bits.  Tags remain
// indexed by architectural physical register number, exactly as in fpu_top.

`default_nettype none

module ven_fp_state (
    input  wire logic         clk,
    input  wire logic         rst_n,

`ifdef VEN_SNAPSHOT_RESTORE
    // Simulation-only architectural checkpoint seed.  This is reset-only: it
    // never adds a writable state path to a production image.
    input  wire logic         init_restore,
    input  wire logic [2:0]   init_top,
    input  wire logic [15:0]  init_status,
    input  wire logic [15:0]  init_control,
    input  wire logic [7:0]   init_tag,
    input  wire logic [31:0]  init_fip,
    input  wire logic [15:0]  init_fcs,
    input  wire logic [31:0]  init_fdp,
    input  wire logic [15:0]  init_fds,
    // Physical register order: p*80 +: 80 is x87 physical slot p.
    input  wire logic [639:0] init_regs_phys,
`endif

    // Two architectural ST(i) read ports.  Indices are relative to TOP.
    input  wire logic [2:0]   rd0_idx,
    input  wire logic [2:0]   rd1_idx,
    output      logic [79:0]  rd0_data,
    output      logic [79:0]  rd1_data,
    output      logic         rd0_empty,
    output      logic         rd1_empty,

    output      logic [2:0]   top_o,
    output      logic [15:0]  status_o,
    output      logic [15:0]  control_o,
    output      logic [7:0]   tag_o,
    output      logic [31:0]  fip_o,
    output      logic [15:0]  fcs_o,
    output      logic [31:0]  fdp_o,
    output      logic [15:0]  fds_o,

    // Materialized views used by verification and environment save/restore.
    // phys_flat[p*80 +: 80] is architectural physical register p.
    // st_flat[i*80 +: 80] is architectural ST(i).
    output      logic [639:0] phys_flat_o,
    output      logic [639:0] st_flat_o,

    // Canonical commit interface.  A result write may co-fire with a pop.
    input  wire logic         commit_init,
    input  wire logic         commit_push,
    input  wire logic [79:0]  push_data,
    input  wire logic         commit_write,
    input  wire logic [2:0]   write_idx,
    input  wire logic [79:0]  write_data,
    input  wire logic         write_mark_valid,
    input  wire logic         commit_swap,
    input  wire logic [2:0]   swap_idx,
    input  wire logic [1:0]   commit_pop,
    input  wire logic         commit_free,
    input  wire logic [2:0]   free_idx,
    input  wire logic         commit_inc_top,
    input  wire logic         commit_dec_top,
    input  wire logic         commit_status,
    input  wire logic [15:0]  status_data,
    input  wire logic         commit_control,
    input  wire logic [15:0]  control_data,

    // Environment-pointer commits.  The command shell decides which decoded
    // operations are administrative and which have a memory operand; this leaf
    // only preserves the proven fpu_top write ordering.
    input  wire logic         commit_eptr,
    input  wire logic [31:0]  eptr_fip,
    input  wire logic [15:0]  eptr_fcs,
    input  wire logic         commit_dptr,
    input  wire logic [31:0]  dptr_fdp,
    input  wire logic [15:0]  dptr_fds,

    // FLDENV/FRSTOR canonical commit.  env_regs_phys is physical-register
    // order, exactly matching old fpu_top.env_fpr_flat.
    input  wire logic         commit_env,
    input  wire logic [15:0]  env_control,
    input  wire logic [2:0]   env_top,
    input  wire logic [15:0]  env_status,
    input  wire logic [7:0]   env_tag,
    input  wire logic         commit_env_regs,
    input  wire logic [639:0] env_regs_phys
);

  logic [79:0] bank [8];
  logic [2:0]  map  [8];
  logic [2:0]  top;
  logic [15:0] status;
  logic [15:0] control;
  logic [7:0]  tag;
  logic [31:0] fip, fdp;
  logic [15:0] fcs, fds;

  logic [2:0] rd0_phys, rd1_phys;

  assign rd0_phys  = top + rd0_idx;
  assign rd1_phys  = top + rd1_idx;
  assign rd0_data  = bank[map[rd0_phys]];
  assign rd1_data  = bank[map[rd1_phys]];
  assign rd0_empty = tag[rd0_phys];
  assign rd1_empty = tag[rd1_phys];

  assign top_o     = top;
  assign status_o  = status;
  assign control_o = control;
  assign tag_o     = tag;
  assign fip_o     = fip;
  assign fcs_o     = fcs;
  assign fdp_o     = fdp;
  assign fds_o     = fds;

  always_comb begin
    phys_flat_o = '0;
    st_flat_o   = '0;
    for (int i = 0; i < 8; i++) begin
      phys_flat_o[i*80 +: 80] = bank[map[i]];
      st_flat_o[i*80 +: 80]   = bank[map[top + i[2:0]]];
    end
  end

  // FSW.ES is sticky and is set by any unmasked exception.  On P5 without an
  // asynchronous coprocessor, FSW.B mirrors FSW.ES.
  function automatic logic [15:0] with_es_b(input logic [15:0] value);
    logic es;
    begin
      es = value[7] | (|(value[5:0] & ~control[5:0]));
      with_es_b = {es, value[14:8], es, value[6:0]};
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      top     <= 3'd0;
      status  <= 16'h0000;
      control <= 16'h037f;
      tag     <= 8'hff;
      fip     <= 32'd0;
      fcs     <= 16'd0;
      fdp     <= 32'd0;
      fds     <= 16'd0;
      for (int i = 0; i < 8; i++) begin
        bank[i] <= 80'd0;
        map[i]  <= i[2:0];
      end
`ifdef VEN_SNAPSHOT_RESTORE
      if (init_restore) begin
        // A checkpoint is taken at an instruction boundary, so there is no
        // in-flight FP command to recover.  Re-establish identity mapping and
        // materialize the architectural *physical* slots directly; this is
        // exact even after an earlier FXCH had compacted the private bank.
        top     <= init_top;
        status  <= init_status;
        control <= init_control;
        tag     <= init_tag;
        fip     <= init_fip;
        fcs     <= init_fcs;
        fdp     <= init_fdp;
        fds     <= init_fds;
        for (int i = 0; i < 8; i++) begin
          bank[i] <= init_regs_phys[i*80 +: 80];
          map[i]  <= i[2:0];
        end
      end
`endif
    end else begin
      // FNINIT has the same priority/order as the proven fpu_top: it resets
      // metadata but deliberately preserves stale register contents.
      if (commit_init) begin
        top     <= 3'd0;
        status  <= 16'h0000;
        control <= 16'h037f;
        tag     <= 8'hff;
        fip     <= 32'd0;
        fcs     <= 16'd0;
        fdp     <= 32'd0;
        fds     <= 16'd0;
      end

      if (commit_push) begin
        top             <= top - 3'd1;
        tag[top - 3'd1] <= 1'b0;
        bank[map[top - 3'd1]] <= push_data;
      end

      if (commit_write) begin
        bank[map[top + write_idx]] <= write_data;
        if (write_mark_valid)
          tag[top + write_idx] <= 1'b0;
      end

      if (commit_swap) begin
        map[top]            <= map[top + swap_idx];
        map[top + swap_idx] <= map[top];
      end

      if (commit_pop == 2'd1) begin
        tag[top] <= 1'b1;
        top      <= top + 3'd1;
      end else if (commit_pop == 2'd2) begin
        tag[top]        <= 1'b1;
        tag[top + 3'd1] <= 1'b1;
        top             <= top + 3'd2;
      end

      if (commit_free)
        tag[top + free_idx] <= 1'b1;

      if (commit_inc_top)
        top <= top + 3'd1;
      if (commit_dec_top)
        top <= top - 3'd1;

      if (commit_control)
        control <= control_data;
      if (commit_status)
        status <= with_es_b(status_data);

      if (commit_eptr) begin
        fip <= eptr_fip;
        fcs <= eptr_fcs;
      end
      if (commit_dptr) begin
        fdp <= dptr_fdp;
        fds <= dptr_fds;
      end

      // These commits are deliberately after the ordinary scalar ports, as in
      // the proven fpu_top.  with_es_b observes the pre-edge control word under
      // NBA semantics, including when control and status are restored together.
      if (commit_env) begin
        control <= env_control;
        top     <= env_top;
        status  <= with_es_b(env_status);
        tag     <= env_tag;
      end
      if (commit_env_regs)
        for (int i = 0; i < 8; i++)
          bank[map[i]] <= env_regs_phys[i*80 +: 80];
    end
  end

endmodule

`default_nettype wire
