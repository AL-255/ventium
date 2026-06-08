// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_l1d.sv — L1 unified data array + line-fill engine (P1-1 step 1).
//
// The DATA half the cycle model never needed (dcache_timing.sv is timing-only —
// load data came from the BFM via mem_rdata). On the real FPGA there is no BFM:
// hit data must come from a PL-side array, and a miss must pull the 32-byte line
// from the backing memory (the BFM in sim now; the AXI4 master → PS-DDR later).
// This module is that array + the miss line-fill FSM, sitting BETWEEN the core's
// mem_* port (the same-cycle-ack contract) and a backing mem_* port. See
// fpga/L1_AXI_DESIGN.md §2/§3.
//
// Geometry: 8 KB, 2-way, 32-byte line, 128 sets — IDENTICAL to icache + the oracle
// p5trace L1, so cache behaviour stays consistent. Data = packed 256-bit lines in
// distributed RAM (the icache pattern, P0-3: shallow-and-wide → LUTRAM, async read
// so a HIT returns combinationally for the same-cycle ack). tag/val/lru mirror
// dcache_timing's 2-way-LRU.
//
// Contract (fpga/L1_AXI_DESIGN.md §1):
//   * READ HIT  → c_rdata = the addressed word, c_ack=1, SAME CLOCK (no backing).
//   * READ MISS → c_ack=0 (core stalls), the fill FSM bursts the 32-byte line
//     (8 words) from the backing, allocates the not-MRU victim, then the retry hits.
//   * WRITE     → write-THROUGH: update the array on a hit (byte strobes) AND
//     forward to the backing; c_ack follows the backing ack. (No write-allocate —
//     a write miss does not pull the line; write-back/MESI is a later optimization.)
// At most one core transaction in flight (the core's mem port is single-beat).
//
// NOT YET WIRED into the core: bus_mode=2 + the fast-path load's miss-stall gate are
// the next step. Standalone-synthesizable + unit-checkable as-is.

