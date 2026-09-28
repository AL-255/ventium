`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
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
//     forward to the backing; c_ack follows admission to the backing P54C write
//     buffer. (No write-allocate — a write miss does not pull the line;
//     write-back/MESI is a later optimization.)
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

    // ---- golden / "L1-useless" mode (diagnostic): after EVERY completed core
    // transaction, drop all cached state (valid bits + the registered read window)
    // so the NEXT access fully re-fills from the backing and re-captures fresh — no
    // L1 state survives a transaction. Tanks performance (every access misses), but
    // produces a result uncontaminated by L1 line-staleness / read-window bugs: if a
    // fetch corruption PERSISTS with golden=1, the bug is NOT in L1's carried state
    // (it is downstream — the core fetch buffer); if it VANISHES, L1 state was the
    // cause. Runtime bit (MODE.GOLDEN_L1); tied 0 = normal cached operation.
    input  logic        golden,

    // ---- KEN# (cacheability) — the northbridge ven_cachemap decision for THIS
    // access (docs/northbridge-system-spec.md §3). 1 = normal cached operation
    // (the Phase A default at every instantiation). 0 = NON-ALLOCATING BYPASS: the
    // line is never allocated/touched in the array; a read fetches the addressed
    // line into a private buffer and serves the word from there (no pollution), a
    // write goes straight write-through. An uncacheable address has a STABLE PAM
    // attribute, so it is never resident — hence no force-miss of a stale hit is
    // needed (the bypass path simply never consults/installs the array). Tied 1
    // until the cachemap is wired (Phase C), so the default build is byte-identical.
    input  logic        cacheable,

    // ---- per-line snoop INVALIDATE (the EADS#/inquire analogue) — the northbridge
    // pulses this for one clock when a NON-CPU master (DMA / PCI) writes a line that
    // may be cached here, so the next CPU read of it misses and refills the new data
    // (the L1 is write-through, so it is never dirtier than L2 — invalidate suffices,
    // no write-back). Clears the matching {set,way} valid bit if resident; harmless
    // if absent. Tied 0 until DMA is a coherent requester (Phase D) → byte-identical.
    input  logic        snoop_inv_valid,
    input  logic [31:0] snoop_inv_addr,

    // ---- core side (the same-cycle-ack contract; mirrors core mem_*) ----------
    input  logic        c_req,
    input  logic        c_we,
`ifdef VEN_L1D_CODE_BUFFER
    input  logic        c_code, // physical instruction-fill beat, never a data operand
`endif
    input  logic [31:0] c_addr,
    input  logic [31:0] c_wdata,
    input  logic [3:0]  c_wstrb,
    output logic [31:0] c_rdata,
    output logic        c_ack,
`ifdef VEN_P54_DUAL_STORE_PAIR
    // A checked younger store to a different 32-bit bank in the same resident
    // line. Both stores are admitted by the backing write buffers on one edge.
    input  logic        c_pair_req,
    input  logic [31:0] c_pair_addr,
    input  logic [31:0] c_pair_wdata,
    input  logic [3:0]  c_pair_wstrb,
    output logic        c_pair_ready,
    output logic        c_pair_ack,
`endif
`ifdef VEN_PIPE_MEM_CHAIN
    // Independent next-request address. The old c_addr/c_ack/rdata retain
    // their owner until the commit edge; next_ready never depends on commit.
    input  logic        c_next_req, c_next_commit, c_next_cacheable,
    input  logic [31:0] c_next_addr,
    input  logic [3:0]  c_next_wstrb,
    output logic        c_next_ready,
`endif
`ifdef VEN_FP_LOAD64
    // High half of the SAME owned, registered response, not another request.
    // Valid only for a complete resident 8-byte extent in one physical line.
    output logic [31:0] c_rdata_hi,
    output logic        c_rdata_hi_valid,
`endif
`ifdef VEN_L1D_HIT_STREAM
    // Experimental resident-read interface, NOT yet connected to core issue.
    // In stream mode c_req/c_addr describe a NEW request; acceptance is
    // c_req && c_req_ready. c_rdata/c_rsp_addr describe the independently held
    // response; c_ack is its consume edge (c_rsp_valid && c_rsp_ready).
    // Only cacheable, non-crossing dword hits are accepted. A rejected request
    // causes no backing access or LRU change. Drain responses before leaving
    // stream mode; misses/MMIO/stores then use the unchanged legacy protocol.
    // Flush/snoop/golden cancels the pending response explicitly; caller must
    // replay its owner, never retire the canceled data. No speculative MMIO.
    input  logic        c_hit_stream,
    output logic        c_req_ready,
    output logic        c_rsp_valid,
    input  logic        c_rsp_ready,
    output logic [31:0] c_rsp_addr,
    output logic        c_rsp_cancel,
`endif
`ifdef VEN_P54_DUAL_HIT
    // Checked, cacheable hit-only U/V read port. Rejected requests have no
    // effect; the caller must retry a miss/split through the legacy owner path.
    input  logic [1:0]       pair_req_valid,
    input  logic [1:0]       pair_cacheable,
    input  logic [1:0][31:0] pair_paddr,
    input  logic [1:0][1:0]  pair_size_log2,
    input  logic [1:0][15:0] pair_owner,
    output logic [1:0]       pair_req_ready,
    output logic [1:0]       pair_req_split,
    output logic             pair_bank_conflict,
    output logic [1:0]       pair_rsp_valid,
    output logic [1:0]       pair_rsp_cancel,
    input  logic [1:0]       pair_rsp_ready,
    output logic [1:0][15:0] pair_rsp_owner,
    output logic [1:0][31:0] pair_rsp_paddr,
    output logic [1:0][31:0] pair_rsp_data,
`endif
    // VEN DIAG (load-serve forensics): expose the read-serve hit state so the dbg ring can show WHY a
    // load got its data. {1'b0,st[1:0],flush_all,rd_match,hit_way,hit1,hit0} sampled at the current request.
    output logic [7:0]  dbg_serve,

    // ---- backing side (BFM now; AXI4 master → PS-DDR later) -------------------
    output logic        m_req,
    output logic        m_we,
    output logic [31:0] m_addr,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_wstrb,
    input  logic [31:0] m_rdata,
`ifdef VEN_P54_DUAL_STORE_PAIR
    output logic        m_pair_req,
    output logic [31:0] m_pair_addr,
    output logic [31:0] m_pair_wdata,
    output logic [3:0]  m_pair_wstrb,
    input  logic        m_pair_ready,
    input  logic        m_pair_ack,
`endif
    // REVIEW2_aug2 H-11: tell the backing this READ is NARROW -- NOT a 32-byte
    // line fill. See the H-11 note below for why an amplified non-cacheable read
    // is an MMIO CORRECTNESS bug.
    // REVIEW1_Aug3 R2-H01: m_rd_size carries the current piece's size (AXI ARSIZE
    // encoding: 0=1B, 1=2B, 2=4B); each beat is its own single-beat transaction
    // at a byte-exact address, so a device read touches exactly its own bytes.
    output logic        m_rd_narrow,
    output logic [1:0]  m_rd_size,
    input  logic        m_ack
);

  localparam int LW = L1_LINE*8;         // 256 line bits
  localparam int WORDS = L1_LINE/4;      // 8 words/line
  // REVIEW2 M-04: DERIVED geometry. The set-index / tag split was hard-coded as
  // [11:5] and [31:12], so overriding L1_SETS indexed dc_tag/dc_val past their end AND
  // split the address at the wrong bit -- silently wrong data, not a compile error.
  // These make the split follow the parameter instead.
  localparam int OFFW  = $clog2(L1_LINE);              // 5 for 32-byte lines
  localparam int IDXW  = $clog2(L1_SETS);              // 7 for 128 sets
  localparam int TAGW  = 32 - OFFW - IDXW;             // 20 for the 128x32 geometry

  // ---- arrays ----------------------------------------------------------------
  // Data: packed 256-bit lines, flat {set,way} index → distributed RAM (async
  // read for the same-cycle hit). tag/val/lru: 2-way LRU (== dcache_timing).
`ifdef VEN_L1D_BANKED_DATA
  // Eight independent word banks hold the same 8 KiB. Each generated bank
  // owns a 256x32 array and one byte-enabled write port; a multidimensional
  // dc_bank[bank][row] with dynamic bank writes does NOT infer Xilinx RAM.
  logic bank_fill_we, bank_store_we;
`ifdef VEN_P54_DUAL_STORE_PAIR
  logic bank_pair_store_we;
  assign bank_pair_store_we = bank_store_we && c_pair_req && c_pair_ready &&
                              m_pair_ack;
`endif
  assign bank_fill_we = rst_n && (st == L1_FILL) && m_ack && !bypass_q
`ifdef VEN_L1D_CODE_BUFFER
      && !code_fill_q
`endif
      ;
  assign bank_store_we = rst_n && (st == L1_IDLE) && !mc_lookup_next &&
      !stream_path && c_req && c_we && c_ack && !xline && hit;
`else
  (* ram_style = "distributed" *)
  logic [LW-1:0] dc_line [L1_SETS*2];
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
`ifndef VEN_L1D_BANKED_DATA
  initial $fatal(1, "VEN_P54_DUAL_STORE_PAIR requires banked L1D data");
`endif
  // Limiting this first admission class to one resident physical line makes
  // U's tag/cacheability decision valid for V as well. No second tag RAM read,
  // replacement decision, or noncacheable/MMIO side effect is guessed here.
  assign c_pair_ready = rst_n && c_req && c_we && cacheable && !golden &&
      !flush_all && !snoop_inv_valid && (st == L1_IDLE) &&
      m_pair_ready &&
      !mc_lookup_next && !stream_path && hit && !xline &&
      (c_addr[31:5] == c_pair_addr[31:5]) &&
      (c_addr[1:0] == 2'd0) && (c_pair_addr[1:0] == 2'd0) &&
      (c_addr[4:2] != c_pair_addr[4:2]) &&
      (c_wstrb == 4'hf) && (c_pair_wstrb == 4'hf);
  assign c_pair_ack = c_pair_req && c_pair_ready && c_ack && m_pair_ack;
`endif
  logic [TAGW-1:0] dc_tag [L1_SETS][2];  // addr[31 -: TAGW]
  logic          dc_val  [L1_SETS][2];
  logic          dc_lru  [L1_SETS];      // way most-recently-used

`ifdef VEN_P54_DUAL_HIT_LEGACY_CAPTURE
`ifndef VEN_P54_DUAL_HIT
  initial $fatal(1, "legacy-capture pair requires VEN_P54_DUAL_HIT");
`endif
`endif
`ifdef VEN_P54_DUAL_HIT
`ifndef VEN_L1D_BANKED_DATA
  initial $fatal(1, "VEN_P54_DUAL_HIT requires VEN_L1D_BANKED_DATA");
`endif
  logic pair_lookup_active;
  logic [1:0][IDXW-1:0] pair_set;
  logic [1:0][TAGW-1:0] pair_tag;
  logic [1:0] pair_hit0, pair_hit1, pair_way, pair_hit;
  logic [1:0][7:0] pair_bank_mask;
  logic [1:0][31:0] pair_read_data;
  logic [7:0] pair_bank_ready;
  logic pair_legacy_overlap;
`ifdef VEN_P54_DUAL_HIT_LEGACY_CAPTURE
`ifdef VEN_L1D_COMB_ACK
  initial $fatal(1, "legacy-capture pair requires registered L1 responses");
`endif
  // A new aligned U hit still uses the ordinary registered response window.
  // Its one word bank is reserved while the otherwise idle banks may capture
  // ONE younger V owner. Rejection leaves U's existing read path unchanged.
  // Do not admit an instruction fill, an unrelated next-read lookahead, or a
  // held response. The separately checked prime path below is an exception.
  logic pair_legacy_capture;
  logic [2:0] pair_reserved_bank;
`ifdef VEN_P54_DUAL_LOAD_PRIME
`ifndef VEN_PIPE_REG_LOAD_PRIME
  initial $fatal(1, "dual-load prime needs registered load priming");
`endif
  // A branch/register predecessor can capture the next U from c_next_addr.
  // The primed U owns its bank exactly like an ordinary fresh capture; only
  // an independent V bank may be read on that edge. Do not open the pair port
  // for a rejected speculative next lookup or an uncommitted predecessor.
  logic pair_prime_capture;
  assign pair_prime_capture = (pair_req_valid == 2'b10) && mc_lookup_prime &&
      mc_capture_next && !golden && (c_next_wstrb == 4'hf) &&
      (c_next_addr[1:0] == 2'd0) && (c_next_addr[4:0] <= 5'd28);
  assign pair_reserved_bank = pair_prime_capture ? c_next_addr[4:2] : c_addr[4:2];
`else
  wire pair_prime_capture = 1'b0;
  assign pair_reserved_bank = c_addr[4:2];
