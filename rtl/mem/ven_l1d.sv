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

    // ---- #35 external invalidation: clear ALL valid bits (a conservative flush)
    // for the cosim — the int-0x80 proxy / syscall emulator writes the backing
    // MemModel DIRECTLY (bypassing the L1), so without this a re-read after a
    // syscall-filled buffer (Quake) would hit a STALE cached line. Pulse flush_all
    // after each such write; the next reads miss and refill from the backing. On
    // real HW the HPC0 CCI snoop covers AXI writes; tied 0 in modes 0/1.
    input  logic        flush_all,

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

  // ---- next-line lookup: a 4-byte access whose bytes cross the 32-byte line end
  // (c_addr[4:0] > 28) needs the NEXT line too. The core's mem port is byte-
  // addressable (the BFM reads 4 bytes at any byte addr — e.g. a slow-path S_FETCH
  // of an instruction that straddles a line boundary), so the L1 must serve such
  // reads from {next_line, line}. For a read to HIT, BOTH lines must be resident;
  // a miss fills whichever line is missing (L first, then L+1).
  logic [31:0] addr_n;
  logic [6:0]  set_n; logic [19:0] tag_n;
  logic        hit_n0, hit_n1, hit_n, hit_way_n, xline, rd_hit;
  assign addr_n    = c_addr + 32'd32;          // the next 32-byte line
  assign set_n     = addr_n[11:5];
  assign tag_n     = addr_n[31:12];
  assign hit_n0    = dc_val[set_n][0] && dc_tag[set_n][0]==tag_n;
  assign hit_n1    = dc_val[set_n][1] && dc_tag[set_n][1]==tag_n;
  assign hit_n     = hit_n0 || hit_n1;
  assign hit_way_n = hit_n1;
  assign xline     = (c_addr[4:0] > 5'd28);    // 4-byte access spills into the next line
  assign rd_hit    = hit && (!xline || hit_n); // a READ hits iff both needed lines resident

  // addressed line read (the hit way) + the BYTE offset within it. The core's mem
  // port is BYTE-addressable (the sim BFM reads the 4 bytes starting at the exact
  // byte address — e.g. an unaligned slow-path S_FETCH at the instruction address),
  // so the L1 must extract the 4 bytes at c_addr[4:0], NOT the aligned word at
  // c_addr[4:2]. (Aligned accesses — every L1D/L1AXI gate read + the line fill — have
  // c_addr[1:0]=0, so {boff,3'b0} == {word_c,5'b0} and they are unchanged.) A read
  // whose 4 bytes cross the 32-byte line end (c_addr[4:0] > 28) is NOT handled here
  // (it would need the next line too) — see the cross-line note in P1-1.
  logic [LW-1:0] rd_line, rd_line_next;
  logic [4:0]    boff;
  assign rd_line      = dc_line[{set_c, hit_way}];
  assign rd_line_next = dc_line[{set_n, hit_way_n}];   // the L+1 line (for a cross-line read)
  assign boff         = c_addr[4:0];

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
    // 4 bytes at the addressed byte offset, from the {L+1, L} window so a read that
    // crosses the line end (boff > 28) takes its high bytes from the next line.
    c_rdata = {rd_line_next, rd_line}[{1'b0,boff,3'b000} +: 32];
    c_ack   = 1'b0;
    if (c_req) begin
      if (c_we)            c_ack = m_ack;          // write-through ack = backing ack
      else if (rd_hit && st==L1_IDLE) c_ack = 1'b1; // read hit (both needed lines): same-cycle
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
          if (c_req && !c_we && !rd_hit) begin
            // read MISS → fill the MISSING line into its not-MRU victim way. On a
            // xline-line read where L is resident but L+1 is not, fill L+1; the core
            // holds the request so the retry then fills L (if needed) -> L+1 -> hits.
            if (!hit) begin
              fset <= set_c; fway <= ~dc_lru[set_c]; ftag <= tag_c; fbase <= c_addr;
            end else begin            // hit_L but xline && !hit_n -> fill the next line
              fset <= set_n; fway <= ~dc_lru[set_n]; ftag <= tag_n; fbase <= addr_n;
            end
            fw <= 3'd0;  st <= L1_FILL;
          end else if (c_req && !c_we && rd_hit) begin
            // read HIT → 2-way LRU touch (both lines on a xline-line hit).
            dc_lru[set_c] <= hit_way;
            if (xline) dc_lru[set_n] <= hit_way_n;
          end else if (c_req && c_we) begin
            // WRITE (write-through). The backing received the full byte-accurate store
            // via the comb driver (ven_axi_master splits a cross-word / cross-line
            // store into per-word AXI beats); the core STALLS (c_ack=m_ack, below)
            // until that completes, so committing the array now is correct and robust
            // to multi-cycle backing latency. Keep the cached copy coherent:
            logic [31:0] oldw, neww;
            if (xline) begin
              // cross-LINE store (4 bytes span the 32-byte line end): the within-line
              // array RMW cannot cross the boundary, so INVALIDATE every RESIDENT line
              // the store touches -> a re-read refills the full, correct data from the
              // backing. This MUST run even when the ADDRESSED line missed (hit==0):
              // the spilled HIGH bytes land in the NEXT line, and if only that next
              // line is resident (hit==0, hit_n==1) its STALE copy would be served by a
              // later cross-line read. This was the FreeDOS __call16 iret-frame
              // corruption: a `pushl` to ...x7E spilled the return CS into a resident
              // next line that was never updated, so the iret popped CS=0 and derailed.
              if (hit)   begin dc_val[set_c][hit_way]   <= 1'b0; dc_lru[set_c] <= hit_way; end
              if (hit_n) dc_val[set_n][hit_way_n] <= 1'b0;
            end else if (hit) begin
              // within-line write HIT → RMW the 4 bytes at the addressed BYTE offset
              // (boff): keep the old byte where the strobe is 0, take c_wdata where 1.
              // Decoupled from the backing ack (the core cannot re-read during its own
              // stalled write); idempotent across a multi-clock backing write.
              dc_lru[set_c] <= hit_way;
              oldw = dc_line[{set_c,hit_way}][{boff,3'b000} +: 32];
              for (int b=0;b<4;b++)
                neww[b*8 +: 8] = c_wstrb[b] ? c_wdata[b*8 +: 8] : oldw[b*8 +: 8];
              dc_line[{set_c,hit_way}][{boff,3'b000} +: 32] <= neww;
            end
            // (within-line write MISS: no cached copy → nothing to update; write-through.)
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
      // #35 external flush: clear every valid bit (last-write-wins over the case's
      // tag/val writes, so an invalidation always takes priority). The next reads
      // miss + refill the now-current backing. Tags/data are left (val gates them).
      if (flush_all)
        for (int s=0;s<L1_SETS;s++) begin dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0; end
    end
  end

endmodule : ven_l1d
