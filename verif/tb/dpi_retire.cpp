// verif/tb/dpi_retire.cpp
//
// Producer C: the C++ implementation of the RTL's vtm_retire DPI callback.
// The RTL core imports vtm_retire (docs/rtl-interface.md §2) and calls it once
// per retired instruction in architectural order, passing the fetch PC and the
// post-commit architectural state. We turn each call into ONE func-mode
// .vtrace line (docs/trace-format.md §2.1/§2.2), written to the trace file
// opened by tb_main.
//
// Field names and hex formatting MUST match verif/diff/tracefmt.py exactly
// (the comparator parses by field name): lowercase, zero-padded, "0x%08x" for
// 32-bit values and "0x%04x" for 16-bit selectors.

#include <cstdint>
#include <cstdio>

#include "trace_writer.h"

// Verilator emits the DPI-C prototype for vtm_retire into
// obj_dir/Vventium_top__Dpi.h after verilating. We include it (when present)
// so our definition is type-checked against the generated prototype. The
// build adds -Iobj_dir to CFLAGS; if the header is absent (e.g. some standalone
// compile), the fallback prototype below keeps the C types identical to the
// SystemVerilog mapping documented in the task:
//   longint unsigned  -> unsigned long long  (svBitVecVal 64 / uint64_t)
//   int unsigned      -> uint32_t
//   shortint unsigned -> uint16_t (passed widened; Verilator uses (s)vUint).
#if defined(__has_include)
#  if __has_include("Vventium_top__Dpi.h")
#    include "Vventium_top__Dpi.h"
#    define VTM_HAVE_DPI_HEADER 1
#  endif
#endif

// The active trace writer for the current run. Owned/configured by tb_main
// (it opens the file and writes the header before clocking begins). A single
// global is sufficient: the testbench runs one core, single-threaded, and
// Verilator calls DPI imports synchronously from eval().
namespace ventium {
TraceWriter* g_trace = nullptr;
}  // namespace ventium

// Match the SystemVerilog import signatures from docs/rtl-interface.md §2.
// When Verilator's generated header is present it already declares these with
// extern "C"; we provide the bodies. Otherwise we declare+define them ourselves.
//
// vtm_retire_x87 passing convention (ventium_pkg.sv / rtl-interface.md §2):
//   each st(i) split as longint unsigned mantissa lo (uint64_t) +
//   shortint unsigned sign/exp hi (uint16_t, passed widened); fctrl/fstat/ftag
//   as int unsigned (uint32_t, 16-bit value in a 32b slot).
#ifndef VTM_HAVE_DPI_HEADER
extern "C" void vtm_retire(
    unsigned long long n,
    unsigned int pc,
    unsigned int eflags,
    unsigned int eax, unsigned int ecx,
    unsigned int edx, unsigned int ebx,
    unsigned int esp, unsigned int ebp,
    unsigned int esi, unsigned int edi,
    unsigned short cs, unsigned short ss,
    unsigned short ds, unsigned short es,
    unsigned short fs, unsigned short gs);
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
    unsigned long long st7_lo, unsigned short st7_hi);
// vtm_retire_cycle (M4): pipe 0=U/1=V/2=none, paired 0/1. int unsigned -> uint32.
extern "C" void vtm_retire_cycle(
    unsigned long long n, unsigned int pipe, unsigned int paired);
#endif

// x87 retire (M3): the core calls this with the SAME `n` as the paired
// vtm_retire, carrying the post-commit x87 state. We stash it keyed by `n`; the
// paired vtm_retire drains it and emits one combined record. No file write here.
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
    using namespace ventium;
    if (!g_trace) return;
    X87State s;
    s.st_lo[0] = st0_lo; s.st_hi[0] = st0_hi;
    s.st_lo[1] = st1_lo; s.st_hi[1] = st1_hi;
    s.st_lo[2] = st2_lo; s.st_hi[2] = st2_hi;
    s.st_lo[3] = st3_lo; s.st_hi[3] = st3_hi;
    s.st_lo[4] = st4_lo; s.st_hi[4] = st4_hi;
    s.st_lo[5] = st5_lo; s.st_hi[5] = st5_hi;
    s.st_lo[6] = st6_lo; s.st_hi[6] = st6_hi;
    s.st_lo[7] = st7_lo; s.st_hi[7] = st7_hi;
    s.fctrl = (unsigned short)(fctrl & 0xFFFFu);
    s.fstat = (unsigned short)(fstat & 0xFFFFu);
    s.ftag  = (unsigned short)(ftag  & 0xFFFFu);
    g_trace->stash_x87(n, s);
}

// cycle retire (M4): the pipeline core calls this with the SAME `n` as the
// paired vtm_retire, reporting which pipe the instruction issued to (0=U,1=V,
// 2=none) and whether it issued paired with its sibling. We stash it keyed by
// `n`; the paired vtm_retire drains it and (in --cycle mode) emits one cycle
// record stamping the TB clock as cyc. No file write here. This is a no-op in
// func mode (the stash is simply never drained) — harmless.
extern "C" void vtm_retire_cycle(
    unsigned long long n, unsigned int pipe, unsigned int paired) {
    using namespace ventium;
    if (!g_trace) return;
    CycleInfo ci;
    ci.pipe   = (unsigned char)(pipe > 2u ? 2u : pipe);  // clamp to {0,1,2}
    ci.paired = (paired != 0u);
    g_trace->stash_cycle(n, ci);
}

