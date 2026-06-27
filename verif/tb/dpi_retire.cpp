// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

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
#include <unordered_map>

#include "trace_writer.h"

// --exec-written-check: flag the first retired insn fetched from a byte that was
// written (as data) at/after g_exec_floor — the F3 divergence point where the core
// starts executing recently-written data as code. DEFINED here (dpi_retire.cpp is
// linked by EVERY testbench, incl. the core tb that make verify builds); tb_soc.cpp
// externs + populates these. Default-off, so a no-op everywhere but the soc gap-walk.
std::unordered_map<uint32_t, uint64_t> g_wcyc;
uint64_t g_exec_floor = 0;
bool     g_exec_check = false;
uint64_t g_now_cycle  = 0;

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

// M14 checkpoint support: the latest retired architectural state (struct in
// trace_writer.h), updated every vtm_retire so the periodic-checkpoint path
// (free-run) can save complete state (these regs + the MemModel snapshot).
LastArch g_last_arch;
// task #102 RETDUMP: the latest post-commit CR0 (captured by vtm_retire_sys
// UNCONDITIONALLY so the no-trace RD window can print PE/PG). Inert otherwise.
unsigned int g_last_cr0 = 0;
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
// vtm_retire_sys (M2S.1): cr0..cr4 as int unsigned (uint32).
extern "C" void vtm_retire_sys(
    unsigned long long n, unsigned int cr0, unsigned int cr2,
    unsigned int cr3, unsigned int cr4);
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
    if (!g_trace || g_trace->discard()) return;   // --no-trace: skip the stash
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
    if (!g_trace || g_trace->discard()) return;   // --no-trace: skip the stash
    CycleInfo ci;
    ci.pipe   = (unsigned char)(pipe > 2u ? 2u : pipe);  // clamp to {0,1,2}
    ci.paired = (paired != 0u);
    g_trace->stash_cycle(n, ci);
}

