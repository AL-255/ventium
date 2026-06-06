// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tools/pipeviz/ventium_viz.h — the C ABI exported by libventium_viz.so.
//
// This is the backend for the PySide6 pipeline visualizer. It wraps the
// Verilator-built Vventium_top model (verilated with --public-flat-rw so every
// internal core/cache/TLB/FPU signal is reachable from C++ via the generated
// `___024root` struct — a cross-module-reference read of the live RTL state) and
// drives the same clk/reset/mem_* loop the production testbench (verif/tb/
// tb_main.cpp) uses, with the dual-issue cycle mode enabled by default so the U
// and V pipes are both exercised.
//
// The struct layout here is mirrored verbatim by the Python ctypes layer
// (pipeviz/backend.py). Keep the two in lock-step. All multi-byte values are
// native little-endian (x86 host == x86 target byte order).
#ifndef VENTIUM_VIZ_H
#define VENTIUM_VIZ_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Geometry mirrors the RTL parameters (rtl/mem/{icache,dcache_timing,tlb}.sv,
// rtl/core/core.sv): 16-byte slow-path prefetch buffer, 16-entry direct-mapped
// split TLB, 128-set/2-way/32-byte L1 caches, 8 GPRs, 6 segments, 8 x87 regs.
enum {
  VV_NSEG        = 6,
  VV_NGPR        = 8,
  VV_NFPR        = 8,
  VV_IBUF        = 16,
  VV_TLB_ENTRIES = 16,
  VV_IC_SETS     = 128,
  VV_DC_SETS     = 128,
  VV_WAYS        = 2,
  VV_LINE        = 32,
  VV_MAXBYTES    = 16
};

// --- live per-cycle architectural + microarchitectural snapshot --------------
// Filled by vv_get_state() from the current (post-eval) RTL state. Everything a
// panel needs to render the "now" frame.
typedef struct {
  uint64_t clk;            // bridge clock count since last reset
  uint32_t core_cyc;       // u_core.core_cyc (RTL clock-count-at-retire base)
  uint32_t state;          // u_core.state (the FSM "pipeline stage", see vv_state_name)
  uint8_t  cpu_hung;       // F00F hang latched

  // front-end / fetch
  uint32_t eip;            // architectural EIP / fast-path fetch pointer
  uint32_t flin;           // linear fetch address feeding the icache fast path
  uint32_t next_eip;
  uint32_t q_pc, q_pc2;    // latched retire PCs (U, V)
  uint8_t  fetch_word;     // slow-path fetch word counter
  uint8_t  ibuf[VV_IBUF];  // slow-path 16-byte prefetch buffer

  // integer architectural state
  uint32_t gpr[VV_NGPR];   // EAX ECX EDX EBX ESP EBP ESI EDI
  uint32_t eflags;
  uint16_t seg_sel[VV_NSEG];   // CS SS DS ES FS GS
  uint32_t seg_base[VV_NSEG];
  uint32_t seg_limit[VV_NSEG];
  uint8_t  seg_attr[VV_NSEG];
  uint32_t cr0, cr2, cr3, cr4; // last-seen (from sys retires; 0 in flat user mode)
  uint8_t  sys_mode;
  uint8_t  cpl;
  uint8_t  smm_active;

  // dual-issue fast-path pipeline scalars
  uint8_t  stall_cnt;          // remaining materialised stall clocks
  uint8_t  mispred_bubbles;    // remaining branch-mispredict flush bubbles
  uint8_t  pending_mem_pen;    // deferred D-cache miss/misalign penalty
  uint8_t  pipe_pair;          // U+V issue together THIS clock
  uint8_t  pipe_pair_ok;       // pairing is legal (pre-gate)

  // prefetch / icache fill sequencing
  uint8_t  pf_word;            // refill word counter (0..7)
  uint32_t pf_fill_addr;       // line base being filled
  uint8_t  pf_fill_way;        // victim way chosen for the fill

  // page-walk
  uint8_t  walk_for_d;         // 0 = I-side walk, 1 = D-side walk
  uint32_t walk_ret_state;     // state to resume after the walk

  // FP latency/occupancy scoreboard + x87 architectural state
  uint8_t  fp_occ_pending;     // an FP op is burning its pipe-occupancy clocks
  uint32_t fp_issue_cyc;       // cycle the in-flight FP op issued
  uint32_t fp_ready_cyc;       // cycle the most-recent FP producer's result is ready
  uint8_t  ftop;               // x87 stack top
  uint8_t  fptag;              // per-physical-register tag byte (bit i -> fpr[i])
  uint16_t fctrl;
  uint16_t fstat;
  uint8_t  fpr[VV_NFPR][10];   // physical fpr[0..7], 80-bit floatx80, little-endian

  // decoded U / V fast-path slots (extracted from the fpd_t packed structs)
  uint8_t  ud_len, vd_len;
  uint8_t  ud_simple, ud_is_load, ud_is_branch, ud_is_fp, ud_pairs_first;
  uint8_t  vd_simple, vd_is_load, vd_is_branch, vd_is_fp, vd_pairs_second;
  uint8_t  ud_aluop, vd_aluop;
  uint8_t  ud_fp_kind, vd_fp_kind;
} vv_state_t;

