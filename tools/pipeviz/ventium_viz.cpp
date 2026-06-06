// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tools/pipeviz/ventium_viz.cpp — the Verilator backend for the pipeline
// visualizer. Wraps Vventium_top (verilated with --public-flat-rw), drives the
// same clk/reset/mem_* loop the production TB uses (verif/tb/tb_main.cpp), and
// reads the live internal core/cache/TLB/FPU state through the generated
// `___024root` struct (the cross-module-reference read the task calls for).
//
// The four vtm_retire* DPI callbacks the RTL invokes (ventium_pkg.sv /
// rtl/core/core.sv) are implemented here to capture each retirement into a ring
// buffer, instead of the TB's .vtrace writer. A per-clock microarch sample ring
// feeds the timeline panel.

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <deque>
#include <unordered_map>
#include <vector>

#include "verilated.h"
#include "Vventium_top.h"
#include "Vventium_top___024root.h"   // full root struct -> internal-signal access
#if __has_include("Vventium_top__Dpi.h")
#  include "Vventium_top__Dpi.h"      // generated DPI prototypes (signature check)
#endif

#include "memmodel.h"                 // verif/tb/memmodel.h (reused BFM memory)
#include "ventium_viz.h"

using ventium::MemModel;

// ---------------------------------------------------------------------------
// Hierarchical-signal access helpers. With --public-flat-rw every RTL signal is
// a public member of the root struct, named <path>__DOT__<sig> with '.' -> __DOT__.
// ---------------------------------------------------------------------------
#define CORE(f)   (R->ventium_top__DOT__u_core__DOT__##f)
#define ICACHE(f) (R->ventium_top__DOT__u_core__DOT__u_icache__DOT__##f)
#define DCACHE(f) (R->ventium_top__DOT__u_core__DOT__u_dcache_tm__DOT__##f)
#define ITLB(f)   (R->ventium_top__DOT__u_core__DOT__u_itlb__DOT__##f)
#define DTLB(f)   (R->ventium_top__DOT__u_core__DOT__u_dtlb__DOT__##f)
#define FPU(f)    (R->ventium_top__DOT__u_core__DOT__u_fpu_state__DOT__##f)

// ---- fpd_t packed-struct bit offsets (ventium_decode_pkg.sv, LSB-relative) --
// fpd_t is 160 bits; the first declared field is the MSB. These are the LSB
// positions of the fields the visualizer surfaces. (If fpd_t changes, only the
// U/V slot decoration is affected; nothing crashes.)
enum {
  FPD_FP_OCC_LSB     = 0,   // [6:0]
  FPD_IS_FP_LSB      = 26,
  FPD_FP_KIND_LSB    = 23,  // [25:23]
  FPD_PAIRS_SEC_LSB  = 29,
  FPD_PAIRS_FIRST_LSB= 30,
  FPD_IS_BRANCH_LSB  = 93,
  FPD_IS_LOAD_LSB    = 107,
  FPD_ALU_OP_LSB     = 150, // [154:150]
  FPD_LEN_LSB        = 155, // [158:155]
  FPD_SIMPLE_LSB     = 159
};

static inline uint32_t w5fld(const VlWide<5>& w, int lsb, int width) {
  uint32_t v = 0;
  for (int i = 0; i < width; ++i) {
    int b = lsb + i;
    v |= (((uint32_t)(w[b >> 5] >> (b & 31)) & 1u) << i);
  }
  return v;
}

// ---------------------------------------------------------------------------
// The visualizer instance.
// ---------------------------------------------------------------------------
namespace {

struct RawRetire {           // assembled across the per-n DPI calls
  vv_retire_t rec{};
};

struct Viz {
  Vventium_top* top = nullptr;
  MemModel      mem;

  bool     in_reset = true;
  bool     done     = false;
  int      cycle_mode = 1;     // dual-issue by default so the V pipe is exercised
  int      system     = 0;
  uint64_t clk        = 0;     // completed clocks since reset
  uint64_t cur_cyc    = 0;     // clock index being evaluated (for retire stamping)
  uint32_t idle       = 0;     // consecutive clocks with no retirement
  uint32_t quiesce    = 256;

  // last-seen control registers (only sys retires carry them; flat user => 0)
  uint32_t cr0 = 0, cr2 = 0, cr3 = 0, cr4 = 0;

  // retirement ring (architectural order)
  std::deque<vv_retire_t> retires;
  uint64_t retire_total = 0;
  uint64_t retire_base  = 0;   // n of retires.front()