`endif
  logic pair_arb_conflict;
  assign pair_legacy_capture = (pair_req_valid == 2'b10) &&
      c_req && !c_we && cacheable && !golden && !rd_armed &&
      (st == L1_IDLE) && !mc_lookup_next && !early_armed && !stream_path &&
      (c_wstrb == 4'hf) && (c_addr[1:0] == 2'd0) &&
      (c_addr[4:0] <= 5'd28) && do_rd_cap
`ifdef VEN_L1D_CODE_BUFFER
      && !code_access
`endif
      ;
  assign pair_bank_conflict = pair_arb_conflict ||
      ((pair_legacy_capture || pair_prime_capture) && pair_req_valid[1] &&
       !pair_req_split[1] &&
       pair_bank_mask[1][pair_reserved_bank]);
`else
  wire pair_legacy_capture = 1'b0;
  wire pair_prime_capture = 1'b0;
  wire [2:0] pair_reserved_bank = 3'd0;
`endif
  // A registered legacy read response is served from rd_window_q, not from
  // the data-bank read ports. Admit a new pair on its consume edge, provided
  // the old address/ACK still match and the separate single-next lookahead
  // is not using those banks. A new legacy capture, write, bypass or held
  // unmatched response retains exclusive ownership. The optional fresh-U
  // path above reserves U's bank and never shares its registered result.
`ifdef VEN_L1D_COMB_ACK
  // The cosim-only combinational response still reads the live banks.
  assign pair_legacy_overlap = 1'b0;