// system retire (M2S.1): the core calls this with the SAME `n` as the paired
// vtm_retire, carrying the post-commit cr0..cr4. We stash it keyed by `n`; the
// paired vtm_retire drains it (under sys:true) and emits the cr0..cr4 fields.
extern "C" void vtm_retire_sys(
    unsigned long long n, unsigned int cr0, unsigned int cr2,
    unsigned int cr3, unsigned int cr4) {
    using namespace ventium;
    g_last_cr0 = cr0;  // task #102: always capture (RD window prints PE/PG)
    if (!g_trace || g_trace->discard()) return;   // --no-trace: skip the stash
    SysState s;
    s.cr0 = cr0; s.cr2 = cr2; s.cr3 = cr3; s.cr4 = cr4;
    g_trace->stash_sys(n, s);
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
    // M14: stash the latest arch state for the periodic checkpoint (independent
    // of g_trace — works even when the trace goes to /dev/null in free-run).
    g_last_arch.n = n; g_last_arch.pc = pc; g_last_arch.eflags = eflags;
    g_last_arch.gpr[0]=eax; g_last_arch.gpr[1]=ecx; g_last_arch.gpr[2]=edx;
    g_last_arch.gpr[3]=ebx; g_last_arch.gpr[4]=esp; g_last_arch.gpr[5]=ebp;
    g_last_arch.gpr[6]=esi; g_last_arch.gpr[7]=edi;
    g_last_arch.seg[0]=cs; g_last_arch.seg[1]=ss; g_last_arch.seg[2]=ds;
    g_last_arch.seg[3]=es; g_last_arch.seg[4]=fs; g_last_arch.seg[5]=gs;

    // VEN_GPTRACE: log the faulting protected-mode program's retire stream (the DOS-Quake
    // #GP runs at cs=0x2b). Shows the instruction path into the fault + which insn sets the
    // bad selector (ebx=0x26ac), for the seg-load #GP back-trace. Off unless env-set.
    {
        static int gptrace = -1;
        if (gptrace < 0) gptrace = std::getenv("VEN_GPTRACE") ? 1 : 0;
        if (gptrace && cs == 0x2b) {
            std::fprintf(stderr,
                "[GPTRACE] n=%llu pc=0x%05x eax=%x ebx=%x ecx=%x edx=%x esi=%x edi=%x bp=%x sp=%x ds=%x es=%x ss=%x\n",
                (unsigned long long)n, pc, eax, ebx, ecx, edx, esi, edi, ebp, esp, ds, es, ss);
        }
        // go32-window trace: the divergence is in cs=0x18:0x2b04..0x2b73 (RTL spuriously
        // flips to cs=0x2b/ring3). Log cs=0x18 in that offset window near the fault to
        // diff against QEMU's golden offset sequence (0x2b04 0x2b09 0x2b0a 0x2b0d ...).
        if (gptrace && cs == 0x18 && (pc & 0xffff) >= 0x2b00 && (pc & 0xffff) <= 0x2c00
            && n > 8900000ull) {
            std::fprintf(stderr, "[GO32W] n=%llu cs=18 eip=0x%x ss=%x esp=%x eflags=%08x\n",
                         (unsigned long long)n, pc & 0xffff, (unsigned)ss, esp, eflags);
        }
        // WORKER-RESUME trace: the coroutine worker runs at cs=0x87; its first eip after
        // each task switch is the resume point (QEMU golden: 0x233 0x24e 0x258 0x26d ...).
        // The first iteration where this diverges = where the worker derailed.
        if (gptrace && cs == 0x87 && n > 8900000ull) {
            static unsigned prev87 = 0;
            if (pc != prev87 + 1 && pc != prev87 + 2 && pc != prev87 + 3 && pc != prev87 + 4
                && pc != prev87 + 5 && pc != prev87 + 6) {
                std::fprintf(stderr, "[WRK] n=%llu cs=87 eip=0x%x eax=%x ebx=%x ss=%04x esp=%x\n",
                             (unsigned long long)n, pc, eax, ebx, (unsigned)ss, esp);
            }
            prev87 = pc;
        }
        // ALL-RETIRE trace across the LTR/task-gate gap (n=8907560..8907607) to see the
        // exact failure mode of the far-jmp-to-task-gate at go32 0x2b70-0x2b73.
        if (gptrace && n >= 8907560ull && n <= 8908115ull) {
            std::fprintf(stderr, "[GAP] cs=%04x eip=0x%x eax=%x ebx=%x ecx=%x edx=%x fl=%x\n",
                         (unsigned)cs, pc, eax, ebx, ecx, edx, eflags & 0x8d5);
        }
        // VM/cs transition trace: log when EFLAGS.VM (bit17) or cs changes near the fault,
        // to pinpoint the V86<->PM transition the #GP comes from. Off unless VEN_GPTRACE.
        if (gptrace && n > 8800000ull) {
            static unsigned prev_cs = 0xffff; static int prev_vm = -1;
            int vm = (eflags >> 17) & 1;
            int pe = g_last_cr0 & 1;
            if ((unsigned)cs != prev_cs || vm != prev_vm) {
                std::fprintf(stderr, "[VMTRACE] n=%llu cs=%04x eip=0x%x VM=%d PE=%d cr0=%08x eflags=%08x ss=%04x esp=%x\n",
                             (unsigned long long)n, (unsigned)cs, pc, vm, pe, g_last_cr0, eflags, (unsigned)ss, esp);
                prev_cs = (unsigned)cs; prev_vm = vm;
            }
        }
    }

    // --- F4 DERAIL TRIPWIRE -------------------------------------------------
    // A committed EIP in [0x1000_0000, 0x4000_0000) is NEVER legitimate for the
    // Quake user image (code = 0x0804_xxxx..0x080B_xxxx, brk-heap = 0x0a00_0000+,
    // stack/Hunk >= 0x4000_0000). On the board the userspace Quake derails into
    // the 0x1804_xxxx alias of the ELF header (a code pointer / branch target that
    // acquired bit 28). Capture the instruction trail INTO the bad branch + the
    // committed register state at the transition, so the BRANCH SOURCE (the last
    // 0x08xx_xxxx EIP) and the kind of branch are unambiguous in ONE free-run.
    // Enabled by VEN_DERAIL_TRIP in the environment (off => zero overhead path).
    {
        static const bool en = (std::getenv("VEN_DERAIL_TRIP") != nullptr);
        // VEN_TRIP_N: dump a window of committed {n,eip,esp,regs} bracketing this
        // retire count — the board's EXACT derail count (default 43,695,985). The
        // sim runs CLEAN through here, so its committed insns ARE the correct stream
        // the board mis-executed: the branch source + the CORRECT target it should
        // have taken (vs the board's corrupt 0x1804_xxxx). Pins read-vs-fetch.
        static const char* tn = std::getenv("VEN_TRIP_N");
        static const unsigned long long N0 = tn ? std::strtoull(tn, 0, 0) : 43695985ull;
        if (en && n + 700 >= N0 && n <= N0 + 50) {
            std::fprintf(stderr,
                "WIN n=%-10llu eip=%08x esp=%08x  eax=%08x ecx=%08x edx=%08x ebx=%08x ebp=%08x esi=%08x edi=%08x\n",
                (unsigned long long)n, pc, esp, eax, ecx, edx, ebx, ebp, esi, edi);
        }
        if (en) {
            static uint32_t r_pc[64]; static uint32_t r_n[64]; static uint32_t r_sp[64];
            static int      r_h = 0;  static bool tripped = false;
            r_pc[r_h & 63] = pc; r_n[r_h & 63] = (uint32_t)n; r_sp[r_h & 63] = esp; r_h++;
            if (!tripped && ((pc >= 0x10000000u && pc < 0x40000000u) || pc < 0x08047000u)) {
                tripped = true;
                std::fprintf(stderr,
                    "\n==== F4 DERAIL TRIP: EIP entered alias 0x%08x at retire n=%llu ====\n"
                    "  regs(post): eax=%08x ecx=%08x edx=%08x ebx=%08x\n"
                    "              esp=%08x ebp=%08x esi=%08x edi=%08x eflags=%08x\n"
                    "  segs: cs=%04x ss=%04x ds=%04x es=%04x fs=%04x gs=%04x\n"
                    "  --- last 48 committed {retire, eip, esp} (oldest first) ---\n",
                    pc, (unsigned long long)n, eax, ecx, edx, ebx,
                    esp, ebp, esi, edi, eflags, cs, ss, ds, es, fs, gs);
                for (int i = 0; i < 48; i++) {
                    int idx = (r_h - 48 + i) & 63;
                    std::fprintf(stderr, "    n=%-10u eip=%08x esp=%08x\n",
                                 r_n[idx], r_pc[idx], r_sp[idx]);
                }
                std::fflush(stderr);
            }
        }
    }

    // --- RETIRE-WINDOW REGISTER DUMP (task #102 DOS-Quake forward diff) --------
    // Emit one compact committed-state line per retire over the window
    // [VEN_RETDUMP_LO, VEN_RETDUMP_HI] so an offline aligner can diff the Ventium
    // committed PC+GPR+flag stream against the qemu -d in_asm,cpu trace and pin the
    // FIRST divergent instruction (a register MISCOMPUTE, not a wild branch).
    // Format (one per line, all hex): "RD n cs eip flags eax ecx edx ebx esp ebp
    // esi edi ss ds". Env-gated => zero overhead when unset.
    {
        static int    rd_init = 0;
        static unsigned long long rd_lo = 0, rd_hi = 0;
        static int     rd_cs = -1;   // VEN_RETDUMP_CS: emit only this cs (else all)
        if (!rd_init) {
            const char* l = std::getenv("VEN_RETDUMP_LO");
            const char* h = std::getenv("VEN_RETDUMP_HI");
            const char* c = std::getenv("VEN_RETDUMP_CS");
            rd_lo = l ? std::strtoull(l, 0, 0) : ~0ull;   // unset => never fire
            rd_hi = h ? std::strtoull(h, 0, 0) : 0ull;
            rd_cs = c ? (int)strtol(c, 0, 0) : -1;
            rd_init = 1;
        }
        if (n >= rd_lo && n <= rd_hi && (rd_cs < 0 || (int)cs == rd_cs)) {
            std::fprintf(stderr,
                "RD %llu %04x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %04x %04x %04x cr0=%08x\n",
                (unsigned long long)n, (unsigned)cs, pc, eflags,
                eax, ecx, edx, ebx, esp, ebp, esi, edi, (unsigned)ss, (unsigned)ds,
                (unsigned)es, g_last_cr0);  // es + cr0 (task #102: PE/PG visibility)
        }
    }

    // task #102: EFLAGS.ID (bit21) transition tracer. VEN_IDSET=N emits the first N
    // retires where bit21 goes 0->1 or 1->0, with full ctx, so the FIRST spurious
    // ID set (vs qemu, which keeps it clear) can be pinned to one cs:eip + opcode.
    // Env-gated => zero overhead when unset.
    {
        static int idset_init = 0, idset_max = 0, idset_cnt = 0, idset_prev = -1;
        if (!idset_init) {
            const char* e = std::getenv("VEN_IDSET");
            idset_max = e ? (int)strtol(e, 0, 0) : 0;
            idset_init = 1;
        }
        if (idset_max) {
            int cur = (eflags >> 21) & 1;
            if (idset_prev >= 0 && cur != idset_prev && idset_cnt < idset_max) {
                std::fprintf(stderr,
                    "IDSET %s n=%llu cs=%04x eip=%08x efl=%08x eax=%08x ecx=%08x esp=%08x cr0=%08x\n",
                    cur ? "0->1" : "1->0",
                    (unsigned long long)n, (unsigned)cs, pc, eflags,
                    eax, ecx, esp, g_last_cr0);
                ++idset_cnt;
            }
            idset_prev = cur;
        }
    }

    // --exec-written-check: the first retire whose fetch lin addr was written as
    // DATA (>= floor) is where the core began executing recently-written data as
    // code — the F3 control-flow divergence. Report the onset (first ~20 hits).
    if (g_exec_check) {
        static int reported = 0;
        uint32_t lin = ((uint32_t)cs << 4) + pc;
        auto it = g_wcyc.find(lin);
        if (it != g_wcyc.end() && reported < 20) {
            std::fprintf(stderr,
                "EXEC-FROM-WRITTEN n=%llu cs:ip=%04x:%08x lin=0x%06x  written@cyc=%llu now=%llu\n",
                (unsigned long long)n, (unsigned)cs, pc, lin,
                (unsigned long long)it->second, (unsigned long long)g_now_cycle);
            ++reported;
        }
    }

    if (!g_trace || !g_trace->ok()) return;
    // --no-trace (free-run fast path): count the retirement so the TB loop can
    // make progress, but skip ALL record formatting (the per-instruction cost).
    if (g_trace->discard()) { g_trace->note_retire(); return; }

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

    // M2S.1 system fields (only when the trace header declares sys:true). Drain
    // the cr0..cr4 the core stashed via vtm_retire_sys for this same `n`; if the
    // core did not call it (e.g. a user-mode core), emit zeros (well-formed).
    // The 6 selectors are already emitted above (cs..gs); the comparator's sys
    // path compares cr0..cr4 + selectors + GPRs + eflags + eip. Field names +
    // 0x%08x formatting MUST match tracefmt.py (SYS_CR).
    if (g_trace->sys()) {
        bool present = false;
        SysState s = g_trace->take_sys((uint64_t)n, &present);
        std::fprintf(g_trace->fp(),
            ",\"cr0\":\"0x%08x\",\"cr2\":\"0x%08x\","
            "\"cr3\":\"0x%08x\",\"cr4\":\"0x%08x\"",
            s.cr0, s.cr2, s.cr3, s.cr4);
        (void)present;
    }

    std::fprintf(g_trace->fp(), "}\n");

    g_trace->note_retire();
}