extern "C" void vtm_retire(
    unsigned long long n,
    unsigned int pc,
    unsigned int eflags,
    unsigned int eax, unsigned int ecx,
    unsigned int edx, unsigned int ebx,
    unsigned int esp, unsigned int ebp,
    unsigned int esi, unsigned int edi,
    unsigned short cs, unsigned short ss,
    unsigned short ds, unsigned short es,
    unsigned short fs, unsigned short gs) {
    using namespace ventium;
    if (!g_trace || !g_trace->ok()) return;

    // --- cycle mode (M4): emit a cycle-mode record instead of the func one ---
    // The integer/system architectural state is irrelevant in cycle mode; we
    // emit {n, pc, cyc, pipe, paired} (docs/trace-format.md §2.3). `cyc` is the
    // TB-owned clock count at this retirement (paired insns share it because
    // both vtm_retire calls fire in the same rising-edge eval, reading the same
    // clock). pipe/paired come from the core's vtm_retire_cycle stash for this
    // `n`; absent -> pipe=U paired=false (well-formed). The `bytes` field is not
    // available at the retire callback (only post-state regs are), so we omit it
    // — the cycle comparator aligns by n and sanity-checks pc, neither of which
    // needs bytes.
    if (g_trace->cycle()) {
        bool present = false;
        CycleInfo ci = g_trace->take_cycle((uint64_t)n, &present);
        const char* pipe_str = (ci.pipe == 0) ? "U"
                             : (ci.pipe == 1) ? "V"
                                              : "-";
        std::fprintf(g_trace->fp(),
            "{\"n\":%llu,\"pc\":\"0x%08x\",\"cyc\":%llu,"
            "\"pipe\":\"%s\",\"paired\":%s}\n",
            (unsigned long long)n,
            pc,
            (unsigned long long)g_trace->clock(),
            pipe_str,
            ci.paired ? "true" : "false");
        (void)present;  // absence already yields pipe=U paired=false
        g_trace->note_retire();
        return;
    }

    // Emit one compact JSON object on its own line. Field order is irrelevant
    // to the comparator (it parses by name), but we follow the canonical
    // compare order (pc, GPRs, eflags, segs[, x87]) from
    // tracefmt.func_compare_keys for readable diffs. 32-bit -> 0x%08x, 16-bit ->
    // 0x%04x (tracefmt.hx). The integer prefix is identical in both modes.
    std::fprintf(g_trace->fp(),
        "{\"n\":%llu,"
        "\"pc\":\"0x%08x\","
        "\"eax\":\"0x%08x\",\"ecx\":\"0x%08x\","
        "\"edx\":\"0x%08x\",\"ebx\":\"0x%08x\","
        "\"esp\":\"0x%08x\",\"ebp\":\"0x%08x\","
        "\"esi\":\"0x%08x\",\"edi\":\"0x%08x\","
        "\"eflags\":\"0x%08x\","
        "\"cs\":\"0x%04x\",\"ss\":\"0x%04x\","
        "\"ds\":\"0x%04x\",\"es\":\"0x%04x\","
        "\"fs\":\"0x%04x\",\"gs\":\"0x%04x\"",
        (unsigned long long)n,
        pc,
        eax, ecx, edx, ebx, esp, ebp, esi, edi,
        eflags,
        (unsigned)cs, (unsigned)ss, (unsigned)ds,
        (unsigned)es, (unsigned)fs, (unsigned)gs);

    // x87 fields (only when the trace header declares x87:true). Drain the
    // x87 state the core stashed via vtm_retire_x87 for this same `n`; if the
    // core did not call it for this retirement, emit zeros (still well-formed).
    // Formats MUST match tracefmt.py: st0..st7 = 80-bit (20 hex digits) as
    // hi(16)<<64 | lo(64); fctrl/fstat/ftag = 16-bit (4 digits); the untracked
    // pointer fields fop/fiseg/foseg = 16-bit 0, fioff/fooff = 32-bit 0.
    if (g_trace->x87()) {
        bool present = false;
        X87State s = g_trace->take_x87((uint64_t)n, &present);
        for (int i = 0; i < 8; ++i) {
            // 80-bit canonical floatx80: print high 16 bits then low 64 bits,
            // zero-padded to 4 + 16 = 20 hex digits.
            std::fprintf(g_trace->fp(),
                ",\"st%d\":\"0x%04x%016llx\"",
                i, (unsigned)s.st_hi[i], (unsigned long long)s.st_lo[i]);
        }
        std::fprintf(g_trace->fp(),
            ",\"fctrl\":\"0x%04x\",\"fstat\":\"0x%04x\",\"ftag\":\"0x%04x\","
            "\"fop\":\"0x%04x\","
            "\"fioff\":\"0x%08x\",\"fooff\":\"0x%08x\","
            "\"fiseg\":\"0x%04x\",\"foseg\":\"0x%04x\"",
            (unsigned)s.fctrl, (unsigned)s.fstat, (unsigned)s.ftag,
            0u, 0u, 0u, 0u, 0u);
        (void)present;  // absence already yields zeros; nothing else to do
    }

    std::fprintf(g_trace->fp(), "}\n");

    g_trace->note_retire();
}