// --- one TLB entry (per side; 16 of them) ------------------------------------
typedef struct {
  uint8_t  valid;
  uint8_t  big;       // 4 MiB page
  uint8_t  dirty;     // D-TLB only
  uint8_t  perm;      // {US, RW, P}
  uint32_t vpn;       // linear page number (lin[31:12])
  uint32_t pfn;       // physical frame (phys[31:12])
} vv_tlb_t;

// --- one resident cache line -------------------------------------------------
// For the I-cache `data` holds the 32 line bytes; for the D-cache (timing-only,
// no data array) `data` is left zero and only tag/lru/valid are meaningful.
typedef struct {
  uint8_t  set;       // 0..127
  uint8_t  way;       // 0..1
  uint8_t  valid;
  uint8_t  lru;       // way most-recently-used in this set
  uint32_t tag;       // addr[31:12]
  uint8_t  data[VV_LINE];
} vv_cline_t;

// --- one retired instruction (architectural-order ring) ----------------------
typedef struct {
  uint64_t n;                 // retire sequence number
  uint64_t cyc;              // bridge clock the retirement fired on
  uint32_t pc;
  uint32_t eflags;
  uint32_t gpr[VV_NGPR];
  uint16_t seg[VV_NSEG];     // CS SS DS ES FS GS
  uint8_t  pipe;             // 0=U, 1=V, 2=none
  uint8_t  paired;           // issued paired with its sibling
  uint8_t  nbytes;           // instruction length (from memory at pc; capstone refines)
  uint8_t  bytes[VV_MAXBYTES];
  // x87 post-commit snapshot (logical ST(0..7) order), valid when x87_valid
  uint8_t  x87_valid;
  uint16_t fctrl, fstat, ftag;
  uint8_t  st[VV_NFPR][10];
} vv_retire_t;

// --- one sampled clock (microarch timeline ring) -----------------------------
typedef struct {
  uint64_t cyc;              // bridge clock index
  uint32_t state;            // FSM state that clock
  uint32_t eip;
  uint32_t flin;
  uint8_t  stall_cnt;
  uint8_t  mispred_bubbles;
  uint8_t  pending_mem_pen;
  uint8_t  fp_occ_pending;
  uint8_t  pf_word;
  uint8_t  retU, retV;       // a U / V retirement fired this clock
  uint64_t nU, nV;
  uint32_t pcU, pcV;
} vv_cycle_t;

// --- lifecycle / driving -----------------------------------------------------
void*    vv_create(void);
void     vv_destroy(void* h);

// Load a flat binary image into the bus memory at load_addr (returns bytes, -1
// on failure), or raw bytes from a buffer.
long     vv_load_image(void* h, const char* path, uint32_t load_addr);
void     vv_load_bytes(void* h, const uint8_t* data, uint32_t n, uint32_t addr);
uint8_t  vv_mem_read8(void* h, uint32_t addr);
void     vv_mem_read(void* h, uint32_t addr, uint8_t* buf, uint32_t n);
uint32_t vv_sizeof(int which);   // 0=state 1=tlb 2=cline 3=retire 4=cycle

// Cold reset: latch entry/esp, choose cycle_mode (dual issue) + system boot.
void     vv_reset(void* h, uint32_t entry, uint32_t esp, int cycle_mode, int system);

// Advance up to n_clocks core clocks. Stops early on HALT/hang/quiesce. Returns
// the number of clocks actually stepped. If stop_on_retire, stops the instant a
// new instruction retires (single-step-by-instruction).
uint64_t vv_step(void* h, uint32_t n_clocks, int stop_on_retire);
int      vv_is_done(void* h);   // HALT / hung / quiesced

// --- state readers -----------------------------------------------------------
void     vv_get_state(void* h, vv_state_t* out);
int      vv_get_tlb(void* h, int is_d, vv_tlb_t* out /* [16] */);
int      vv_get_icache(void* h, vv_cline_t* out, int max);   // valid lines only
int      vv_get_dcache(void* h, vv_cline_t* out, int max);   // valid lines only

uint64_t vv_retire_count(void* h);                            // total retired
int      vv_get_retires(void* h, uint64_t since_n, vv_retire_t* out, int max);
uint64_t vv_cycle_count(void* h);                             // total clocks sampled
int      vv_get_cycles(void* h, uint64_t since_cyc, vv_cycle_t* out, int max);

// FSM state -> human name (e.g. "S_PIPE"). Returned pointer is static.
const char* vv_state_name(uint32_t state);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // VENTIUM_VIZ_H