`else
  assign pair_legacy_overlap = c_req && !c_we && rd_match && c_ack && cacheable;
`endif
  assign pair_lookup_active = (|pair_req_valid) && (st == L1_IDLE) &&
      (((!c_req && !rd_armed) && !mc_lookup_next) ||
       (pair_legacy_overlap && !mc_lookup_next) || pair_legacy_capture ||
       pair_prime_capture) &&
      !early_armed && !stream_path &&
      !flush_all && !snoop_inv_valid && !golden;
  assign pair_bank_ready = pair_lookup_active ?
      ((pair_legacy_capture || pair_prime_capture) ?
       ~(8'b1 << pair_reserved_bank) :
       8'hff) : 8'h00;
  for (genvar lane = 0; lane < 2; lane++) begin : g_pair_tags
    assign pair_set[lane] = pair_paddr[lane][OFFW +: IDXW];
    assign pair_tag[lane] = pair_paddr[lane][OFFW+IDXW +: TAGW];
    assign pair_hit0[lane] = dc_val[pair_set[lane]][0] &&
                             dc_tag[pair_set[lane]][0] == pair_tag[lane];
    assign pair_hit1[lane] = dc_val[pair_set[lane]][1] &&
                             dc_tag[pair_set[lane]][1] == pair_tag[lane];
    assign pair_way[lane] = pair_hit1[lane];
    assign pair_hit[lane] = pair_lookup_active && pair_cacheable[lane] &&
                            (pair_hit0[lane] || pair_hit1[lane]) &&
                            (pair_size_log2[lane] != 2'd3);
  end
  ven_p54_hit_return u_pair_return (
      .clk, .rst_n,
      .flush(flush_all || snoop_inv_valid || golden),
      .req_valid(pair_req_valid), .req_hit(pair_hit),
      .req_owner(pair_owner), .req_paddr(pair_paddr),
      .req_size_log2(pair_size_log2), .req_data(pair_read_data),
      .bank_ready(pair_bank_ready), .req_ready(pair_req_ready),
      .req_split(pair_req_split), .req_bank_mask(pair_bank_mask),
`ifdef VEN_P54_DUAL_HIT_LEGACY_CAPTURE
      .bank_conflict(pair_arb_conflict), .rsp_valid(pair_rsp_valid),
`else
      .bank_conflict(pair_bank_conflict), .rsp_valid(pair_rsp_valid),
`endif
      .rsp_cancel(pair_rsp_cancel), .rsp_ready(pair_rsp_ready),
      .rsp_owner(pair_rsp_owner), .rsp_paddr(pair_rsp_paddr),
      .rsp_data(pair_rsp_data));
`endif

  // REVIEW2 M-04: this module ADVERTISED L1_SETS/L1_LINE but hard-coded seven set-index
  // bits [11:5], a 20-bit tag [31:12] and offset bit 5, so overriding L1_SETS indexed
  // dc_tag/dc_val past their end AND split the address at the wrong bit -- silently
  // wrong data, not a compile error.
  //
  // FIXED for L1_SETS: the split is now derived (OFFW/IDXW/TAGW above) and every set/
  // tag reference follows the parameter, so 64/128/256 sets all index and tag
  // correctly. That is the half the review's hazard was about ("overriding the
  // parameter to 64 can index beyond the array and uses the wrong tag split").
  //
  // STILL PINNED for L1_LINE: the line geometry is woven through the byte-select
  // datapath, not just the address split. Guarded below.
  initial begin
    // L1_SETS is now HONOURED: the set/tag split is derived above, so 64/128/256 all
    // index correctly and tag the right bits. It must still be a power of two, since
    // $clog2 is what makes the split exact.
    if ((L1_SETS & (L1_SETS-1)) != 0 || L1_SETS < 2)
      $fatal(1, "ven_l1d: L1_SETS=%0d must be a power of two >= 2 (the set/tag split is derived with $clog2).", L1_SETS);
    // L1_LINE is still PINNED. Unlike the set/tag split, the line geometry is woven
    // through the byte-select datapath -- the 32-byte read window, the bypass line
    // extract, the 8-beat fill loop and the within-line store offset all assume 5
    // offset bits. Refuse to elaborate rather than let it be found as corrupted data.
    if (L1_LINE != 32)
      $fatal(1, "ven_l1d: L1_LINE=%0d unsupported -- the byte-select datapath assumes 32-byte lines / 5 offset bits (REVIEW2 M-04, remaining half).", L1_LINE);
  end

  // ---- combinational lookup off the registered arrays (PRE-update) ----------
  logic [IDXW-1:0] set_c; logic [TAGW-1:0] tag_c;
  logic        hit0, hit1, hit; logic hit_way;
  logic mc_lookup_next, mc_lookup_old, mc_lookup_prime, mc_capture_next;
  logic [31:0] lookup_addr;
  logic [3:0] lookup_wstrb;
`ifdef VEN_PIPE_MEM_CHAIN
`ifdef VEN_L1D_COMB_ACK
  initial $fatal(1, "VEN_PIPE_MEM_CHAIN requires registered L1 responses");
`endif
  assign mc_lookup_old = c_next_req && c_req && !c_we && rd_match &&
      (st == L1_IDLE) && !early_armed && !stream_path;
`ifdef VEN_PIPE_REG_LOAD_PRIME
  assign mc_lookup_prime = c_next_req && !c_req && !rd_armed &&
      (st == L1_IDLE) && !early_armed && !stream_path;
`else
  assign mc_lookup_prime = 1'b0;
`endif
  assign mc_lookup_next = mc_lookup_old || mc_lookup_prime;
  assign lookup_addr = mc_lookup_next ? c_next_addr : c_addr;
  assign lookup_wstrb = mc_lookup_next ? c_next_wstrb : c_wstrb;
  assign c_next_ready = mc_lookup_next && c_next_cacheable &&
      (mc_lookup_prime || cacheable) &&
      !golden && !flush_all && !snoop_inv_valid && hit &&
      ((c_next_wstrb == 4'b0001) ||
       ((c_next_wstrb == 4'b1111) && c_next_addr[4:0] <= 5'd28));
  assign mc_capture_next = c_next_ready && c_next_commit;
`else
  assign mc_lookup_next = 1'b0;
  assign mc_lookup_old = 1'b0;
  assign mc_lookup_prime = 1'b0;
  assign mc_capture_next = 1'b0;
  assign lookup_addr = c_addr;
  assign lookup_wstrb = c_wstrb;
`endif
  assign set_c   = lookup_addr[OFFW +: IDXW];
  assign tag_c   = lookup_addr[OFFW+IDXW +: TAGW];
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
  logic [IDXW-1:0] set_n; logic [TAGW-1:0] tag_n;
  logic        hit_n0, hit_n1, hit_n, hit_way_n, xline, rd_hit;
`ifdef VEN_L1D_CODE_BUFFER
  // One physical I-line staging buffer. The upstream I-cache retains code;
  // this is only its fill source and never participates in D-cache replacement.
  logic code_access, code_hit, code_valid_q, code_fill_q;
  logic [26:0] code_line_tag_q;
  logic [LW-1:0] code_line_q;
  // Aligned 4-byte reads cannot cross the 32-byte line. Use the live c_addr,
  // not xline/lookup_addr: the latter can be redirected by mc_lookup_next,
  // which itself depends on the owned rd_match response (comb-loop hazard).
  // The core's instruction-fill arms leave read strobes at zero (the legacy
  // cacheable-read convention); explicit full-word reads use 4'hf. Both mean
  // one aligned dword here. Narrow nonzero strobes remain on the D path.
  assign code_access = c_code && !c_we && cacheable && !golden &&
      (c_addr[1:0] == 2'd0) && ((c_wstrb == 4'h0) || (c_wstrb == 4'hf));
  assign code_hit = code_access && code_valid_q &&
      (code_line_tag_q == c_addr[31:5]);
`endif
  assign addr_n    = lookup_addr + 32'd32;     // the next 32-byte line
  assign set_n     = addr_n[OFFW +: IDXW];
  assign tag_n     = addr_n[OFFW+IDXW +: TAGW];
  assign hit_n0    = dc_val[set_n][0] && dc_tag[set_n][0]==tag_n;
  assign hit_n1    = dc_val[set_n][1] && dc_tag[set_n][1]==tag_n;
  assign hit_n     = hit_n0 || hit_n1;
  assign hit_way_n = hit_n1;
  // The line-spill test uses the access's REAL extent (highest active strobe),
  // not a blanket 4 bytes: a byte/word access near a line end whose strobes do
  // not cross must not pull in the next line. With the blanket form a byte
  // read at offset 31 filled L+1 even though it never touches it -- and when
  // L+1 lies in a hole/disabled-PAM region (the boundary is line-aligned) the
  // fill DDR-aliases that region into the cache with no route error. The +3
  // whole-word form survives only for a zero-strobe legacy producer.
  logic [2:0] c_x_hi;
  always_comb begin
    c_x_hi = 3'd0;
    for (int b = 0; b < 4; b++) if (lookup_wstrb[b]) c_x_hi = 3'(b);
  end
  assign xline     = ({1'b0, lookup_addr[4:0]}
                      + ((c_we || lookup_wstrb != 4'd0) ? {3'd0, c_x_hi} : 6'd3)) > 6'd31;
  // ---- REVIEW1_Aug2 H-07: a non-cacheable READ must not be served from the array ---
  // NOT FIXED. The analysis below is correct and the fix attempt is recorded because it
  // failed in an instructive way.
  // Under VEN_L1_HONOR_CD the bypass-read FSM is disabled (it deadlocks in the
  // full-core+bridge context -- a measured claim recorded at the L1_IDLE arm), and the
  // comment there argues the allocating path is "correct (returns the fresh line)".
  // That is true of a read MISS and false of a read HIT: rd_hit is computed from the
  // array regardless of `cacheable`, so a still-resident line served CACHED data after
  // CD was set -- stale pre-CD RAM, and for a cache-mapped MMIO region a suppressed
  // read side effect. That is the half of H-07 that is a correctness bug rather than a
  // performance one.
  //
  // Suppressing the HIT sends the access down the ordinary allocating fill, which
  // fetches the line from memory and therefore returns FRESH data. It does not fix the
  // allocation itself -- MMIO read side effects are still duplicated by the burst, and
  // that needs the bypass FSM the review asks for -- but it removes the stale-data
  // path without touching the FSM that is documented to hang.
  //
  // Only under VEN_L1_HONOR_CD: with the bypass enabled (the default build) a
  // non-cacheable read already takes L1_BYP and never consults rd_hit for service.
  // MEASURED, not reasoned: gating this on `cacheable` under VEN_L1_HONOR_CD -- the
  // obvious fix, and the one that removes the stale-data path -- DEADLOCKS. The access
  // is routed to the fill, but the post-fill serve consults rd_hit too, and rd_hit is
  // still suppressed because `cacheable` is still 0, so the read never acks:
  //     [9c] ... FAIL nc read of resident line is FRESH: got 00000000 exp deadbeef
  //          FAIL read 0000509c: no ack
  // That is the same shape the L1_IDLE comment records for the bypass FSM, and it is
  // why H-07 needs an actual SERVE path that does not depend on a cacheable hit --
  // exactly the "non-deadlocking read bypass" the review asks for. Left as the plain
  // array hit; the [9c] case below documents the property a correct fix must satisfy.
  assign rd_hit    =
`ifdef VEN_L1D_CODE_BUFFER
                     code_access ? code_hit :
`endif
                     hit && (!xline || hit_n); // a READ hits iff both needed lines resident

  // addressed line read (the hit way) + the BYTE offset within it. The core's mem
  // port is BYTE-addressable (the sim BFM reads the 4 bytes starting at the exact
  // byte address — e.g. an unaligned slow-path S_FETCH at the instruction address),
  // so the L1 must extract the 4 bytes at c_addr[4:0], NOT the aligned word at
  // c_addr[4:2]. (Aligned accesses — every L1D/L1AXI gate read + the line fill — have
  // c_addr[1:0]=0, so {boff,3'b0} == {word_c,5'b0} and they are unchanged.) A read
  // whose 4 bytes cross the 32-byte line end (c_addr[4:0] > 28) is NOT handled here
  // (it would need the next line too) — see the cross-line note in P1-1.
  logic [LW-1:0]   rd_line, rd_line_next;
  logic [LW-1:0]   rd_line_raw, rd_line_next_raw, fill_forward_line_raw;
  logic [2*LW-1:0] rd_window;                          // {L+1, L} cross-line read window
  logic [4:0]      boff;
  // An opt-in fill-forward response below may capture a word that has already
  // landed in the line currently being allocated.  Its tag is intentionally
  // not valid until the tail drains, so the ordinary `hit_way` mux cannot name
  // it.  The response remains registered through rd_window_q; this selector is
  // only its capture source, never a combinational core-data path.
  logic              fill_forward_hit;
  logic              fill_forward_data_hit;
  logic              fill_forward_code_hit;
  logic [WORDS-1:0]  fill_word_valid;
  logic [LW-1:0]      fill_forward_line;
`ifdef VEN_L1D_BANKED_DATA
`ifdef VEN_L1D_BANK0_SHARED_XLINE
  // A crossing dword consumes banks 7 and 0 of the next line; it never
  // consumes bank 0 of the first line. Share bank 0's one LUTRAM read address
  // instead of inferring a second asynchronous port for that exceptional
  // access. The captured first-line bank 0 is then NOT a complete line, so
  // the full-line reuse/FP high-half qualifiers below must reject it.
  logic bank0_next_read;
  assign bank0_next_read = xline && !fill_forward_hit;
`endif
  for (genvar bank = 0; bank < WORDS; bank++) begin : g_banked_read
    (* ram_style = "distributed" *) logic [31:0] data [L1_SETS*2];
    logic [3:0] wr_mask;
    logic [31:0] wr_data;
    logic [IDXW:0] wr_row;
    logic [4:0] line_byte;
    always_comb begin
      wr_mask = 4'd0;
      wr_data = 32'd0;
      wr_row = bank_fill_we ? {fset, fway} : {set_c, hit_way};
      line_byte = 5'd0;
      if (bank_fill_we && fill_word == 3'(bank)) begin
        wr_mask = 4'hf;
        wr_data = m_rdata;
`ifdef VEN_P54_DUAL_STORE_PAIR
      end else if (bank_pair_store_we &&
                   c_pair_addr[4:2] == 3'(bank)) begin
        // The pair-ready predicate proves aligned, full-word, distinct-bank
        // stores to this same resident row. Each LUTRAM bank still has one
        // physical write port; V owns only its bank on the acceptance edge.
        wr_mask = c_pair_wstrb;
        wr_data = c_pair_wdata;
`endif
      end else if (bank_store_we) begin
        for (int i = 0; i < 4; i++) begin
          line_byte = c_addr[4:0] + 5'(i);
          if (c_wstrb[i] && line_byte[4:2] == 3'(bank)) begin
            wr_mask[line_byte[1:0]] = 1'b1;
            wr_data[8*line_byte[1:0] +: 8] = c_wdata[8*i +: 8];
          end
        end
      end
    end
    always_ff @(posedge clk) begin
      for (int byte_lane = 0; byte_lane < 4; byte_lane++)
        if (wr_mask[byte_lane])
          data[wr_row][8*byte_lane +: 8] <= wr_data[8*byte_lane +: 8];
    end
    // Fill-forward and ordinary U access are mutually exclusive. Select the
    // row BEFORE the bank read so they do not infer two copies/read ports of
    // the entire data array merely to choose one result afterward.
    assign rd_line_raw[32*bank +: 32] = data[
`ifdef VEN_P54_DUAL_HIT
        (pair_req_ready[0] && pair_bank_mask[0][bank]) ?
            {pair_set[0], pair_way[0]} :
        (pair_req_ready[1] && pair_bank_mask[1][bank]) ?
            {pair_set[1], pair_way[1]} :
`endif
`ifdef VEN_L1D_BANK0_SHARED_XLINE
        ((bank == 0) && bank0_next_read) ? {set_n, hit_way_n} :
`endif
        fill_forward_hit ? {fset, fway} : {set_c, hit_way}];
    // A 32-bit legacy read can cross into only word zero of the following
    // line. FP_LOAD64 explicitly rejects the crossing high-half shortcut and
    // retries through the ordinary path. Do not give all eight LUTRAM banks a
    // second async read port for seven words that no response can observe.
    if (bank == 0) begin : g_cross_word
`ifdef VEN_L1D_BANK0_SHARED_XLINE
      assign rd_line_next_raw[31:0] = rd_line_raw[31:0];
`else
      assign rd_line_next_raw[31:0] = data[{set_n, hit_way_n}];
`endif
    end else begin : g_no_cross_word
      assign rd_line_next_raw[32*bank +: 32] = 32'd0;
    end
  end
  assign fill_forward_line_raw = rd_line_raw;
`else
`ifdef VEN_L1D_BANK0_SHARED_XLINE
  initial $fatal(1, "VEN_L1D_BANK0_SHARED_XLINE requires VEN_L1D_BANKED_DATA");
`endif
  assign rd_line_raw = dc_line[{set_c, hit_way}];
  assign rd_line_next_raw = dc_line[{set_n, hit_way_n}];
  assign fill_forward_line_raw = dc_line[{fset, fway}];
`endif
  assign rd_line      =
`ifdef VEN_L1D_CODE_BUFFER
                        code_access ? code_line_q :
`endif
                        fill_forward_hit ? fill_forward_line : rd_line_raw;
  assign rd_line_next = rd_line_next_raw;   // the L+1 line (for a cross-line read)
  assign rd_window    = {rd_line_next, rd_line};       // named temp: xsim can't index a concat
  assign boff         = lookup_addr[4:0];

`ifdef VEN_P54_DUAL_HIT
  for (genvar lane = 0; lane < 2; lane++) begin : g_pair_data
    logic [31:0] first_word, second_word, shifted;
    logic [63:0] two_words;
    logic [2:0] first_bank, second_bank;
    assign first_bank = pair_paddr[lane][4:2];
    assign second_bank = first_bank + 3'd1;
    assign first_word = rd_line_raw[32*first_bank +: 32];
    assign second_word = rd_line_raw[32*second_bank +: 32];
    assign two_words = {second_word, first_word};
    assign shifted = 32'(two_words >> {pair_paddr[lane][1:0], 3'b000});
    assign pair_read_data[lane] = pair_size_log2[lane] == 2'd0 ?
                                  {24'd0, shifted[7:0]} :
                                  pair_size_log2[lane] == 2'd1 ?
                                  {16'd0, shifted[15:0]} : shifted;
  end
`endif

  // ---- PIPELINED READ (timing-closure): register the high-fanout async line read.
  // The async read of dc_line (256-bit-wide distributed RAM, 256 entries) has huge
  // fanout (>1100) and ~49 logic levels through the {set,way} mux — it does not close
  // 40 MHz timing and GLITCHES on silicon (the free-run Quake derail). Registering
  // rd_window into rd_window_q breaks that path (now: eip_reg -> async read -> a FF,
  // then FF -> output mux as two short paths). The core polls mem_ack, so a 1-cycle
  // read latency is fine.
  //
  // CRITICAL: the ack must be GUARDED by an address match. The core does not cleanly
  // "hold addr, wait for ack, then advance" — it can present a NEW c_addr while a prior
  // read's ack (rd_armed) is still asserted (different cache SET, even). A bare
  // `c_ack = rd_armed` then serves rd_window_q (captured for the OLD addr) to the NEW
  // addr -> stale data -> derail. rd_addr_q records which address the window was
  // captured for; we only ack (and suppress re-capture) when it matches the live
  // request, so stale data can NEVER be acked for a mismatched address.
  logic            rd_armed;
  logic [2*LW-1:0] rd_window_q;
  logic [31:0]     rd_addr_q;       // address rd_window_q was captured for
`ifdef VEN_L1D_CODE_BUFFER
  logic            rd_code_q;
`endif
  logic            rd_match;        // captured window is valid for the CURRENT request
  logic            do_rd_cap;
  logic            stream_path;
  logic            window_reuse;
  logic [LW-1:0]   shadow_line_q;
  logic            mc_prime_window_reuse;
`ifdef VEN_FP_LOAD64
  // A fill-forward capture may contain only the requested dword; a later
  // completed fill does not retroactively refresh that saved window.  Record
  // full-line provenance on its capture edge instead of guessing from hit now.
  logic            rd_full_line_q;
  assign c_rdata_hi = shadow_reuse ?
      shadow_line_q[{1'b0,c_addr[4:0],3'b000} + 9'd32 +: 32] :
      rd_window_q[{1'b0,c_addr[4:0],3'b000} + 9'd32 +: 32];
  assign c_rdata_hi_valid = (L1_LINE == 32) && rst_n && c_req && !c_we &&
      c_ack && (c_wstrb == 4'hf) && cacheable && !golden &&
      !flush_all && !snoop_inv_valid && !stream_path && !early_armed &&
      (st == L1_IDLE) && hit &&
      ((rd_full_line_q && (rd_match || window_reuse) &&
        (c_addr[31:5] == rd_addr_q[31:5])) || shadow_reuse) &&
      (c_addr[4:0] <= 5'd24)
`ifdef VEN_PIPE_MEM_CHAIN
      && !mc_lookup_next
`endif
`ifdef VEN_L1D_COMB_ACK
      && 1'b0 // never attach a registered high half to an asynchronous low half
`endif
      ;
`endif
`ifdef VEN_L1D_WINDOW_REUSE
  // Reuse the first complete resident line of the existing registered window.
  // Require a current hit: this is not an extra cache entry. Never serve MMIO,
  // a crossing, or data captured from an incomplete fill through this path.
  logic window_valid_q;
`ifdef VEN_L1D_TWO_WINDOW_REUSE
`ifdef VEN_L1D_COMB_ACK
  initial $fatal(1, "two-window reuse requires registered L1 responses");
`endif
  // Keep only the previously captured complete line. This is a read buffer,
  // never a cache entry: a current tag hit and the normal window invalidation
  // rules are still required before its bytes can be observed.
  logic [31:5] shadow_line_addr_q;
  logic shadow_valid_q, shadow_reuse;
`ifdef VEN_PIPE_MEM_CHAIN
  // Re-arm a checked prime from the already registered primary line without
  // overwriting it (and hence without throwing away the second hot line).
  // The new owner is still registered; only the redundant SRAM read vanishes.
  assign mc_prime_window_reuse = mc_lookup_prime && c_next_ready &&
      window_valid_q && (c_next_addr[31:5] == rd_addr_q[31:5]);
`else
  assign mc_prime_window_reuse = 1'b0;
`endif
  assign shadow_reuse = shadow_valid_q && !mc_lookup_next && !stream_path &&
      !early_armed && (st == L1_IDLE) && c_req && !c_we && cacheable &&
      !golden && !flush_all && !snoop_inv_valid && hit &&
      (c_addr[31:5] == shadow_line_addr_q) && (c_addr[4:0] <= 5'd28)
`ifdef VEN_L1D_CODE_BUFFER
      && !code_access
`endif
      ;
`else
  assign mc_prime_window_reuse = 1'b0;
  assign shadow_line_q = '0;
  wire shadow_reuse = 1'b0;
`endif
  assign window_reuse = window_valid_q && !mc_lookup_next && !stream_path && !early_armed &&
`ifdef VEN_L1D_CODE_BUFFER
      !code_access &&
`endif
      (st == L1_IDLE) && c_req && !c_we && cacheable && !golden &&
      !flush_all && !snoop_inv_valid && hit &&
      (c_addr[31:5] == rd_addr_q[31:5]) && (c_addr[4:0] <= 5'd28);
`else
`ifdef VEN_L1D_TWO_WINDOW_REUSE
  initial $fatal(1, "two-window reuse requires VEN_L1D_WINDOW_REUSE");
`endif
  assign window_reuse = 1'b0;
  assign mc_prime_window_reuse = 1'b0;
  assign shadow_line_q = '0;
  wire shadow_reuse = 1'b0;
`endif
`ifdef VEN_L1D_HIT_STREAM
  logic            rd_stream_q;
  // Keep ownership until consumption/cancel, even if the caller attempts to
  // switch back early. The legacy FSM must not overwrite a held response.
  assign stream_path = c_hit_stream || rd_stream_q;
  assign c_rsp_cancel = rd_stream_q && rd_armed &&
                        (flush_all || snoop_inv_valid || golden);
  assign c_rsp_valid = rd_stream_q && rd_armed && !c_rsp_cancel;
  assign c_rsp_addr = rd_addr_q;
  assign c_req_ready = c_hit_stream && (st == L1_IDLE) &&
                       !c_we && cacheable && !golden && !flush_all &&
                       !snoop_inv_valid && !early_armed &&
                       (c_wstrb == 4'hf) && (c_addr[4:0] <= 5'd28) && hit &&
                       (!rd_armed || (rd_stream_q && c_rsp_ready));
`else
  assign stream_path = 1'b0;
`endif
  assign rd_match  = rd_armed && !stream_path && (rd_addr_q == c_addr)
`ifdef VEN_L1D_CODE_BUFFER
      && (rd_code_q == code_access)
`endif
      ;
  // REVIEW Aug-1 H-05: do_rd_cap is derived from the COMBINATIONAL hit, which reads
  // pre-edge tag/valid. If a snoop for that same line lands on the same clock, the
  // array's valid bit is cleared at the edge but the OLD window has already been
  // captured and rd_armed set -- and the next response is served through rd_match,
  // which compares only the ADDRESS and never re-checks current tag/valid. The core
  // then gets acked with pre-DMA data (repro: HIT_SNOOP_RACE stale=11110000
  // backing=22220000). Suppress the capture whenever a snoop is in flight.
  //
  // The window is 2*LW wide (it spans the addressed line AND the next one, for
  // cross-line reads), so a precise per-line comparison would have to cover both.
  // Snoops are rare (DMA bursts), so kill ANY capture during one: cheap, and there
  // is no address arithmetic left to get wrong.
  // REVIEW2 H-18: CR0.CD / KEN# were honoured for WRITES but not for READS. rd_hit is
  // computed from the array regardless of `cacheable`, so a still-resident line served
  // a CACHED HIT even when the access must bypass -- returning pre-CD data, and with
  // the optional cache map, duplicating or suppressing MMIO side effects.
  //
  // bypass_rd_en is the single predicate for "a non-cacheable read takes the L1_BYP
  // path". It gates BOTH this capture and the FSM branch that starts the bypass fill,
  // so the two cannot disagree -- if the capture were gated while the branch was not
  // (or vice versa) a non-cacheable read would either serve stale data or never be
  // served at all. Under VEN_L1_HONOR_CD the bypass FSM is deliberately disabled (see
  // the L1_IDLE arm), so there the capture must stay ungated or the read deadlocks.
// REVIEW1_Aug2 H-07: this was 0 under VEN_L1_HONOR_CD, so a non-cacheable read was
// served from the ARRAY -- returning pre-CD data, and for MMIO duplicating or
// suppressing read side effects. It is now 1 in both builds; see the L1_IDLE arm and
// the c_ack gating below for the two changes that make that non-deadlocking.
  localparam bit BYPASS_RD_EN = 1'b1;
  // A fill owns the sole backing stream until all of its burst beats have
  // drained.  It need not, however, stall an already-resident read in a
  // *different* set: that read uses only the local array and the existing
  // registered response window.  Keep this deliberately narrow while the
  // contract is exercised: no cross-line read (two replacement domains), no
  // same-set read (the fill's terminal LRU write), no bypass, and no new
  // backing operation.  The default remains the conservative one-request
  // policy until the opt-in has full-system evidence.
  logic fill_independent_hit;
`ifdef VEN_L1D_HIT_UNDER_FILL
  assign fill_independent_hit = (st == L1_FILL) && !bypass_q && !xline &&
`ifdef VEN_L1D_CODE_BUFFER
                               !code_fill_q &&
`endif
                               (set_c != fset);
`else
  assign fill_independent_hit = 1'b0;
`endif
  // A critical word can be returned before its line finishes filling, but the
  // historical conservative policy then blocked every subsequent request until
  // all eight backing beats drained.  That turns one miss into a long train of
  // avoidable waits when a load stream reuses words already received in the
  // same line.  VEN_L1D_FILL_FORWARD admits only an aligned-within-line read
  // whose exact physical word has landed in *this* unpoisoned cacheable fill.
  // It neither allocates a tag early nor starts a second backing transaction;
  // the ordinary registered read window owns the response identity.  A flush
  // or matching snoop poisons the transaction and blocks both same-edge and
  // later forwarding, so partially received stale data cannot escape.  The
  // fill owner itself is excluded: without a request ID, holding its address
  // through the critical-response sampling edge is indistinguishable from a
  // new access and must never yield a second acknowledgement.
  assign do_rd_cap =
                     mc_lookup_next ? (mc_capture_next && !mc_prime_window_reuse) :
`ifdef VEN_L1D_HIT_STREAM
                     stream_path ? (c_req && c_req_ready) :
`endif
                     c_req && !c_we && (rd_hit || fill_forward_hit) &&
                     ((st==L1_IDLE) || fill_independent_hit || fill_forward_hit) &&
                     !rd_match && !window_reuse && !shadow_reuse
                     && !snoop_inv_valid
                     && !(BYPASS_RD_EN && !cacheable);   // H-18: CD/KEN# read bypass

  // ---- CRITICAL-WORD-FIRST MISS RESPONSE ------------------------------------
  // A cache-line miss used to hold the core until all eight words had returned,
  // even when the requested aligned dword was already present at the backing
  // port.  For a normal AXI INCR fill that word may arrive anywhere in the line,
  // so releasing it early would either require an unbounded response buffer or
  // serve the wrong word.  Cacheable fills now start an AXI WRAP8 burst at this
  // word (the backing-side address generator below presents the same circular
  // sequence), which makes fill beat zero the requested word.
  //
  // Keep the response REGISTERED.  This is deliberately not VEN_L1D_COMB_ACK:
  // no asynchronous LUTRAM path is reintroduced, and the data arrives from the
  // already-registered AXI R channel.  The fill nevertheless stays active until
  // every remaining beat is consumed and the line is validated.  A later memory
  // request is therefore still backpressured; only independent ALU work after a
  // load can overlap the tail of its fill.
  //
  // The owner check is mandatory.  The core may retarget c_addr while a response
  // is visible, just as the ordinary registered-hit path requires rd_addr_q /
  // rd_match.  Do not acknowledge A's returned word as B.  Flush/snoop wins both
  // on the arrival edge and on the serve edge; a late invalidation may make the
  // line nonresident, but it cannot retroactively change a load already sampled.
  logic            early_armed;
  logic            early_ok_q;
  logic [31:0]     early_addr_q, early_rdata_q;
  logic [3:0]      early_wstrb_q;
`ifdef VEN_L1D_CODE_BUFFER
  logic            early_code_q;
`endif
  logic            early_match;
  assign early_match = early_armed && c_req && !c_we &&
                       (c_addr == early_addr_q) && (c_wstrb == early_wstrb_q)
`ifdef VEN_L1D_CODE_BUFFER
                       && (early_code_q == code_access)
`endif
                       ;
  assign dbg_serve = {1'b0, st[1:0], flush_all, rd_match, hit_way, hit1, hit0};  // mini-ILA: L1D FSM + serve state

  // H-06/H-07: does an in-flight snoop hit the line currently being allocated?
  // fset/ftag are REGISTERED at fill start, so this is a clean compare that does not
  // depend on the (pre-edge) array contents. Bypass fills allocate nothing, so they
  // cannot go stale in the array and are excluded.
  assign snoop_hits_fill = snoop_inv_valid && !bypass_q &&
                           (snoop_inv_addr[OFFW +: IDXW]      == fset) &&
                           (snoop_inv_addr[OFFW+IDXW +: TAGW] == ftag);

  // ---- fill FSM --------------------------------------------------------------
  // L1_BYP: a non-cacheable read has finished its line fetch into bp_line; serve the
  // addressed word for one clock (c_ack below), allocating NOTHING, then back to IDLE.
  // Keep the L1_DONE encoding reserved: it is exposed in the diagnostic state field
  // and retaining the values leaves the deployed L1_BYP encoding stable.  Cacheable
  // fills no longer enter it; the registered rd_window_q capture provides the full
  // post-write settling cycle that L1_DONE predates.
  typedef enum logic [1:0] { L1_IDLE, L1_FILL, L1_DONE, L1_BYP } l1_state_e;
  l1_state_e   st;
  logic [2:0]  fw;                       // fill word counter 0..7
  logic [IDXW-1:0] fset; logic fway; logic [TAGW-1:0] ftag;
  assign fill_forward_line = fill_forward_line_raw;
  // REVIEW Aug-1 H-06/H-07: a line fill is an 8-beat TRANSACTION, but its tag/valid
  // are installed only on the LAST beat. An invalidation arriving during beats 0..6
  // therefore has nothing to match and is silently lost; the last beat then validates
  // a line whose backing store has already changed underneath it (repros:
  // FLUSH_DURING_FILL and SNOOP_DURING_FILL, both stale=11110000 backing=22220000).
  // A same-cycle LAST-beat snoop is lost too: the snoop block's `dc_val[set][way] &&
  // dc_tag[set][way]==tag` guard reads the PRE-EDGE array (nonblocking), which for the
  // line being allocated is still valid=0 -- so the "LAST in the FF so an invalidation
  // wins over a same-cycle allocate" comment does not actually hold for a fill.
  //
  // Make it transactional: latch a poison bit on any flush, or on a snoop matching the
  // line being filled, at any point between start and finish. A poisoned fill still
  // drains its beats on the bus (the AXI transaction must complete) but does NOT
  // validate, so the core misses and refills from the now-current backing.
  logic fill_poison;
  logic snoop_hits_fill;
  logic [31:0] fbase;                    // line base address of the miss
  // A bypass response must be owned by the request that launched it.  fbase
  // already preserves the exact byte address; retain the read extent as well.
  // The core can present a new c_addr while an older response indication is
  // visible (the cache-hit path therefore uses rd_addr_q/rd_match).  Without
  // the equivalent check here, L1_BYP acknowledged the buffered response for A
  // as request B and indexed A's data with B's live byte offset.
  logic [3:0] byp_wstrb_q;
  logic       byp_match;
  assign byp_match = c_req && !c_we && !cacheable &&
                     (c_addr == fbase) && (c_wstrb == byp_wstrb_q);
  // non-cacheable bypass: capture the fetched line into a PRIVATE buffer (not the
  // array) and remember we are bypassing, so the fill commits nothing.
  logic [LW-1:0] bp_line;
  // REVIEW2 H-19: a non-cacheable read at byte offsets 29..31 needs up to 4 bytes from
  // the FOLLOWING line. The bypass buffer held ONE line and the top 32 bits of the
  // window were hard-zeroed, so those reads returned CORRUPT DATA -- in precisely the
  // path intended for MMIO / CR0.CD bypass, where a wrong value is a wrong device
  // access. Fetch the next line's first word in a 9th beat instead of inventing zeros.
  logic [31:0]   bp_hi;      // next line's word 0 (only meaningful when byp_need_hi)
  logic          byp_need_hi;  // this bypass access crosses the line end (H-19; dead under H-11)
  // REVIEW2_aug2 H-11: this bypass access is not word-aligned, so it may span two
  // words and needs a 2-beat narrow burst. This REPLACES byp_need_hi's role: once the
  // fetch is word-shaped rather than line-shaped, "crosses the line end" stops being a
  // special case at all -- the two words are simply contiguous addresses, and whether a
  // 32-byte boundary falls between them is irrelevant to a request that never had a
  // line shape to begin with.
  logic          byp_n2;
  logic          byp_hi_beat;  // the 9th beat is in flight
  // REVIEW1_Aug3 R2-H01: BYTE-EXACT narrow reads. When the core drives read
  // strobes, a non-cacheable read is fragmented into ALIGNED power-of-two pieces
  // (1..3), each its own single-beat AXI transaction at its own ARSIZE -- a
  // device read touches exactly its own bytes, never the adjacent word, and a
  // size-aligned <=4-byte piece can never cross a 4 KiB page (so the first-cut
  // rsplit fragment scheme is superseded). c_wstrb==0 (a producer that does not
  // drive read strobes) keeps the legacy whole-word 1-2 beat form, encoded as
  // 4-byte pieces -- one machinery serves both.
  logic [2:0]  byp_sz;         // architectural bytes (from the strobes; 0 = legacy)
  always_comb begin
    unique case (c_wstrb)
      4'b0001, 4'b0010, 4'b0100, 4'b1000: byp_sz = 3'd1;
      4'b0011, 4'b0110, 4'b1100:          byp_sz = 3'd2;
      4'b0111, 4'b1110:                   byp_sz = 3'd3;
      4'b1111:                            byp_sz = 3'd4;
      default:                            byp_sz = 3'd0;
    endcase
  end
  // the piece table: up to 3 pieces, each {offs, size} window-relative.
  // size encoding matches AXI ARSIZE[1:0]: 0=1B, 1=2B, 2=4B.
  logic [2:0]  byp_cnt_q;
  logic [2:0]  byp_off_q [3];
  logic [1:0]  byp_siz_q [3];
  logic [2:0]  byp_off_c [3];
  logic [1:0]  byp_siz_c [3];
  logic [2:0]  byp_cnt_c;
  always_comb begin
    logic [1:0] o;
    o = c_addr[1:0];
    byp_cnt_c = 3'd1;
    for (int p = 0; p < 3; p++) begin byp_off_c[p] = 3'd0; byp_siz_c[p] = 2'd2; end
    unique case (byp_sz)
      3'd1: begin byp_off_c[0] = {1'b0, o}; byp_siz_c[0] = 2'd0; end
      3'd2: unique case (o)
              2'd0, 2'd2: begin byp_off_c[0] = {1'b0, o}; byp_siz_c[0] = 2'd1; end
              // o==1: bytes {1,2} -- a 2B piece at an odd address is not
              // size-aligned; two 1B pieces instead (same shape as o==3).
              2'd1: begin
                      byp_cnt_c = 3'd2;
                      byp_off_c[0] = 3'd1; byp_siz_c[0] = 2'd0;
                      byp_off_c[1] = 3'd2; byp_siz_c[1] = 2'd0;
                    end
              default: begin
                      byp_cnt_c = 3'd2;
                      byp_off_c[0] = 3'd3; byp_siz_c[0] = 2'd0;
                      byp_off_c[1] = 3'd4; byp_siz_c[1] = 2'd0;
                    end
            endcase
      // A page-split dword can leave a three-byte fragment. It is not the
      // strobe-zero legacy request: touch exactly those bytes, including at
      // odd offsets, using one aligned halfword and one byte.
      3'd3: begin
              byp_cnt_c = 3'd2;
              byp_off_c[0] = {1'b0, o};
              byp_siz_c[0] = o[0] ? 2'd0 : 2'd1;
              byp_off_c[1] = {1'b0, o} + (o[0] ? 3'd1 : 3'd2);
              byp_siz_c[1] = o[0] ? 2'd1 : 2'd0;
            end
      3'd4: unique case (o)
              2'd0: ;   // one 4B piece at 0 (the defaults)
              2'd1: begin
                      byp_cnt_c = 3'd3;
                      byp_off_c[0] = 3'd1; byp_siz_c[0] = 2'd0;
                      byp_off_c[1] = 3'd2; byp_siz_c[1] = 2'd1;
                      byp_off_c[2] = 3'd4; byp_siz_c[2] = 2'd0;
                    end
              2'd2: begin
                      byp_cnt_c = 3'd2;
                      byp_off_c[0] = 3'd2; byp_siz_c[0] = 2'd1;
                      byp_off_c[1] = 3'd4; byp_siz_c[1] = 2'd1;
                    end
              default: begin
                      byp_cnt_c = 3'd3;
                      byp_off_c[0] = 3'd3; byp_siz_c[0] = 2'd0;
                      byp_off_c[1] = 3'd4; byp_siz_c[1] = 2'd1;
                      byp_off_c[2] = 3'd6; byp_siz_c[2] = 2'd0;
                    end
            endcase
      default: begin  // legacy whole-word form: 1 word, or 2 when unaligned
                 byp_cnt_c = (o != 2'd0) ? 3'd2 : 3'd1;
                 byp_off_c[0] = 3'd0; byp_siz_c[0] = 2'd2;
                 byp_off_c[1] = 3'd4; byp_siz_c[1] = 2'd2;
               end
    endcase
  end
  logic          bypass_q;

`ifdef VEN_L1D_FILL_FORWARD
  // Only one returned word is validated below. An unaligned dword also reads
  // the following word from rd_window_q, which may not have arrived yet.
  // Keep such accesses on the ordinary completed-line registered read path.
  assign fill_forward_data_hit = (st == L1_FILL) && !bypass_q && cacheable &&
`ifdef VEN_L1D_CODE_BUFFER
                            !code_fill_q && !code_access &&
`endif
                            (c_addr[1:0] == 2'b00) &&
                            !xline && !fill_poison && !flush_all &&
                            !snoop_inv_valid && (set_c == fset) &&
                            (tag_c == ftag) && (c_addr != early_addr_q) &&
                            fill_word_valid[c_addr[4:2]];
`else
  assign fill_forward_data_hit = 1'b0;
`endif
`ifdef VEN_L1D_CODE_STREAM
`ifndef VEN_L1D_CODE_BUFFER
  initial $fatal(1, "VEN_L1D_CODE_STREAM requires VEN_L1D_CODE_BUFFER");
`endif
  // Once a returned instruction word has landed in the staging line, a later
  // S_PF word request may use it before the rest of the line arrives. Keep the
  // registered response owner: this is neither a comb AXI-to-core shortcut nor
  // a speculative line validation. The initial critical-word owner remains
  // exclusively on early_armed; it must not be acknowledged twice.
  assign fill_forward_code_hit = (st == L1_FILL) && code_fill_q &&
      code_access && c_req && !bypass_q && !fill_poison && !flush_all &&
      !snoop_inv_valid && (c_addr[31:5] == fbase[31:5]) &&
      (c_addr != early_addr_q) && fill_word_valid[c_addr[4:2]];
`else
  assign fill_forward_code_hit = 1'b0;
`endif
  assign fill_forward_hit = fill_forward_data_hit || fill_forward_code_hit;

  // backing-side drive: during a FILL, burst-read the 8 line words; on a
  // write-through (IDLE), pass the core write straight to the backing.
  // Cacheable fills are circular so word zero is the faulting aligned word.
  // ven_axi_master recognizes a nonzero first word as AXI WRAP8; word zero keeps
  // the existing INCR8 shape.  Both enumerate exactly the same line once.
  logic [2:0] fill_word;
  assign fill_word = fbase[4:2] + fw;
  always_comb begin
    m_req=1'b0; m_we=1'b0; m_addr=32'd0; m_wdata=32'd0; m_wstrb=4'd0;
    m_rd_narrow=1'b0; m_rd_size=2'd0;
`ifdef VEN_P54_DUAL_STORE_PAIR
    m_pair_req=1'b0; m_pair_addr=32'd0;
    m_pair_wdata=32'd0; m_pair_wstrb=4'd0;
`endif
    if (st==L1_FILL) begin
      m_req  = 1'b1; m_we = 1'b0;
      // REVIEW2_aug2 H-11: a NON-CACHEABLE read is a narrow access at the requested
      // WORD -- not a line fill from the line base. Addressing the line base was half
      // the bug: it both over-read seven neighbouring words AND started at the wrong
      // address, which is why the serve then had to index the whole line by
      // c_addr[4:0]. A CACHEABLE fill is unchanged, byte for byte.
      if (bypass_q) begin
        // REVIEW1_Aug3 R2-H01: per-PIECE presentation. Each beat is one aligned
        // power-of-two piece at its own BYTE address and ARSIZE (byp_*_q, latched
        // at the bypass start); ven_axi_master issues each as its own single-beat
        // transaction, so a device read touches exactly its own bytes.
        m_addr      = {fbase[31:2], 2'd0} + {29'd0, byp_off_q[fw[1:0]]};  // this piece's byte addr
        m_rd_narrow = 1'b1;
        m_rd_size   = byp_siz_q[fw[1:0]];
      end else
      // H-19: during the extra beat, address the NEXT line's word 0.
      m_addr = byp_hi_beat ? ({fbase[31:5], 5'd0} + 32'd32)
                           : ({fbase[31:5], 5'd0} + {27'd0, fill_word, 2'b00});
    end else if (st==L1_IDLE && c_req && c_we && !stream_path) begin
      // write-through: forward EVERY core write to the backing verbatim (the
      // write-allocate is disabled above). This now includes the within-line cacheable
      // write MISS (!hit && !xline && cacheable) — with no allocate, its store MUST be
      // forwarded here or it would never reach backing and c_ack would never fire (the
      // core would stall forever). HIT updates the cached copy (FF below); MISS caches
      // nothing; xline invalidates + forwards; non-cacheable forwards straight through.
      // All stores share the backing master's two P54C write buffers.  Keeping
      // no second staging register here is intentional: an L1-local entry plus
      // two AXI entries would silently make the CPU three-deep.
      m_req=1'b1; m_we=1'b1; m_addr=c_addr; m_wdata=c_wdata; m_wstrb=c_wstrb;
`ifdef VEN_P54_DUAL_STORE_PAIR
      // An invalid pair holds U too; the producer can drop c_pair_req and
      // retry U alone. Never post U while V is still being qualified.
      if (c_pair_req) begin
        m_req = c_pair_ready;
        m_pair_req = c_pair_ready;
        m_pair_addr = c_pair_addr;
        m_pair_wdata = c_pair_wdata;
        m_pair_wstrb = c_pair_wstrb;
      end
`endif
    end
  end

  // REVIEW_Jul29 H-13: the L1_BYP (non-cacheable) serve indexed the 256-bit bp_line
  // with {c_addr[4:0],3'b000} +: 32. At byte offsets 29..31 that selects bits
  // 232..279 — PAST THE END of the vector. An out-of-range part-select is not an
  // error, it silently yields X / zero / TOOL-DEPENDENT bits, so Verilator and
  // Vivado could disagree on the same unaligned uncacheable/MMIO dword.
  // Two things here:
  //   1) index a zero-extended copy so the select is always IN RANGE and the
  //      behaviour is at least DETERMINISTIC and identical across tools;
  //   2) flag the crossing loudly in simulation, because deterministic-but-wrong
  //      would otherwise MASK the defect.
  // The real fix is to split the access by its actual byte span and merge the two
  // responses (the cacheable path already builds a {next,current} window for this);
  // that needs bypass-FSM work and is tracked in task #40.
  // ===========================================================================
  // REVIEW2_aug2 H-11 -- NON-CACHEABLE READS WERE AMPLIFIED INTO FULL LINE BURSTS.
  // FIXED. The note below is kept because it was written as a work list, and every
  // item on it turned out to be real -- it is a fair record of what the fix cost.
  //
  // A non-cacheable read reused the FILL burst (L1_IDLE -> L1_FILL with bypass_q), so
  // ONE architectural read became a 32-byte, eight-beat request. For MMIO that is not
  // a performance question but a CORRECTNESS one: read-to-clear registers are cleared
  // eight-plus times, FIFOs pop repeatedly, and adjacent addresses with unrelated side
  // effects are touched.
  //
  // EXPOSURE: the bypass branch is taken only when `cacheable` is 0, and
  // ventium_l1_axi ties l1d_cacheable to 1'b1 except under VEN_L1_HONOR_CD, so this
  // was live in the HONOR_CD build and dormant in the default one.
  //
  // HOW IT WAS FIXED, against the six-item list:
  //   1+2. ven_axi_master's `m_axi_arlen = 8'(LINE_BEATS-1)` constant became rbeats_q,
  //        LATCHED with araddr_q at accept. The r_beat terminal compare and the
  //        priming re-issue both read it, so they cannot disagree about the length.
  //   3.   ventium_l1_axi plumbs m_rd_narrow/_2 through -- but only on the L2-BYPASS
  //        path. With the northbridge in the datapath they are tied 0, because a
  //        line-based L2 has no meaning for a narrow access and this change should not
  //        make an untested claim about a configuration its gates do not run.
  //   4.   this file drives them under bypass_q and addresses the WORD containing
  //        c_addr instead of the line base. Addressing the line base was half the bug:
  //        it over-read seven neighbours AND started at the wrong address, which is
  //        why the serve then had to index the whole line.
  //   5.   the L1_BYP serve indexes a 2-WORD window by c_addr[1:0], not the line by
  //        c_addr[4:0].
  //   5b.  the priming double-read is now restricted to CACHEABLE line fills
  //        (REVIEW_Aug3 C-01): it is a documented workaround for a PS S_AXI_HP FIFO
  //        bug (task #24), but applying it to a narrow read executed the DEVICE side
  //        effect twice (read-to-clear fired on the discarded priming burst). Narrow
  //        reads are born rd_primed=1 in ven_axi_master and deliver their first and
  //        only burst.
  //   6.   an unaligned access still needs two beats, so "single beat" is really "one
  //        or two, by alignment". The seam carries no read SIZE, so alignment alone
  //        decides: conservative in the safe direction (never fetches too few).
  //        FUTURE WORK (REVIEW_Aug3 C-01, deliberately NOT done there): carry the
  //        read size across the seam and narrow ARSIZE/the beat count to the actual
  //        byte span -- for a device, the conservatively-fetched extra word may
  //        itself have unrelated side effects.
  //
  // AND IT SUBSUMED TWO EARLIER WORKAROUNDS. H-19's cross-LINE bypass case and C-09's
  // seven-beat DRAIN both existed only because the fetch was line-shaped. C-09's note
  // said so explicitly -- it offered "a real single-beat backing operation" as the
  // alternative fix and took the drain instead, because the seam could not express a
  // single word. It can now, so nothing is left outstanding to drain.
  //
  // MEASURED, not asserted: tb_l1d case [11e] counts backing read beats. Forcing the
  // old line-shaped fetch back on with the new ports in place gives 8 beats aligned
  // and 8 unaligned; the fix gives 1 and 2, with the served data checked both ways.
  //
  // NOTE the overlap: C-09's first option ("give bypass traffic an explicit
  // single-beat backing operation") is this same change. C-09 was closed by its SECOND
  // option -- drain the burst -- which fixes the residual-beat corruption but leaves
  // the amplification untouched. Doing this would supersede that drain.
  //
  // NOT ATTEMPTED HERE, deliberately: this FSM has a recorded deadlock history
  // (L1_FILL->L1_BYP, see the rd_hit note above), the H-07 repair in it landed only
  // after a misdiagnosis was unwound, and a half-done split would produce exactly the
  // silent wrong-data class this comment exists to prevent. It wants a directed
  // read-side-effect test (a read-to-clear model in the BFM) alongside it, which does
  // not exist yet.
  // ===========================================================================
  logic [287:0] bp_line_x;
  assign bp_line_x = {bp_hi, bp_line};   // H-19: real high word, not zeros
  // REVIEW1_Aug3: the byp_cross WARNING is REMOVED -- it was stale. Under H-11 the
  // bypass fetch is word-shaped (1-2 beats), so a read at line offsets 29..31 is
  // served by beat 2 (the NEXT line's first word) through this 2-word window, and
  // the data is CORRECT for every c_addr[1:0]. The warning claimed "split access
  // NOT implemented; high bytes read as 0", which described the pre-H-11
  // line-shaped fetch, and its flood (every line-end read with CR0.CD set) was
  // measured slowing full-core gates by ~2x. The L1AXINARROW gate's line-edge
  // section (0xA0FFD..0xA0FFF dword checks, incl. the R2-H01 4 KiB-edge fragment
  // split) is the executable proof the shape is handled.

  // core-side response: HIT (read) returns combinationally; a write acks with the
  // backing; a read miss deasserts c_ack and kicks the fill (handled in the FF).
  always_comb begin
    // 4 bytes at the addressed byte offset, from the {L+1, L} window so a read that
    // crosses the line end (boff > 28) takes its high bytes from the next line.
    // In L1_BYP (non-cacheable read) the data comes from the private bp_line buffer
    // instead. Its byte offset and response identity are both from the saved request
    // (fbase/byp_wstrb_q), never from a newer live c_addr.
`ifdef VEN_L1D_COMB_ACK
    // COSIM-ONLY perf (NEVER synthesize — the registered rd_window_q path below exists for
    // 40 MHz fmax / anti-glitch closure; this combinational serve does not meet timing on
    // silicon). Serve the read HIT in the SAME cycle: both the data AND the byte-select come
    // from the LIVE c_addr window (rd_window / c_addr), so there is no captured-window stale
    // exposure at all — strictly VALUE-IDENTICAL to the registered serve, just one cycle
    // earlier. Saves 1 clk on every S_FETCH word + every data-load HIT (~20-30% of POST
    // cycles). rd_armed/rd_window_q/rd_addr_q still update below (harmless dead logic here).
    // L1_BYP is different: its data and response identity come from the saved request
    // (fbase/byp_wstrb_q), never from a newer live c_addr/c_wstrb.
    c_rdata = (st==L1_BYP) ? bp_line_x[{4'd0,fbase[1:0],3'b000} +: 32]   // saved request offset
                           : rd_window[{1'b0,c_addr[4:0],3'b000} +: 32];   // LIVE window, LIVE offset
    c_ack   = 1'b0;
    if (c_req) begin
      if (c_we) begin
        c_ack = (st==L1_IDLE) ? m_ack : 1'b0;
`ifdef VEN_P54_DUAL_STORE_PAIR
        if (c_pair_req) c_ack = c_pair_ready && m_ack && m_pair_ack;
`endif
      end
      // REVIEW2 H-13: same gating on the combinational-ack variant.
      // REVIEW1_Aug2 H-07: the ARRAY ack term must not fire for a non-cacheable read of
      // a RESIDENT line -- that is precisely the "resident data returned after CD is
      // set" the finding describes, and it would also ack with stale data on the same
      // clock the L1_IDLE arm starts the bypass fill. Gated HERE, on the ack term,
      // rather than on rd_hit: rd_hit is also consulted by the POST-FILL serve, and
      // gating it there is what made the previous attempt deadlock.
      else                 c_ack = (rd_hit && (st==L1_IDLE) && !flush_all && !snoop_inv_valid
                                    && !(BYPASS_RD_EN && !cacheable))
                                 || ((st==L1_BYP) && byp_match);             // owned non-cacheable response
    end
`else
    // (STLD REMOVED — the store-to-load overlay POISONED PS-visible updates: an ancient CPU
    // write of BDA kbd tail=0x1E sat in the 32-entry buffer and overlaid EVERY fresh read of
    // 0x41C forever, so daemon-injected keys were invisible. The coherence problem it was
    // built for was actually the LGDT base bug. Clean registered serve restored.)
    c_rdata = (st==L1_BYP) ? bp_line_x[{4'd0,fbase[1:0],3'b000} +: 32]   // saved request offset
                           : shadow_reuse ? shadow_line_q[{1'b0,c_addr[4:0],3'b000} +: 32]
                           : window_reuse ? rd_window_q[{1'b0,c_addr[4:0],3'b000} +: 32]
                           : early_armed ? early_rdata_q
                                         : rd_window_q[{1'b0,rd_addr_q[4:0],3'b000} +: 32];
    c_ack   = 1'b0;
    if (c_req) begin
      if (c_we) begin
        c_ack = (st==L1_IDLE) ? m_ack : 1'b0;
`ifdef VEN_P54_DUAL_STORE_PAIR
        if (c_pair_req) c_ack = c_pair_ready && m_ack && m_pair_ack;
`endif
      end
      // REVIEW1_Aug2 H-07: same array-ack suppression as the combinational variant
      // above -- see the comment there for why this is on the ack term, not rd_hit.
      // REVIEW2 H-13: suppressing the CAPTURE during a snoop was not enough. If a
      // window was armed on the PREVIOUS clock and the snoop arrives on the SERVE
      // edge, rd_match is still true (it compares only the address, never current
      // tag/valid) and the core's sequential logic samples c_ack=1 with the stale
      // rd_window_q at that very edge, while the array clears valid. Gate the
      // RESPONSE itself, not just the capture.
      else                 c_ack = window_reuse || shadow_reuse ||
                                 (early_match && !flush_all && !snoop_inv_valid)
                                 || (rd_match && !flush_all && !snoop_inv_valid
                                    && !(BYPASS_RD_EN && !cacheable))
                                 || ((st==L1_BYP) && byp_match); // owned non-cacheable response
    end
`endif
`ifdef VEN_L1D_HIT_STREAM
    if (stream_path) begin
      c_rdata = rd_window_q[{1'b0,rd_addr_q[4:0],3'b000} +: 32];
      // A premature mode switch must not mislabel the old stream response
      // as the completion of a newly presented legacy store/read.
      c_ack = c_hit_stream && c_rsp_valid && c_rsp_ready;
    end
`endif
  end

  // golden / "L1-useless" mode: a core transaction completes (acks) this clock. We
  // drop all cached state on the NEXT edge so nothing carries into the following
  // access. c_ack is the completion edge for both reads (rd_match) and writes (m_ack).
  logic txn_done;
  // build #24: NARROW golden to the low 1 MiB (real-mode DOS memory, incl. the FreeDOS relocation
  // source). golden (flush-all + rd_window_q clear per txn) FIXED the relocation coherence bug in
  // build #23, but flushing on EVERY access (incl. Win95 protected-mode >=1MB) is ~10x slow. Gating to
  // <1MB keeps the real-mode boot coherent (correct copy) while extended-memory accesses cache at full
  // speed -> the boot can actually reach the desktop.
  assign txn_done = golden && c_req && c_ack && (c_addr[31:20] == 12'h000);

  // (STLD store-to-load forwarding REMOVED — see the serve-path note above. It was built
  // for a misdiagnosed coherence theory (the real bug was the 16-bit LGDT base) and its
  // indefinite-lifetime entries overlaid stale CPU-write data onto PS-updated lines.)

  // ---- sequential: fill sequencing + array writes ---------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st<=L1_IDLE; fw<=3'd0; rd_armed<=1'b0; rd_window_q<='0; rd_addr_q<=32'd0;
`ifdef VEN_L1D_CODE_BUFFER
      rd_code_q<=1'b0; early_code_q<=1'b0;
`endif
`ifdef VEN_FP_LOAD64
      rd_full_line_q <= 1'b0;
`endif
`ifdef VEN_L1D_WINDOW_REUSE
      window_valid_q <= 1'b0;
`ifdef VEN_L1D_TWO_WINDOW_REUSE
      shadow_line_q <= '0;
      shadow_line_addr_q <= '0;
      shadow_valid_q <= 1'b0;
`endif
`endif
`ifdef VEN_L1D_HIT_STREAM
      rd_stream_q <= 1'b0;
`endif
      fill_word_valid <= '0;
      early_armed<=1'b0; early_ok_q<=1'b0; early_addr_q<=32'd0;
      early_rdata_q<=32'd0; early_wstrb_q<=4'd0;
      bypass_q<=1'b0; bp_line<='0; fill_poison<=1'b0; byp_n2<=1'b0;
`ifdef VEN_L1D_CODE_BUFFER
      code_valid_q<=1'b0; code_fill_q<=1'b0; code_line_tag_q<='0;
`endif
      byp_wstrb_q<=4'd0;
      bp_hi<=32'd0; byp_need_hi<=1'b0; byp_hi_beat<=1'b0;   // H-19
      for (int s=0;s<L1_SETS;s++) begin
        dc_lru[s]<=1'b0; dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0;
        dc_tag[s][0]<=20'd0; dc_tag[s][1]<=20'd0;
      end
    end else begin
`ifdef VEN_FP_LOAD64
      if (do_rd_cap)
        rd_full_line_q <= (st == L1_IDLE) && hit && !fill_forward_hit && !stream_path &&
`ifdef VEN_L1D_BANK0_SHARED_XLINE
                          !xline &&
`endif
`ifdef VEN_P54_DUAL_HIT
                          !((pair_legacy_capture || pair_prime_capture) &&
                            pair_req_ready[1]);
`else
                          1'b1;
`endif
      if (flush_all || snoop_inv_valid || golden || stream_path ||
          (c_req && (c_we || !cacheable)))
        rd_full_line_q <= 1'b0;
`endif
`ifdef VEN_L1D_WINDOW_REUSE
      if (do_rd_cap)
        window_valid_q <= (st == L1_IDLE) && hit && !stream_path &&
`ifdef VEN_L1D_BANK0_SHARED_XLINE
                          !xline &&
`endif
`ifdef VEN_P54_DUAL_HIT
                          !((pair_legacy_capture || pair_prime_capture) &&
                            pair_req_ready[1]);
`else
                          1'b1;
`endif
`ifdef VEN_L1D_TWO_WINDOW_REUSE
      if (do_rd_cap && window_valid_q) begin
        shadow_line_q <= rd_window_q[LW-1:0];
        shadow_line_addr_q <= rd_addr_q[31:5];
        shadow_valid_q <= 1'b1;
      end
      // WINDOW_KEEP_STORE only compares a store with the primary owner.
      // Clearing the shadow on *every* store avoids retaining stale bytes
      // when a non-overlapping-primary store actually writes the shadow line.
      if (c_req && c_we)
        shadow_valid_q <= 1'b0;
`endif
      // All window writers participate; invalidation wins over capture.
      if (flush_all || snoop_inv_valid || golden || stream_path ||
`ifdef VEN_L1D_WINDOW_KEEP_STORE
          // Preserve only the FIRST registered physical line across unrelated
          // cacheable stores. No window data/owner or store ACK is changed.
          // xline honors the actual store strobes (zero writes no bytes).
          // Any NC access, overlapping store, miss/fill or external writer
          // retains the conservative invalidation. Current hit still gates use.
          (st != L1_IDLE) || (c_req && (!cacheable ||
            (c_we ? ((c_addr[31:5] == rd_addr_q[31:5]) ||
                     (xline && (addr_n[31:5] == rd_addr_q[31:5]))) : !rd_hit))))
`else
          (st != L1_IDLE) || (c_req && (c_we || !cacheable || !rd_hit)))
`endif
        begin
          window_valid_q <= 1'b0;
`ifdef VEN_L1D_TWO_WINDOW_REUSE
          shadow_valid_q <= 1'b0;
`endif
        end
`endif
      rd_armed <= (do_rd_cap && !flush_all) ||
                  (mc_prime_window_reuse && mc_capture_next)
`ifdef VEN_PIPE_MEM_CHAIN
                  || (mc_lookup_old && !c_next_commit &&
                      !flush_all && !snoop_inv_valid && !golden)
`endif
`ifdef VEN_L1D_HIT_STREAM
                  || (rd_stream_q && rd_armed && !c_rsp_ready && !c_rsp_cancel)
`endif
                  ;
`ifdef VEN_L1D_HIT_STREAM
      rd_stream_q <= do_rd_cap ? c_hit_stream :
                     (rd_stream_q && rd_armed && !c_rsp_ready && !c_rsp_cancel);
`endif
      // A response is intentionally one full core clock wide.  Clearing by
      // default consumes it even if the producer retargeted away before the
      // sampling edge; retaining it could otherwise misattribute it later.
      early_armed <= 1'b0;
      if (do_rd_cap && !flush_all) begin
        rd_window_q <= rd_window;
        rd_addr_q   <= lookup_addr;   // independently accepted response owner
`ifdef VEN_L1D_CODE_BUFFER
        rd_code_q   <= code_access;
`endif
      end
`ifdef VEN_PIPE_MEM_CHAIN
      if (mc_prime_window_reuse && mc_capture_next)
        rd_addr_q <= c_next_addr;
`endif
      unique case (st)
        L1_IDLE: begin
          // REVIEW1_Aug2 H-07: this branch was `if (1'b0)` under VEN_L1_HONOR_CD, on the
          // grounds that the bypass FSM "deadlocks in the full-core+bridge context".
          // The recorded deadlock was real but was caused by a DIFFERENT change --
          // gating rd_hit itself on `cacheable`, which also suppresses the POST-FILL
          // serve, so the read never acks (see the rd_hit comment above).
          //
          // The serve path this needs already exists and does NOT consult rd_hit:
          //     c_ack   = (array hit ...) || (st==L1_BYP)
          //     c_rdata = (st==L1_BYP) ? bp_line_x[...] : rd_window[...]
          // L1_BYP serves from the PRIVATE bp_line buffer and acks on state alone. The
          // one thing missing was suppressing the ARRAY ack term for a non-cacheable
          // read of a RESIDENT line -- otherwise c_ack fired from the array with stale
          // data on the same clock this branch started the bypass fill. That gating is
          // on the c_ack term, NOT on rd_hit, which is the whole distinction.
          //
          // NOTE this branch was also dead in the non-HONOR_CD build: there
          // ventium_l1_axi ties l1d_cacheable to 1'b1, so `!cacheable` never held. The
          // FSM was unreachable in BOTH configurations, which is why the review calls
          // it untested.
          if (mc_lookup_next) begin
            // Old registered response is untouched until this edge. A
            // rejected next read causes no replacement or backing access.
            if (mc_capture_next) dc_lru[set_c] <= hit_way;
          end else if (stream_path) begin
            // The same async lookup and registered read window serve both
            // protocols. Stream misses are rejected without allocation; only
            // an accepted resident dword read changes replacement state.
            if (do_rd_cap) dc_lru[set_c] <= hit_way;
          end else if (c_req && !c_we && !cacheable) begin
            // NON-CACHEABLE READ (KEN# negated): fetch the addressed bytes into the
            // private bp_line buffer (no array touch, no LRU), then serve in L1_BYP.
            fset <= set_c; fway <= ~dc_lru[set_c]; ftag <= tag_c; fbase <= c_addr;
            byp_wstrb_q <= c_wstrb;
            fw <= 3'd0;  bypass_q <= 1'b1;  st <= L1_FILL;
            // REVIEW1_Aug3 R2-H01: latch the piece table (byte-exact when the core
            // drove read strobes; the legacy whole-word form otherwise) and CLEAR
            // the bypass buffer -- beats OR-merge into it (each piece's data is
            // masked to its own lanes downstream).
            byp_cnt_q <= byp_cnt_c;
            byp_off_q[0] <= byp_off_c[0]; byp_siz_q[0] <= byp_siz_c[0];
            byp_off_q[1] <= byp_off_c[1]; byp_siz_q[1] <= byp_siz_c[1];
            byp_off_q[2] <= byp_off_c[2]; byp_siz_q[2] <= byp_siz_c[2];
            bp_line <= '0;
            byp_n2      <= (c_addr[1:0] != 2'd0);
            // H-19's cross-LINE case is subsumed: see the byp_n2 declaration.
            byp_need_hi <= 1'b0;
            byp_hi_beat <= 1'b0; bp_hi <= 32'd0;
            fill_poison <= flush_all || snoop_inv_valid;   // H-06/H-07
            early_ok_q  <= 1'b0;
          end else if (c_req && !c_we && !rd_hit) begin
            // read MISS → fill the MISSING line into its not-MRU victim way. On a
            // xline-line read where L is resident but L+1 is not, fill L+1; the core
            // holds the request so the retry then fills L (if needed) -> L+1 -> hits.
            bypass_q <= 1'b0;
`ifdef VEN_L1D_CODE_BUFFER
            code_fill_q <= code_access;
            if (code_access) code_valid_q <= 1'b0;
`endif
            if (
`ifdef VEN_L1D_CODE_BUFFER
                code_access ||
`endif
                !hit) begin
              fset <= set_c; fway <= ~dc_lru[set_c]; ftag <= tag_c; fbase <= c_addr;
            end else begin            // hit_L but xline && !hit_n -> fill the next line
              fset <= set_n; fway <= ~dc_lru[set_n]; ftag <= tag_n; fbase <= addr_n;
            end
            fw <= 3'd0;  st <= L1_FILL;
            fill_word_valid <= '0;
            fill_poison <= flush_all || snoop_inv_valid;   // H-06/H-07
            // Only a within-line aligned dword has a complete architectural
            // result in the first wrapped word.  Unaligned/cross-line reads
            // retain the established fill-then-window path.
            early_ok_q    <= cacheable && !xline && (c_addr[1:0] == 2'd0);
            early_addr_q  <= c_addr;
            early_wstrb_q <= c_wstrb;
`ifdef VEN_L1D_CODE_BUFFER
            early_code_q <= code_access;
`endif
          end else if (1'b0 && c_req && c_we && !xline && !hit && cacheable) begin
            // DISABLED (Win95 REP-MOVSB relocation fix): the write-allocate STALLS the core
            // (c_ack=0) through an 8-beat fill on every write MISS. Under real FPGA DDR latency a
            // long back-to-back REP MOVSB relocation to fresh dest lines (FreeDOS kernel -> 0x80000)
            // diverges here — the dest keeps stale data. The P54C bounded write queue admits a
            // clean per-store write-through; the backing master blocks a later read miss until
            // those writes drain. Keep the allocate arm text for reference:
            // WRITE-ALLOCATE: a within-line write MISS fills the addressed line into
            // the not-MRU victim FIRST; the core holds the store (c_ack=0) and the
            // post-fill retry hits -> RMW the cached copy + write-through. Without the
            // allocate the store is write-through ONLY, and a later read MISS of the
            // same line fills from not-yet-globally-visible (posted) backing -> STALE
            // data. That is the free-run __init_libc derail: `rep stos` zeroes an
            // uncached buffer then reads it back; single-step drained the posted write
            // between instructions so it only bit on silicon (AXI_WPOST sim repro).
            bypass_q <= 1'b0;
            fset <= set_c; fway <= ~dc_lru[set_c]; ftag <= tag_c; fbase <= c_addr;
            fw <= 3'd0;  st <= L1_FILL;
            fill_poison <= flush_all || snoop_inv_valid;   // H-06/H-07
          end else if (c_req && !c_we && rd_hit) begin
            // read HIT → 2-way LRU touch (both lines on a xline-line hit).
`ifdef VEN_L1D_CODE_BUFFER
            if (!code_access) begin
`endif
            dc_lru[set_c] <= hit_way;
            if (xline) dc_lru[set_n] <= hit_way_n;
`ifdef VEN_L1D_CODE_BUFFER
            end
`endif
          end else if (c_req && c_we && c_ack) begin
            // WRITE (write-through). The backing received the full byte-accurate store
            // via the comb driver (ven_axi_master splits a cross-word / cross-line
            // store into per-word AXI beats); c_ack means the master retained the
            // store in one of its two ordered buffers, so committing the matching
            // cached copy now is safe. Keep the cached copy coherent:
            if (!xline && hit) begin
              // FIX D (UPDATE 94, cluster->sector RMW): WRITE HIT, within a single line ->
              // byte-accurate UPDATE-IN-PLACE of the hit way, keeping the line VALID+MRU, so an
              // immediately-following LOAD of the same address HITS the fresh value. This is the
              // fix for tight same-address read-modify-write loops — the FAT driver's
              // (cluster-2)*spc multiword shift `rcl dx,1 / rcl word ss:[0x607],1` (x6): under
              // FIX A's blind-invalidate each rcl store cleared the line, so the NEXT rcl load
              // MISSED and re-filled STALE from the backing before the store's write-through was
              // globally visible -> the high word never accumulated -> COMMAND.COM's LBA 0x2F3C0
              // truncated to 0x0F3C0 (62400) -> Win95 shell load fails. Byte map = ven_axi_master's
              // (ven_axi_master.sv:186): the byte at c_addr is lane 0 of c_wstrb/c_wdata, so byte i
              // lands at line byte offset c_addr[4:0]+i (a within-line cross-WORD store — e.g.
              // [0x607] at offset 23 spanning 23,24 — is handled naturally; xline stores that spill
              // to the NEXT line keep the blind-invalidate arm below). The store is still
              // write-through (comb driver), so the backing stays authoritative.
`ifndef VEN_L1D_BANKED_DATA
              for (int i = 0; i < 4; i++) begin
                logic [4:0] line_byte;
                line_byte = c_addr[4:0] + 5'(i);
                if (c_wstrb[i])
                  dc_line[{set_c, hit_way}][8*line_byte +: 8] <= c_wdata[8*i +: 8];
              end
`endif
              // Physical tags distinguish different lines occupying one set.
              // Preserve the other way unless it duplicates this exact tag.
              // Cache mutation is acceptance-qualified above, so a held then
              // withdrawn store cannot leave speculative data in a valid line.
              if (hit0 && hit1) dc_val[set_c][~hit_way] <= 1'b0;
              dc_lru[set_c] <= hit_way;
            end else begin
              // Nonallocating write miss: no matching cached data to change.
              // Crossing stores invalidate only resident touched physical tags;
              // ven_axi_master drains posted writes before any backing read.
              // External writers still require the independent snoop/flush
              // contract below. Unrelated stores cannot repair missing snoops.
              if (hit0) dc_val[set_c][0] <= 1'b0;
              if (hit1) dc_val[set_c][1] <= 1'b0;
              if (xline) begin
                if (hit_n0) dc_val[set_n][0] <= 1'b0;
                if (hit_n1) dc_val[set_n][1] <= 1'b0;
              end
            end
            // (STLD write-capture removed with the forwarding buffer.)
          end
        end
        L1_FILL: begin
`ifdef VEN_L1D_CODE_BUFFER
          if (golden && code_fill_q) fill_poison <= 1'b1;
`endif
`ifdef VEN_L1D_HIT_UNDER_FILL
          // fill_independent_hit proves set_c != fset, so this local LRU
          // touch cannot race the fill's terminal allocation/LRU update.
          // The read itself still takes the normal registered capture/serve
          // path; this is hit-under-fill, not a combinational bypass.
          if (do_rd_cap)
            dc_lru[set_c] <= hit_way;
`endif
          // H-06/H-07: an invalidation arriving MID-fill (beats 0..6) has no allocated
          // line to match, so it must be remembered instead of dropped.
          if (flush_all || snoop_hits_fill) fill_poison <= 1'b1;
          if (m_ack) begin
            // AXI WRAP8/INCR8 beat zero is the saved faulting dword.  Latch it
            // before the regular line write so the response remains a short
            // FF-to-core path.  Never arm through an invalidate boundary.
            if (!bypass_q && (fw == 3'd0) && early_ok_q &&
                !flush_all && !snoop_inv_valid) begin
              early_armed   <= 1'b1;
              early_rdata_q <= m_rdata;
            end
            // capture the returned word: into the PRIVATE buffer for a non-cacheable
            // bypass (no array write), else into the victim line being allocated.
            // REVIEW2_aug2 C-09: A BYPASS BEAT MUST NEVER WRITE THE ARRAY.
            //
            // This used to read `if (bypass_q && !byp_hi_beat) ... else dc_line ...`,
            // so the NINTH (high-word) beat of a cross-line non-cacheable read -- where
            // bypass_q=1 AND byp_hi_beat=1 -- failed the first condition and fell into
            // the array write. fw is still 7 at that point, so the returned word was
            // written into victim word 7 of {fset,fway} with NO tag or valid update: a
            // valid, unrelated line silently corrupted beneath its existing tag, which
            // a later hit then serves as if it were real data.
            //
            // A bypass allocates nothing by definition, so the array write is gated on
            // !bypass_q rather than on the beat index. The high word is captured as
            // bp_hi immediately below.
            if (bypass_q) begin
              // REVIEW2_aug2 H-11: the narrow fetch returns the addressed word first
              // and (when unaligned) the following one, so they land at bp_line words
              // 0 and 1 rather than at their line offsets.
              // REVIEW1_Aug3 R2-H01: OR-merge each piece (its data is masked to its
              // own lanes by ven_axi_master) into the word it belongs to; the buffer
              // was cleared at the bypass start.
              if (!byp_off_q[fw[1:0]][2]) bp_line[31:0]  <= bp_line[31:0]  | m_rdata;
              else                         bp_line[63:32] <= bp_line[63:32] | m_rdata;
            end else begin
              // The backing stream starts at the critical word and wraps; map
              // each returned beat back to its physical dword slot in the line.
`ifdef VEN_L1D_CODE_BUFFER
              if (code_fill_q)
                code_line_q[32*fill_word +: 32] <= m_rdata;
`endif
`ifndef VEN_L1D_BANKED_DATA
`ifdef VEN_L1D_CODE_BUFFER
              else
`endif
              dc_line[{fset,fway}][{fill_word,5'b00000} +: 32] <= m_rdata;
`endif
              // The data array write is visible on the following clock.  Mark
              // precisely that physical WRAP-word ready so a later same-line
              // load can use the existing registered capture/ack path while
              // the remaining fill beats continue to drain.
              fill_word_valid[fill_word] <= 1'b1;
            end
            if (byp_hi_beat) begin
              // H-19: the extra request returns the NEXT line's word 0, which is beat 0
              // of that request.
              //
              // ---- REVIEW2_aug2 C-09 (second half): DRAIN THE REST OF THE BURST.
              // This used to capture beat 0 and jump straight to L1_BYP, leaving SEVEN
              // beats of that burst outstanding on the backing interface. ven_axi_master
              // turns every read into an eight-beat line burst -- it cannot request a
              // single word -- and the seam carries no transaction ID, so if the core
              // started another miss before those beats drained, the new L1_FILL
              // consumed the OLD burst's residual data as its own line. Silent, and it
              // corrupts a line that was filled correctly as far as any tag can tell.
              //
              // The review offers two fixes: a real single-beat backing operation, or
              // drain and identify the transaction before allowing a new fill. The
              // first needs a new request size on the ven_axi_master seam; this is the
              // second, and it is contained entirely in this state. fw is reused as the
              // drain counter (it is dead once the line is captured), so only word 0 is
              // taken and beats 1..7 are consumed and discarded before L1_BYP.
              if (fw == 3'd0) bp_hi <= m_rdata;
              if (fw == 3'(WORDS-1)) begin
                byp_hi_beat <= 1'b0;
                st          <= L1_BYP;
              end else fw <= fw + 3'd1;
            end else if (bypass_q) begin
              // REVIEW2_aug2 H-11: the burst is 1 or 2 beats now, so it ends here --
              // and the C-09 DRAIN is gone with it. That drain existed only because
              // ven_axi_master could not request a single word and left seven beats
              // outstanding; the review named "a real single-beat backing operation"
              // as the alternative fix, and this is it. Nothing is left in flight to
              // drain, so a following fill cannot inherit residual beats.
              // R2-H01: the beat count is the piece count (1..3).
              if (fw == (byp_cnt_q - 3'd1)) st <= L1_BYP;
              else                          fw <= fw + 3'd1;
            end else if (fw==3'(WORDS-1)) begin
              if (1'b0) begin
                // non-cacheable: serve from bp_line next clock; allocate NOTHING.
                // H-19: unless the access crosses the line end, in which case run ONE
                // more beat for the following line's word 0 first.
                // C-09: restart fw at 0 so the high request's own eight beats are
                // counted and fully drained above.
                if (byp_need_hi) begin byp_hi_beat <= 1'b1; fw <= 3'd0; end
                else             st          <= L1_BYP;
              end else begin
                // last word → allocate the victim (tag/val) + MRU, then retry hits.
                // REVIEW Aug-1 H-06/H-07: only VALIDATE if the transaction was never
                // poisoned -- and re-test flush/snoop on this very clock too, because a
                // same-cycle invalidation cannot be caught by the pre-edge guards in the
                // flush/snoop blocks below (they see valid=0 for this not-yet-allocated
                // line). The tag is written either way; val is what gates it.
`ifdef VEN_L1D_CODE_BUFFER
                if (code_fill_q) begin
                  code_line_tag_q <= fbase[31:5];
                  code_valid_q <= !(fill_poison || flush_all || snoop_hits_fill || golden);
                end else begin
`endif
                  dc_tag[fset][fway]<=ftag; dc_lru[fset]<=fway;
                  dc_val[fset][fway]<= !(fill_poison || flush_all || snoop_hits_fill);
`ifdef VEN_L1D_CODE_BUFFER
                end
`endif
                // The line/tag/valid RAM writes commit on this edge.  Returning
                // directly to IDLE gives the existing registered read window the
                // following full cycle to observe the new line, then a further
                // registered response cycle.  This removes only the obsolete
                // L1_DONE bubble; it does NOT create a same-edge async-RAM ack.
                st<=L1_IDLE;
              end
            end else fw<=fw+3'd1;
          end
        end
        L1_DONE: begin
          // one settle clock so the just-written line is visible to the comb read
          // before the core's retry samples the hit. Then back to serving.
          st<=L1_IDLE;
        end
        L1_BYP: begin
          // non-cacheable read: c_ack + c_rdata (from bp_line) are asserted
          // combinationally THIS clock; just return to serving. Nothing allocated.
          st<=L1_IDLE;
        end
        default: st<=L1_IDLE;
      endcase
`ifdef VEN_P54_DUAL_HIT
      // Both owner responses captured this edge; the younger V touch wins if
      // both physical lines map to the same set, matching program order.
      if (pair_req_valid[0] && pair_req_ready[0])
        dc_lru[pair_set[0]] <= pair_way[0];
      if (pair_req_valid[1] && pair_req_ready[1])
        dc_lru[pair_set[1]] <= pair_way[1];
`endif
      // #35 external flush: clear every valid bit (last-write-wins over the case's
      // tag/val writes, so an invalidation always takes priority). The next reads
      // miss + refill the now-current backing. Tags/data are left (val gates them).
      if (flush_all)
        for (int s=0;s<L1_SETS;s++) begin dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0; end
      // golden mode: after each completed transaction, invalidate every line AND
      // clear the registered read window (rd_armed/rd_window_q/rd_addr_q) so the next
      // access fully re-fills + re-captures. Last-write-wins over the fill's val=1 and
      // the do_rd_cap capture above (this clock the txn already acked, so dropping the
      // state cannot un-do the ack — c_ack/rd_match are registered values sampled now).
      if (txn_done) begin
        rd_armed <= 1'b0; rd_window_q <= '0; rd_addr_q <= 32'd0;
        for (int s=0;s<L1_SETS;s++) begin dc_val[s][0]<=1'b0; dc_val[s][1]<=1'b0; end
      end
      // per-line snoop INVALIDATE (DMA / PCI coherence): clear the matching {set,way}
      // valid bit if resident. LAST in the FF so an invalidation wins over a same-cycle
      // allocate of that line (a DMA write must never leave a stale cached copy). Gated
      // by snoop_inv_valid — tied 0 in modes 0/1, so the default path is byte-identical.
      if (snoop_inv_valid) begin
        logic [IDXW-1:0] snp_set; logic [TAGW-1:0] snp_tag;
        snp_set = snoop_inv_addr[OFFW +: IDXW];
        snp_tag = snoop_inv_addr[OFFW+IDXW +: TAGW];
        if (dc_val[snp_set][0] && dc_tag[snp_set][0]==snp_tag) dc_val[snp_set][0]<=1'b0;
        if (dc_val[snp_set][1] && dc_tag[snp_set][1]==snp_tag) dc_val[snp_set][1]<=1'b0;
      end
`ifdef VEN_L1D_CODE_BUFFER
      // The I-fill copy must not outlive any external mutation or an accepted
      // CPU store. A conservative all-store invalidate costs no extra backing
      // traffic in the normal fill sequence and avoids an untracked code alias.
      if (flush_all || snoop_inv_valid || golden || txn_done ||
          (c_req && c_code && !cacheable) ||
          (c_req && c_we && c_ack))
        code_valid_q <= 1'b0;
`endif
    end
  end

`ifndef SYNTHESIS
`ifdef VEN_L1D_PERF
  // Simulation-only transaction attribution for full-system replay.  A core
  // load can wait either for the intentional one-cycle registered hit window,
  // an allocating line fill, a non-cacheable bypass, or the backing interface.
  // Keep these counters beside the actual serve predicates: guessing from the
  // core's S_LOAD residency alone cannot distinguish those cases.
  longint unsigned perf_hit_capture, perf_hit_ack, perf_critical_ack, perf_hit_under_fill;
  longint unsigned perf_fill_forward;
  longint unsigned perf_miss_start, perf_bypass_start;
  longint unsigned perf_read_wait_idle, perf_read_wait_fill;
  longint unsigned perf_read_wait_done, perf_read_wait_bypass;
  longint unsigned perf_fill_cycles, perf_fill_wait, perf_fill_ack;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      perf_hit_capture     <= 0; perf_hit_ack         <= 0; perf_critical_ack <= 0;
      perf_hit_under_fill  <= 0; perf_fill_forward     <= 0;
      perf_miss_start      <= 0; perf_bypass_start    <= 0;
      perf_read_wait_idle  <= 0; perf_read_wait_fill  <= 0;
      perf_read_wait_done  <= 0; perf_read_wait_bypass<= 0;
      perf_fill_cycles     <= 0; perf_fill_wait       <= 0; perf_fill_ack <= 0;
    end else begin
      if (do_rd_cap) perf_hit_capture <= perf_hit_capture + 1;
      if (do_rd_cap && fill_independent_hit)
        perf_hit_under_fill <= perf_hit_under_fill + 1;
      if (do_rd_cap && fill_forward_hit)
        perf_fill_forward <= perf_fill_forward + 1;
      if (c_req && !c_we && c_ack && rd_match) perf_hit_ack <= perf_hit_ack + 1;
      if (c_req && !c_we && c_ack && early_match) perf_critical_ack <= perf_critical_ack + 1;
      if (c_req && !c_we && st==L1_IDLE) begin
        if (!cacheable) perf_bypass_start <= perf_bypass_start + 1;
        // Read-chain lookahead redirects rd_hit to the unissued NEXT address.
        // Rejection there starts no fill, so it is not a demand miss. The
        // old c_req remains acknowledged from its registered response.
        else if (!mc_lookup_next && !rd_hit)
          perf_miss_start <= perf_miss_start + 1;
      end
      if (c_req && !c_we && !c_ack) begin
        unique case (st)
          L1_IDLE: perf_read_wait_idle   <= perf_read_wait_idle + 1;
          L1_FILL: perf_read_wait_fill   <= perf_read_wait_fill + 1;
          L1_DONE: perf_read_wait_done   <= perf_read_wait_done + 1;
          L1_BYP:  perf_read_wait_bypass <= perf_read_wait_bypass + 1;
          default: ;
        endcase
      end
      if (st==L1_FILL) begin
        perf_fill_cycles <= perf_fill_cycles + 1;
        if (m_ack) perf_fill_ack <= perf_fill_ack + 1;
        else       perf_fill_wait <= perf_fill_wait + 1;
      end
    end
  end

  final begin
    $display("[L1DPERF] hit-capture=%0d hit-ack=%0d critical-ack=%0d hit-under-fill=%0d fill-forward=%0d miss-start=%0d bypass-start=%0d",
             perf_hit_capture, perf_hit_ack, perf_critical_ack, perf_hit_under_fill,
             perf_fill_forward, perf_miss_start, perf_bypass_start);
    $display("[L1DPERF] read-wait idle=%0d fill=%0d done=%0d bypass=%0d",
             perf_read_wait_idle, perf_read_wait_fill, perf_read_wait_done,
             perf_read_wait_bypass);
    $display("[L1DPERF] fill cycles=%0d backing-wait=%0d backing-ack=%0d",
             perf_fill_cycles, perf_fill_wait, perf_fill_ack);
  end
`endif
`endif

`ifdef VEN_DBG_CORE
  // DEADLOCK detector (Quake cs=0087:0x334 non-retiring stall): if the core holds a request with no ack
  // for a long time, the L1D/AXI is stuck servicing it. Log the address + memory-path state ONCE so the
  // deadlocking access (upper-memory/MMIO/out-of-range?) can be identified.
  logic [23:0] stuck_cnt = 24'd0;
  logic        stuck_shown = 1'b0;
  always_ff @(posedge clk) begin
    if (!rst_n) begin stuck_cnt <= 24'd0; stuck_shown <= 1'b0; end
    else begin
      if ((c_req && !c_ack) || st != L1_IDLE) stuck_cnt <= stuck_cnt + 24'd1;
      else stuck_cnt <= 24'd0;
      if (stuck_cnt == 24'd500000 && !stuck_shown) begin
        stuck_shown <= 1'b1;
        $display("[L1DSTUCK] c_req=%b c_we=%b c_addr=%08x ws=%b cacheable=%b hit=%b rd_hit=%b st=%0d | m_req=%b m_we=%b m_addr=%08x m_ack=%b fbase=%08x fw=%0d bypass=%b",
                 c_req, c_we, c_addr, c_wstrb, cacheable, hit, rd_hit, st, m_req, m_we, m_addr, m_ack, fbase, fw, bypass_q);
      end
    end
  end
`endif

endmodule : ven_l1d
