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

// Match the SystemVerilog import signature from docs/rtl-interface.md §2.
// When Verilator's generated header is present it already declares this with
// extern "C"; we provide the body. Otherwise we declare+define it ourselves.
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
#endif

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

    // Emit one compact JSON object on its own line. Field order is irrelevant
    // to the comparator (it parses by name), but we follow the canonical
    // compare order (pc, GPRs, eflags, segs) from tracefmt.func_compare_keys
    // for readable diffs. 32-bit -> 0x%08x, 16-bit -> 0x%04x (tracefmt.hx).
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
        "\"fs\":\"0x%04x\",\"gs\":\"0x%04x\"}\n",
        (unsigned long long)n,
        pc,
        eax, ecx, edx, ebx, esp, ebp, esi, edi,
        eflags,
        (unsigned)cs, (unsigned)ss, (unsigned)ds,
        (unsigned)es, (unsigned)fs, (unsigned)gs);

    g_trace->note_retire();
}
