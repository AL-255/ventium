// verif/tb/trace_writer.h
//
// Tiny shared object that owns the open .vtrace file and the retire counter.
// tb_main.cpp constructs it (opens the file, writes the header), exposes it to
// dpi_retire.cpp via the ventium::g_trace global, and dpi_retire.cpp appends
// one func-mode record per vtm_retire call. Header/record formats are pinned by
// docs/trace-format.md §1/§2 and verif/diff/tracefmt.py.
//
// x87 (M3+): when tb_main opens the writer in --x87 mode, the header declares
// "x87":true and each record carries the x87 fields (st0..st7, fctrl, fstat,
// ftag, and fop/fiseg/fioff/foseg/fooff = 0). The core's separate
// vtm_retire_x87 DPI call (rtl-interface.md §2) stashes the post-commit x87
// state keyed by the retire sequence `n` via stash_x87(); the matching
// vtm_retire then drains it for that `n`. If the core never called
// vtm_retire_x87 for a retirement, the stash is "unset" and the record is
// emitted with zeroed x87 fields — still a well-formed x87:true record.
//
// Kept header-only and dependency-free so both translation units agree on the
// layout without a separate .cpp. This is the only file shared between the two
// owned source files of Producer C.
#ifndef VENTIUM_TRACE_WRITER_H
#define VENTIUM_TRACE_WRITER_H

#include <cstdint>
#include <cstdio>
#include <string>

namespace ventium {

// Post-commit x87 architectural state for one retirement, in the canonical
// floatx80 encoding the trace compares against (gen_trace.py / tracefmt.py):
//   st<i> 80-bit = (hi<<64)|lo, hi = sign|exp [79:64], lo = mantissa [63:0].
// Control words are 16-bit (masked on format). The pointer fields are not
// modeled (QEMU user-mode reports 0), so they are not stored here — dpi_retire
// emits 0 for fop/fiseg/fioff/foseg/fooff.
struct X87State {
    uint64_t st_lo[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    uint16_t st_hi[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    uint16_t fctrl    = 0;
    uint16_t fstat    = 0;
    uint16_t ftag     = 0;
};

class TraceWriter {
public:
    TraceWriter() = default;
    ~TraceWriter() { close(); }

    // Open the output file and emit the header line. The header matches
    // tracefmt.header("rtl","func",x87=<x87>,...) — i.e.
    //   {"vtrace":1,"producer":"rtl","mode":"func","x87":<bool>,"note":"..."}
    // `x87` selects whether records carry the x87 fields (trace-format.md §2.2).
    // Returns true on success.
    bool open(const std::string& path, const std::string& note, bool x87) {
        fp_  = std::fopen(path.c_str(), "wb");
        if (!fp_) return false;
        x87_ = x87;
        // note is free-form (trace-format.md §1) and ignored by the comparator;
        // it must not contain a double-quote — tb_main passes only simple text.
        std::fprintf(fp_,
            "{\"vtrace\":1,\"producer\":\"rtl\",\"mode\":\"func\","
            "\"x87\":%s,\"note\":\"%s\"}\n",
            x87 ? "true" : "false",
            note.c_str());
        return true;
    }

    void close() {
        if (fp_) {
            std::fflush(fp_);
            std::fclose(fp_);
            fp_ = nullptr;
        }
    }

    bool   ok()  const { return fp_ != nullptr; }
    FILE*  fp()  const { return fp_; }
    bool   x87() const { return x87_; }

    // --- x87 stash (M3) ------------------------------------------------------
    // vtm_retire_x87 calls this with the post-commit x87 state for sequence `n`;
    // the paired vtm_retire then calls take_x87(n) to drain it. Only one
    // outstanding entry is needed because the core calls vtm_retire_x87
    // immediately before vtm_retire for the same `n` (single-issue, in-order),
    // but we also key by `n` and validate so a stale/mismatched stash is treated
    // as "absent" (zeros) rather than silently mis-attributed.
    void stash_x87(uint64_t n, const X87State& s) {
        x87_pending_     = s;
        x87_pending_n_   = n;
        x87_pending_set_ = true;
    }

    // Return the stashed x87 state for `n` if present and matching; clear it.
    // Sets `present` to whether a matching stash was found. When absent, returns
    // a zeroed state so the record is still well-formed (zeros).
    X87State take_x87(uint64_t n, bool* present) {
        if (x87_pending_set_ && x87_pending_n_ == n) {
            x87_pending_set_ = false;
            *present = true;
            return x87_pending_;
        }
        *present = false;
        return X87State{};   // zeros
    }

    // Bookkeeping driven by dpi_retire.cpp on each emitted record.
    void     note_retire() { ++retired_; }
    uint64_t retired() const { return retired_; }

private:
    FILE*    fp_      = nullptr;
    uint64_t retired_ = 0;
    bool     x87_     = false;

    X87State x87_pending_;
    uint64_t x87_pending_n_   = 0;
    bool     x87_pending_set_ = false;
};

// Defined in dpi_retire.cpp; set by tb_main before clocking begins.
extern TraceWriter* g_trace;

}  // namespace ventium

#endif  // VENTIUM_TRACE_WRITER_H