  // per-clock microarch sample ring
  std::deque<vv_cycle_t>  cycles;
  uint64_t cycle_total = 0;
  uint64_t cycle_base  = 0;

  // DPI scratch for the clock currently being evaluated
  std::unordered_map<uint64_t, vv_retire_t>           pend;       // n -> partial
  std::vector<vv_retire_t>                            clk_retires; // finalized this clk

  static constexpr size_t RETIRE_CAP = 200000;
  static constexpr size_t CYCLE_CAP  = 400000;
};

Viz* g_viz = nullptr;   // single core, single thread: a global is sufficient

}  // namespace

// ---------------------------------------------------------------------------
// DPI callbacks invoked by the RTL during the rising-edge eval(). Mirrors the
// stash/finalize structure of verif/tb/dpi_retire.cpp, but captures into rings.
// ---------------------------------------------------------------------------
extern "C" void vtm_retire_x87(
    unsigned long long n,
    unsigned int fctrl, unsigned int fstat, unsigned int ftag,
    unsigned long long st0_lo, unsigned short st0_hi,
    unsigned long long st1_lo, unsigned short st1_hi,
    unsigned long long st2_lo, unsigned short st2_hi,
    unsigned long long st3_lo, unsigned short st3_hi,
    unsigned long long st4_lo, unsigned short st4_hi,
    unsigned long long st5_lo, unsigned short st5_hi,
    unsigned long long st6_lo, unsigned short st6_hi,
    unsigned long long st7_lo, unsigned short st7_hi) {
  if (!g_viz) return;
  vv_retire_t& r = g_viz->pend[n];
  r.x87_valid = 1;
  r.fctrl = (uint16_t)fctrl; r.fstat = (uint16_t)fstat; r.ftag = (uint16_t)ftag;
  const unsigned long long lo[8] = {st0_lo,st1_lo,st2_lo,st3_lo,st4_lo,st5_lo,st6_lo,st7_lo};
  const unsigned short     hi[8] = {st0_hi,st1_hi,st2_hi,st3_hi,st4_hi,st5_hi,st6_hi,st7_hi};
  for (int i = 0; i < 8; ++i) {
    for (int b = 0; b < 8; ++b) r.st[i][b] = (uint8_t)(lo[i] >> (8*b));
    r.st[i][8] = (uint8_t)(hi[i] & 0xff);
    r.st[i][9] = (uint8_t)((hi[i] >> 8) & 0xff);
  }
}

extern "C" void vtm_retire_cycle(unsigned long long n, unsigned int pipe, unsigned int paired) {
  if (!g_viz) return;
  vv_retire_t& r = g_viz->pend[n];
  r.pipe   = (uint8_t)(pipe > 2u ? 2u : pipe);
  r.paired = (uint8_t)(paired != 0u);
}

extern "C" void vtm_retire_sys(unsigned long long n, unsigned int cr0,
                               unsigned int cr2, unsigned int cr3, unsigned int cr4) {
  if (!g_viz) return;
  g_viz->cr0 = cr0; g_viz->cr2 = cr2; g_viz->cr3 = cr3; g_viz->cr4 = cr4;
  (void)n;
}

