// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// rtl/soc/ven_soc_dbg.sv — VEN_DBG_CORE on-die debug/trace block.
//
// A purely-observational forensic unit fed by ventium_top's debug bundle. It
// gives the PS (and on-board post-mortem) what no register-poll could before:
//
//   * LAST-RETIRE LATCH — committed EIP/CS/ESP/EFLAGS of the last retired insn
//     (so a freeze is diagnosable: "where was the core?" without a sim).
//   * PC RING BUFFER (DEPTH entries, BRAM) — the last N retired {state,CS,EIP}.
//     Reading it back on a freeze shows the INSTRUCTION TRAIL into the derail
//     (e.g. the bad IRET -> garbage jump that took ~a faithful sim to find).
//   * FREEZE DETECTOR — a stall counter (reset on each retire); when it crosses
//     a PS-set threshold it LATCHES a snapshot (EIP/FSM-state/last-vector) and a
//     sticky `frozen` flag, capturing the state AT the freeze (before the PS
//     even polls), distinguishing a silent stall from a clean halt.
//   * PERFORMANCE COUNTERS — cycles, retired insns, no-retire (stall) cycles,
//     I/O-wait cycles, external-IRQ count. CPI = cyc/retired; stall% and I/O
//     overhead fall out directly. All windowed (cleared by R_DBG_CTRL).
//
// Single clock domain (pl_clk0, same as ven_soc_axil + the core). Instantiated
// ONLY by ventium_kv260_core under `ifdef VEN_DBG_CORE; the module itself is
// inert when never instantiated, so a non-debug build is byte/cycle-identical.

module ven_soc_dbg #(
    parameter int DEPTH = 32,                 // PC ring depth (power of 2)
    parameter int IDXW  = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- debug bundle from ventium_top (pure observers) ----------------------
    input  logic        dbg_retire_valid,
    input  logic [31:0] dbg_eip,
    input  logic [15:0] dbg_cs,
    input  logic [31:0] dbg_esp,
    input  logic [31:0] dbg_eflags,
    input  logic [5:0]  dbg_state,
    input  logic [7:0]  dbg_int_vec,
    input  logic [31:0] dbg_fault_pc,
    input  logic [31:0] dbg_cr0,
    input  logic        io_pending,      // ven_soc_axil io-bridge: core parked in S_IO
    input  logic        inta,            // 1-clock external-interrupt acknowledge

    // ---- control (R_DBG_CTRL / R_DBG_TRACE_IDX in ven_soc_axil) ---------------
    input  logic        ctrl_clear,      // 1-clock: zero perf counters + clear freeze/ring
    input  logic [31:0] freeze_thresh,   // stall cycles -> freeze snapshot (0 = disabled)
    input  logic [IDXW-1:0] trace_rd_idx,// 0 = most-recent retired PC, 1 = previous, ...

    // ---- readback (combinational; ven_soc_axil registers these on rd_fire) ----
    output logic [31:0] last_eip,
    output logic [15:0] last_cs,
    output logic [31:0] last_esp,
    output logic [31:0] last_eflags,
    output logic        frozen,          // sticky: a freeze was detected
    output logic [31:0] frozen_eip,
    output logic [5:0]  frozen_state,
    output logic [7:0]  frozen_vec,
    output logic [31:0] trace_pc,        // ring[idx].eip          (1-clock read latency)
    output logic [31:0] trace_aux,       // {state[5:0], cs[15:0]} (same entry)
    output logic [IDXW:0] trace_count,   // entries captured (saturates at DEPTH)
    output logic [63:0] perf_cyc,        // total cycles since clear
    output logic [63:0] perf_retired,    // retired instructions since clear
    output logic [31:0] perf_stall,      // cycles with NO retire
    output logic [31:0] perf_io,         // cycles parked in S_IO (io_pending)
    output logic [31:0] perf_irq         // external interrupts acknowledged (inta)
);

  // ---- last-retire latch ----------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      last_eip <= 32'd0; last_cs <= 16'd0; last_esp <= 32'd0; last_eflags <= 32'd0;
    end else if (dbg_retire_valid) begin
      last_eip    <= dbg_eip;
      last_cs     <= dbg_cs;
      last_esp    <= dbg_esp;
      last_eflags <= dbg_eflags;
    end
  end

  // ---- PC ring buffer (BRAM-inferred SDP: 1 write on retire, 1 read port) ----
  // Entry = {state[5:0], cs[15:0], eip[31:0]} = 54 bits.
  (* ram_style = "block" *) logic [53:0] ring [DEPTH];
  logic [IDXW-1:0] head;       // next write slot (wraps mod DEPTH)
  logic [IDXW:0]   count;      // populated entries (saturates at DEPTH)
  logic [53:0]     rd_q;       // registered read data

  // read index: most-recent (head-1) minus the caller's "N back" offset, mod DEPTH.
  logic [IDXW-1:0] rd_addr;
  assign rd_addr = head - 1'b1 - trace_rd_idx;

  always_ff @(posedge clk) begin
    if (!rst_n || ctrl_clear) begin
      head  <= '0;
      count <= '0;
    end else if (dbg_retire_valid) begin
      ring[head] <= {dbg_state, dbg_cs, dbg_eip};
      head <= head + 1'b1;
      if (count < (IDXW+1)'(DEPTH)) count <= count + 1'b1;
    end
    rd_q <= ring[rd_addr];     // 1-clock-latency read (stable when the core is frozen)
  end

  assign trace_pc    = rd_q[31:0];
  assign trace_aux   = {10'd0, rd_q[53:48], rd_q[47:32]};  // {state[5:0], cs[15:0]}
  assign trace_count = count;

  // ---- freeze detector ------------------------------------------------------
  logic [31:0] stall;
  always_ff @(posedge clk) begin
    if (!rst_n || ctrl_clear) begin
      stall        <= 32'd0;
      frozen       <= 1'b0;
      frozen_eip   <= 32'd0;
      frozen_state <= 6'd0;
      frozen_vec   <= 8'd0;
    end else begin
      if (dbg_retire_valid)            stall <= 32'd0;
      else if (stall != 32'hFFFF_FFFF) stall <= stall + 32'd1;
      // latch the snapshot exactly once, when the stall first crosses threshold
      if (!frozen && (freeze_thresh != 32'd0) && !dbg_retire_valid
          && (stall + 32'd1 == freeze_thresh)) begin
        frozen       <= 1'b1;
        frozen_eip   <= last_eip;    // last committed EIP before the stall
        frozen_state <= dbg_state;   // FSM micro-state at the freeze
        frozen_vec   <= dbg_int_vec; // last exception/IRQ vector
      end
    end
  end

  // ---- performance counters (windowed; cleared by ctrl_clear) ---------------
  always_ff @(posedge clk) begin
    if (!rst_n || ctrl_clear) begin
      perf_cyc <= 64'd0; perf_retired <= 64'd0; perf_stall <= 32'd0;
      perf_io  <= 32'd0; perf_irq <= 32'd0;
    end else begin
      perf_cyc <= perf_cyc + 64'd1;
      if (dbg_retire_valid) perf_retired <= perf_retired + 64'd1;
      else                  perf_stall   <= perf_stall   + 32'd1;
      if (io_pending)       perf_io       <= perf_io      + 32'd1;
      if (inta)             perf_irq      <= perf_irq     + 32'd1;
    end
  end

endmodule : ven_soc_dbg