module ven_l1d #(
    parameter int L1_SETS = 128,
    parameter int L1_LINE = 32           // bytes/line (256-bit packed line)
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- core side (the same-cycle-ack contract; mirrors core mem_*) ----------
    input  logic        c_req,
    input  logic        c_we,
    input  logic [31:0] c_addr,
    input  logic [31:0] c_wdata,
    input  logic [3:0]  c_wstrb,
    output logic [31:0] c_rdata,
    output logic        c_ack,

    // ---- backing side (BFM now; AXI4 master → PS-DDR later) -------------------
    output logic        m_req,
    output logic        m_we,
    output logic [31:0] m_addr,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_wstrb,
    input  logic [31:0] m_rdata,
    input  logic        m_ack
);

  localparam int LW = L1_LINE*8;         // 256 line bits
  localparam int WORDS = L1_LINE/4;      // 8 words/line

  // ---- arrays ----------------------------------------------------------------
  // Data: packed 256-bit lines, flat {set,way} index → distributed RAM (async
  // read for the same-cycle hit). tag/val/lru: 2-way LRU (== dcache_timing).
  (* ram_style = "distributed" *)
  logic [LW-1:0] dc_line [L1_SETS*2];
  logic [19:0]   dc_tag  [L1_SETS][2];   // addr[31:12]
  logic          dc_val  [L1_SETS][2];
  logic          dc_lru  [L1_SETS];      // way most-recently-used

  // ---- combinational lookup off the registered arrays (PRE-update) ----------
  logic [6:0]  set_c; logic [19:0] tag_c;
  logic        hit0, hit1, hit; logic hit_way;
  assign set_c   = c_addr[11:5];
  assign tag_c   = c_addr[31:12];
  assign hit0    = dc_val[set_c][0] && dc_tag[set_c][0]==tag_c;
  assign hit1    = dc_val[set_c][1] && dc_tag[set_c][1]==tag_c;
  assign hit     = hit0 || hit1;
  assign hit_way = hit1;                 // way 1 iff way0 misses (assumes hit)

  // addressed line read (the hit way) + the addressed word within it.
  logic [LW-1:0] rd_line;
  logic [2:0]    word_c;
  assign rd_line = dc_line[{set_c, hit_way}];
  assign word_c  = c_addr[4:2];

  // ---- fill FSM --------------------------------------------------------------
  typedef enum logic [1:0] { L1_IDLE, L1_FILL, L1_DONE } l1_state_e;
  l1_state_e   st;
  logic [2:0]  fw;                       // fill word counter 0..7
  logic [6:0]  fset; logic fway; logic [19:0] ftag;
  logic [31:0] fbase;                    // line base address of the miss

  // backing-side drive: during a FILL, burst-read the 8 line words; on a
  // write-through (IDLE), pass the core write straight to the backing.
  always_comb begin
    m_req=1'b0; m_we=1'b0; m_addr=32'd0; m_wdata=32'd0; m_wstrb=4'd0;
    if (st==L1_FILL) begin
      m_req  = 1'b1; m_we = 1'b0;
      m_addr = {fbase[31:5], 5'd0} + {27'd0, fw, 2'b00};
    end else if (st==L1_IDLE && c_req && c_we) begin
      // write-through: forward the core write to the backing verbatim.
      m_req=1'b1; m_we=1'b1; m_addr=c_addr; m_wdata=c_wdata; m_wstrb=c_wstrb;
    end
  end

  // core-side response: HIT (read) returns combinationally; a write acks with the
  // backing; a read miss deasserts c_ack and kicks the fill (handled in the FF).
  always_comb begin
    c_rdata = rd_line[{word_c,5'b00000} +: 32];   // addressed word of the hit line
    c_ack   = 1'b0;
    if (c_req) begin
      if (c_we)            c_ack = m_ack;          // write-through ack = backing ack
      else if (hit && st==L1_IDLE) c_ack = 1'b1;   // read hit: same-cycle
      // read miss: c_ack stays 0 (core stalls) until the fill completes + retries.
    end
  end

  // ---- sequential: fill sequencing + array writes ---------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st<=L1_IDLE; fw<=3'd0;
      for (int s=0;s<L1_SETS;s++) begin
        dc_lru[s]<=1'b0; dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0;
        dc_tag[s][0]<=20'd0; dc_tag[s][1]<=20'd0;
      end
    end else begin
      unique case (st)
        L1_IDLE: begin
          if (c_req && !c_we && !hit) begin
            // read MISS → start a line fill into the not-MRU victim way.
            fset  <= set_c;  fway <= ~dc_lru[set_c];  ftag <= tag_c;
            fbase <= c_addr;  fw <= 3'd0;
            st    <= L1_FILL;
          end else if (c_req && !c_we && hit) begin
            // read HIT → 2-way LRU touch (mark the hit way MRU).
            dc_lru[set_c] <= hit_way;
          end else if (c_req && c_we && hit && m_ack) begin
            // write HIT (write-through) → update the array word (byte strobes) +
            // LRU touch. The backing already saw the write via the comb driver.
            // Read-modify-write the addressed 32-bit word: keep the old byte where
            // the strobe is 0, take c_wdata where it is 1.
            logic [31:0] oldw, neww;
            oldw = dc_line[{set_c,hit_way}][{word_c,5'b00000} +: 32];
            for (int b=0;b<4;b++)
              neww[b*8 +: 8] = c_wstrb[b] ? c_wdata[b*8 +: 8] : oldw[b*8 +: 8];
            dc_line[{set_c,hit_way}][{word_c,5'b00000} +: 32] <= neww;
            dc_lru[set_c] <= hit_way;
          end
        end
        L1_FILL: begin
          if (m_ack) begin
            // capture the returned word into the victim line.
            dc_line[{fset,fway}][{fw,5'b00000} +: 32] <= m_rdata;
            if (fw==3'(WORDS-1)) begin
              // last word → allocate the victim (tag/val) + MRU, then retry hits.
              dc_tag[fset][fway]<=ftag; dc_val[fset][fway]<=1'b1; dc_lru[fset]<=fway;
              st<=L1_DONE;
            end else fw<=fw+3'd1;
          end
        end
        L1_DONE: begin
          // one settle clock so the just-written line is visible to the comb read
          // before the core's retry samples the hit. Then back to serving.
          st<=L1_IDLE;
        end
        default: st<=L1_IDLE;
      endcase
    end
  end

endmodule : ven_l1d