extern "C" void vtm_retire(
    unsigned long long n, unsigned int pc, unsigned int eflags,
    unsigned int eax, unsigned int ecx, unsigned int edx, unsigned int ebx,
    unsigned int esp, unsigned int ebp, unsigned int esi, unsigned int edi,
    unsigned short cs, unsigned short ss, unsigned short ds, unsigned short es,
    unsigned short fs, unsigned short gs) {
  if (!g_viz) return;
  Viz* v = g_viz;
  vv_retire_t r{};
  auto it = v->pend.find(n);
  if (it != v->pend.end()) { r = it->second; v->pend.erase(it); }
  else { r.pipe = 0; r.paired = 0; }
  r.n = n;
  r.cyc = v->cur_cyc;
  r.pc = pc; r.eflags = eflags;
  r.gpr[0]=eax; r.gpr[1]=ecx; r.gpr[2]=edx; r.gpr[3]=ebx;
  r.gpr[4]=esp; r.gpr[5]=ebp; r.gpr[6]=esi; r.gpr[7]=edi;
  r.seg[0]=cs; r.seg[1]=ss; r.seg[2]=ds; r.seg[3]=es; r.seg[4]=fs; r.seg[5]=gs;
  // instruction bytes: read up to 16 from the BFM memory at the fetch PC (code
  // is stable post-commit). In flat user mode pc==linear==physical; capstone in
  // the GUI refines the true length. (System-mode paged code is best-effort.)
  r.nbytes = VV_MAXBYTES;
  for (int i = 0; i < VV_MAXBYTES; ++i) r.bytes[i] = v->mem.read8(pc + (uint32_t)i);
  v->clk_retires.push_back(r);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------
namespace {

void service_bus(Viz* v) {
  Vventium_top* top = v->top;
  uint32_t rdata = 0; bool ack = false;
  v->mem.service((bool)top->mem_req, (bool)top->mem_we,
                 (uint32_t)top->mem_addr, (uint32_t)top->mem_wdata,
                 (uint8_t)top->mem_wstrb, &rdata, &ack);
  top->mem_rdata = rdata;
  top->mem_ack   = ack;
}

// Drive every optional/secondary input to its inert value (no proxy, no cosim,
// no pin-level bus, no errata, no external interrupts).
void tie_off_inputs(Vventium_top* top) {
  top->bus_mode  = 0;
  top->errata_en = 0;
  top->proxy_en  = 0;
  top->cosim_en  = 0;
  top->syscall_resume_eip = 0;
  top->syscall_eax        = 0;
  top->syscall_apply_gs   = 0;
  top->syscall_gs_base    = 0;
  top->io_rdata = 0;
  top->io_ack   = 0;
  top->mem_rdata = 0;
  top->mem_ack   = 0;
}

// Push a finalized retire into the ring (bounded).
void push_retire(Viz* v, const vv_retire_t& r) {
  v->retires.push_back(r);
  v->retire_total = r.n + 1;
  while (v->retires.size() > Viz::RETIRE_CAP) { v->retires.pop_front(); v->retire_base++; }
}

void push_cycle(Viz* v, const vv_cycle_t& c) {
  v->cycles.push_back(c);
  v->cycle_total = c.cyc + 1;
  while (v->cycles.size() > Viz::CYCLE_CAP) { v->cycles.pop_front(); v->cycle_base++; }
}

// One full core clock (low phase settle + rising-edge work), matching tb_main.
// Returns true if a retirement fired this clock.
bool clock_once(Viz* v) {
  Vventium_top* top = v->top;
  v->clk_retires.clear();

  // clk low: combinational settle + serve the bus
  top->clk = 0;
  service_bus(v); top->eval();
  service_bus(v); top->eval();

  // stamp the clock the about-to-fire retirements belong to (1-based, matching
  // the TB: core_cyc is the count of completed clocks before this edge).
  v->cur_cyc = v->clk + 1;

  // clk high: rising edge; the vtm_retire* DPI calls fire inside eval()
  top->clk = 1;
  service_bus(v); top->eval();
  service_bus(v); top->eval();

  v->clk += 1;

  // sample the microarch state for this clock + fold in any retirements
  auto* R = top->rootp;
  vv_cycle_t c{};
  c.cyc = v->clk;            // 1-based, matches retire cyc
  c.state = CORE(state);
  c.eip = CORE(eip);
  c.flin = CORE(flin);
  c.stall_cnt = CORE(stall_cnt);
  c.mispred_bubbles = CORE(mispred_bubbles);
  c.pending_mem_pen = CORE(pending_mem_pen);
  c.fp_occ_pending = CORE(fp_occ_pending);
  c.pf_word = CORE(pf_word);

  bool retired = false;
  for (auto& r : v->clk_retires) {
    push_retire(v, r);
    retired = true;
    if (r.pipe == 1) { c.retV = 1; c.nV = r.n; c.pcV = r.pc; }
    else             { c.retU = 1; c.nU = r.n; c.pcU = r.pc; }
  }
  push_cycle(v, c);

  if (top->cpu_hung) v->done = true;
  return retired;
}

}  // namespace

// ===========================================================================
// C ABI
// ===========================================================================
extern "C" {

void* vv_create(void) {
  Viz* v = new Viz();
  static bool inited = false;
  if (!inited) { const char* a[] = {"ventium_viz"}; Verilated::commandArgs(1, a); inited = true; }
  v->top = new Vventium_top();
  return v;
}

void vv_destroy(void* h) {
  Viz* v = (Viz*)h;
  if (!v) return;
  if (g_viz == v) g_viz = nullptr;
  if (v->top) { v->top->final(); delete v->top; }
  delete v;
}

long vv_load_image(void* h, const char* path, uint32_t load_addr) {
  Viz* v = (Viz*)h;
  return v->mem.load_image(path, load_addr);
}

void vv_load_bytes(void* h, const uint8_t* data, uint32_t n, uint32_t addr) {
  Viz* v = (Viz*)h;
  for (uint32_t i = 0; i < n; ++i) v->mem.write8(addr + i, data[i]);
}

uint8_t vv_mem_read8(void* h, uint32_t addr) {
  Viz* v = (Viz*)h;
  return v->mem.read8(addr);
}

void vv_mem_read(void* h, uint32_t addr, uint8_t* buf, uint32_t n) {
  Viz* v = (Viz*)h;
  for (uint32_t i = 0; i < n; ++i) buf[i] = v->mem.read8(addr + i);
}

// ABI sanity-check for the Python ctypes mirror: 0=state 1=tlb 2=cline 3=retire 4=cycle.
uint32_t vv_sizeof(int which) {
  switch (which) {
    case 0: return (uint32_t)sizeof(vv_state_t);
    case 1: return (uint32_t)sizeof(vv_tlb_t);
    case 2: return (uint32_t)sizeof(vv_cline_t);
    case 3: return (uint32_t)sizeof(vv_retire_t);
    case 4: return (uint32_t)sizeof(vv_cycle_t);
    default: return 0;
  }
}

void vv_reset(void* h, uint32_t entry, uint32_t esp, int cycle_mode, int system) {
  Viz* v = (Viz*)h;
  g_viz = v;                 // route DPI callbacks to this instance
  Vventium_top* top = v->top;

  v->cycle_mode = cycle_mode;
  v->system = system;
  v->clk = 0; v->cur_cyc = 0; v->idle = 0; v->done = false;
  v->retires.clear(); v->cycles.clear(); v->pend.clear(); v->clk_retires.clear();
  v->retire_total = v->retire_base = 0;
  v->cycle_total = v->cycle_base = 0;
  v->cr0 = v->cr2 = v->cr3 = v->cr4 = 0;

  top->clk = 0;
  top->rst_n = 0;
  top->init_eip = entry;
  top->init_esp = esp;
  top->boot_mode = system ? 1 : 0;
  top->cycle_mode = cycle_mode ? 1 : 0;
  tie_off_inputs(top);
  top->eval();

  const int kResetClocks = 4;
  for (int c = 0; c < kResetClocks; ++c) {
    top->clk = 0; service_bus(v); top->eval();
    top->clk = 1; service_bus(v); top->eval();
  }
  top->rst_n = 1;
  v->in_reset = false;
}

uint64_t vv_step(void* h, uint32_t n_clocks, int stop_on_retire) {
  Viz* v = (Viz*)h;
  g_viz = v;
  uint64_t stepped = 0;
  for (uint32_t i = 0; i < n_clocks; ++i) {
    if (v->done) break;
    bool retired = clock_once(v);
    stepped++;
    if (retired) v->idle = 0; else v->idle++;
    if (v->idle >= v->quiesce) { v->done = true; break; }
    if (Verilated::gotFinish()) { v->done = true; break; }
    if (stop_on_retire && retired) break;
  }
  return stepped;
}

int vv_is_done(void* h) { return ((Viz*)h)->done ? 1 : 0; }

void vv_get_state(void* h, vv_state_t* out) {
  Viz* v = (Viz*)h;
  auto* R = v->top->rootp;
  std::memset(out, 0, sizeof(*out));

  out->clk = v->clk;
  out->core_cyc = CORE(core_cyc);
  out->state = CORE(state);
  out->cpu_hung = v->top->cpu_hung ? 1 : 0;

  out->eip = CORE(eip);
  out->flin = CORE(flin);
  out->next_eip = CORE(next_eip);
  out->q_pc = CORE(q_pc);
  out->q_pc2 = CORE(q_pc2);
  out->fetch_word = CORE(fetch_word);
  for (int i = 0; i < VV_IBUF; ++i) out->ibuf[i] = CORE(ibuf)[i];

  for (int i = 0; i < VV_NGPR; ++i) out->gpr[i] = CORE(gpr)[i];
  out->eflags = CORE(eflags);
  for (int i = 0; i < VV_NSEG; ++i) {
    out->seg_sel[i]   = CORE(seg_sel)[i];
    out->seg_base[i]  = CORE(seg_base)[i];
    out->seg_limit[i] = CORE(seg_limit)[i];
    out->seg_attr[i]  = CORE(seg_attr)[i];
  }
  out->cr0 = v->cr0; out->cr2 = v->cr2; out->cr3 = v->cr3; out->cr4 = v->cr4;
  out->sys_mode = CORE(sys_mode);
  out->cpl = CORE(cpl_r);
  out->smm_active = CORE(smm_active);

  out->stall_cnt = CORE(stall_cnt);
  out->mispred_bubbles = CORE(mispred_bubbles);
  out->pending_mem_pen = CORE(pending_mem_pen);
  out->pipe_pair = CORE(pipe_pair);
  out->pipe_pair_ok = CORE(pipe_pair_ok);

  out->pf_word = CORE(pf_word);
  out->pf_fill_addr = CORE(pf_fill_addr);
  out->pf_fill_way = CORE(pf_fill_way);

  out->walk_for_d = CORE(walk_for_d);
  out->walk_ret_state = CORE(walk_ret_state);

  out->fp_occ_pending = CORE(fp_occ_pending);
  out->fp_issue_cyc = CORE(fp_issue_cyc);
  out->fp_ready_cyc = CORE(fp_ready_cyc);
  out->ftop = CORE(u_fpu_state__DOT__ftop);
  out->fptag = CORE(u_fpu_state__DOT__fptag);
  out->fctrl = CORE(u_fpu_state__DOT__fctrl);
  out->fstat = CORE(u_fpu_state__DOT__fstat);
  for (int i = 0; i < VV_NFPR; ++i) {
    const VlWide<3>& r = FPU(fpr)[i];
    uint32_t w0 = r[0], w1 = r[1], w2 = r[2];
    out->fpr[i][0]=(uint8_t)w0; out->fpr[i][1]=(uint8_t)(w0>>8);
    out->fpr[i][2]=(uint8_t)(w0>>16); out->fpr[i][3]=(uint8_t)(w0>>24);
    out->fpr[i][4]=(uint8_t)w1; out->fpr[i][5]=(uint8_t)(w1>>8);
    out->fpr[i][6]=(uint8_t)(w1>>16); out->fpr[i][7]=(uint8_t)(w1>>24);
    out->fpr[i][8]=(uint8_t)w2; out->fpr[i][9]=(uint8_t)(w2>>8);
  }

  const VlWide<5>& ud = CORE(u_d);
  const VlWide<5>& vd = CORE(v_d);
  out->ud_len = w5fld(ud, FPD_LEN_LSB, 4);
  out->vd_len = w5fld(vd, FPD_LEN_LSB, 4);
  out->ud_simple = w5fld(ud, FPD_SIMPLE_LSB, 1);
  out->vd_simple = w5fld(vd, FPD_SIMPLE_LSB, 1);
  out->ud_is_load = w5fld(ud, FPD_IS_LOAD_LSB, 1);
  out->vd_is_load = w5fld(vd, FPD_IS_LOAD_LSB, 1);
  out->ud_is_branch = w5fld(ud, FPD_IS_BRANCH_LSB, 1);
  out->vd_is_branch = w5fld(vd, FPD_IS_BRANCH_LSB, 1);
  out->ud_is_fp = w5fld(ud, FPD_IS_FP_LSB, 1);
  out->vd_is_fp = w5fld(vd, FPD_IS_FP_LSB, 1);
  out->ud_pairs_first = w5fld(ud, FPD_PAIRS_FIRST_LSB, 1);
  out->vd_pairs_second = w5fld(vd, FPD_PAIRS_SEC_LSB, 1);
  out->ud_aluop = w5fld(ud, FPD_ALU_OP_LSB, 5);
  out->vd_aluop = w5fld(vd, FPD_ALU_OP_LSB, 5);
  out->ud_fp_kind = w5fld(ud, FPD_FP_KIND_LSB, 3);
  out->vd_fp_kind = w5fld(vd, FPD_FP_KIND_LSB, 3);
}

int vv_get_tlb(void* h, int is_d, vv_tlb_t* out) {
  Viz* v = (Viz*)h;
  auto* R = v->top->rootp;
  for (int i = 0; i < VV_TLB_ENTRIES; ++i) {
    if (is_d) {
      out[i].valid = DTLB(tlb_val)[i]; out[i].big = DTLB(tlb_big)[i];
      out[i].dirty = DTLB(tlb_dirty)[i]; out[i].perm = DTLB(tlb_perm)[i];
      out[i].vpn = DTLB(tlb_vpn)[i]; out[i].pfn = DTLB(tlb_pfn)[i];
    } else {
      out[i].valid = ITLB(tlb_val)[i]; out[i].big = ITLB(tlb_big)[i];
      out[i].dirty = 0; out[i].perm = ITLB(tlb_perm)[i];
      out[i].vpn = ITLB(tlb_vpn)[i]; out[i].pfn = ITLB(tlb_pfn)[i];
    }
  }
  return VV_TLB_ENTRIES;
}

int vv_get_icache(void* h, vv_cline_t* out, int max) {
  Viz* v = (Viz*)h;
  auto* R = v->top->rootp;
  int n = 0;
  for (int s = 0; s < VV_IC_SETS && n < max; ++s) {
    for (int w = 0; w < VV_WAYS && n < max; ++w) {
      if (!ICACHE(ic_val)[s][w]) continue;
      vv_cline_t& c = out[n++];
      c.set = (uint8_t)s; c.way = (uint8_t)w; c.valid = 1;
      c.lru = ICACHE(ic_lru)[s];
      c.tag = ICACHE(ic_tag)[s][w];
      for (int b = 0; b < VV_LINE; ++b) c.data[b] = ICACHE(ic_data)[s][w][b];
    }
  }
  return n;
}

int vv_get_dcache(void* h, vv_cline_t* out, int max) {
  Viz* v = (Viz*)h;
  auto* R = v->top->rootp;
  int n = 0;
  for (int s = 0; s < VV_DC_SETS && n < max; ++s) {
    for (int w = 0; w < VV_WAYS && n < max; ++w) {
      if (!DCACHE(dc_val)[s][w]) continue;
      vv_cline_t& c = out[n++];
      c.set = (uint8_t)s; c.way = (uint8_t)w; c.valid = 1;
      c.lru = DCACHE(dc_lru)[s];
      c.tag = DCACHE(dc_tag)[s][w];
      std::memset(c.data, 0, VV_LINE);   // timing-only D-cache: no data array
    }
  }
  return n;
}

uint64_t vv_retire_count(void* h) { return ((Viz*)h)->retire_total; }

// Copy retires with n >= since_n. Indexing is anchored to the live front
// element's id, so it is correct regardless of how many have been evicted.
int vv_get_retires(void* h, uint64_t since_n, vv_retire_t* out, int max) {
  Viz* v = (Viz*)h;
  if (v->retires.empty()) return 0;
  uint64_t front_n = v->retires.front().n;
  uint64_t back_n  = v->retires.back().n;
  uint64_t start = since_n < front_n ? front_n : since_n;
  int n = 0;
  for (uint64_t k = start; k <= back_n && n < max; ++k)
    out[n++] = v->retires[(size_t)(k - front_n)];
  return n;
}

uint64_t vv_cycle_count(void* h) { return ((Viz*)h)->clk; }

// Copy per-clock samples with cyc >= since_cyc (cyc is 1-based; the front
// element's cyc anchors the deque index).
int vv_get_cycles(void* h, uint64_t since_cyc, vv_cycle_t* out, int max) {
  Viz* v = (Viz*)h;
  if (v->cycles.empty()) return 0;
  uint64_t front_cyc = v->cycles.front().cyc;
  uint64_t back_cyc  = v->cycles.back().cyc;
  uint64_t start = since_cyc < front_cyc ? front_cyc : since_cyc;
  int n = 0;
  for (uint64_t k = start; k <= back_cyc && n < max; ++k)
    out[n++] = v->cycles[(size_t)(k - front_cyc)];
  return n;
}

const char* vv_state_name(uint32_t s) {
  // mirrors the state_e enum order in rtl/core/core.sv (typedef enum logic[5:0]).
  static const char* names[] = {
    "S_RESET","S_FETCH","S_DECODE","S_LOAD","S_LOAD2","S_EXEC","S_STORE","S_USEQ",
    "S_HALT","S_FLOAD","S_FEXEC","S_FSTORE","S_FENV_ST","S_FENV_LD","S_IO","S_INS",
    "S_PF","S_PIPE","S_F00F_HANG","S_LGDT","S_SEGLD","S_LJMP","S_WALK","S_INT_GATE",
    "S_INT_CS","S_INT_PUSH","S_IRET","S_INT_CS_RET","S_LTR","S_INT_TSS","S_INT_SS",
    "S_IRET_SS","S_TSW_SAVE","S_TSW_READ","S_TSW_SEG","S_TSW_BUSY","S_SMI_SAVE",
    "S_RSM","S_DB_EXTRA"
  };
  if (s < sizeof(names)/sizeof(names[0])) return names[s];
  return "S_?";
}

}  // extern "C"
