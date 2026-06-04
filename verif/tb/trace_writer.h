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
// Cycle (M4): when tb_main opens the writer in --cycle mode, the header declares
// "mode":"cycle" and each record carries the cycle fields (cyc, pipe, paired)
// per docs/trace-format.md §2.3 INSTEAD of the func fields. tb_main keeps the
// writer's clock counter current (set_clock) so that when vtm_retire fires the
// writer stamps cyc = clock-count-at-retire. The core's separate
// vtm_retire_cycle DPI call stashes {pipe,paired} keyed by `n` via stash_cycle();
// the matching vtm_retire drains it for that `n`. If the core never called
// vtm_retire_cycle for a retirement, the record defaults to pipe=U paired=false
// (a well-formed cycle record). func and cycle modes are mutually exclusive
// (--cycle wins); default (neither) is the unchanged func mode so the M1/M2/M3
// functional gates are unaffected.
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

// Per-retirement cycle attribution the core reports via vtm_retire_cycle (M4):
//   pipe : 0=U, 1=V, 2=none -> formatted "U"/"V"/"-" (docs/trace-format.md §2.3)
//   paired : the instruction issued paired with its sibling this clock.
// The cumulative `cyc` is NOT carried here — the TB owns the clock counter and
// stamps cyc = clock-count-at-retire on the matching vtm_retire.
struct CycleInfo {
    uint8_t pipe   = 0;      // default U (the not-yet-pipelined / sole-pipe case)
    bool    paired = false;
};

// M2S.1: post-commit system control registers the core reports via
// vtm_retire_sys. Emitted (with the selectors that vtm_retire already carries)
// when the trace header declares sys:true. cr0 PE=bit0 .. PG=bit31.
struct SysState {
    uint32_t cr0 = 0;
    uint32_t cr2 = 0;
    uint32_t cr3 = 0;
    uint32_t cr4 = 0;
};

class TraceWriter {
public:
    TraceWriter() = default;
    ~TraceWriter() { close(); }

    // Open the output file and emit the header line. The header matches
    // tracefmt.header("rtl",<mode>,x87=<x87>,...). In FUNC mode (cycle=false):
    //   {"vtrace":1,"producer":"rtl","mode":"func","x87":<bool>,"note":"..."}
    // In CYCLE mode (cycle=true, x87 ignored — cycle records carry no x87):
    //   {"vtrace":1,"producer":"rtl","mode":"cycle","x87":false,"note":"..."}
    // `x87` selects whether func records carry the x87 fields (trace-format §2.2).
    // Returns true on success.
    bool open(const std::string& path, const std::string& note, bool x87,
              bool cycle = false, bool sys = false) {
        fp_  = std::fopen(path.c_str(), "wb");
        if (!fp_) return false;
        cycle_ = cycle;
        x87_   = cycle ? false : x87;   // cycle records never carry x87 fields
        sys_   = cycle ? false : sys;   // sys is a func-mode superset (M2S.1)
        // note is free-form (trace-format.md §1) and ignored by the comparator;
        // it must not contain a double-quote — tb_main passes only simple text.
        // M2S.1: emit "sys":true (like x87) only when set, so existing user/x87
        // traces are byte-for-byte identical.
        std::fprintf(fp_,
            "{\"vtrace\":1,\"producer\":\"rtl\",\"mode\":\"%s\","
            "\"x87\":%s,\"note\":\"%s\"%s}\n",
            cycle_ ? "cycle" : "func",
            x87_ ? "true" : "false",
            note.c_str(),
            sys_ ? ",\"sys\":true" : "");
        return true;
    }

    void close() {
        if (fp_) {
            std::fflush(fp_);
            std::fclose(fp_);
            fp_ = nullptr;
        }
    }

    bool   ok()    const { return fp_ != nullptr; }
    FILE*  fp()    const { return fp_; }
    bool   x87()   const { return x87_; }
    bool   cycle() const { return cycle_; }
    bool   sys()   const { return sys_; }

    // --- M2S.1 system stash --------------------------------------------------
    // vtm_retire_sys stashes cr0..cr4 for sequence `n`; the matching vtm_retire
    // drains it via take_sys(n). Same single-outstanding pattern as x87 (the
    // core calls vtm_retire_sys immediately before vtm_retire for the same n).
    void stash_sys(uint64_t n, const SysState& s) {
        sys_pending_ = s; sys_pending_n_ = n; sys_pending_set_ = true;
    }
    SysState take_sys(uint64_t n, bool* present) {
        if (sys_pending_set_ && sys_pending_n_ == n) {
            sys_pending_set_ = false; *present = true; return sys_pending_;
        }
        *present = false; return SysState{};
    }

    // --- cycle clock + stash (M4) -------------------------------------------
    // tb_main advances the writer's view of the core-clock counter once per
    // core clock (BEFORE the rising-edge eval where vtm_retire may fire), so
    // that vtm_retire can stamp cyc = clock(). Two retirements in the same eval
    // (a paired issue) therefore read the same clock value and share cyc.
    void     set_clock(uint64_t c) { clock_ = c; }
    uint64_t clock() const         { return clock_; }

    // vtm_retire_cycle stashes {pipe,paired} for sequence `n`; the matching
    // vtm_retire calls take_cycle(n) to drain it. Up to two outstanding entries
    // are needed because a paired issue retires BOTH instructions in the same
    // clock: the core calls vtm_retire_cycle then vtm_retire for the U insn,
    // then vtm_retire_cycle then vtm_retire for the V insn (in-order). Keying by
    // `n` and validating means a stale/missing stash is treated as "absent"
    // (pipe=U paired=false) rather than mis-attributed.
    void stash_cycle(uint64_t n, const CycleInfo& ci) {
        // store keyed by n in a tiny 2-slot ring so a U+V pair both survive
        // until their respective vtm_retire drains them.
        for (int s = 0; s < 2; ++s) {
            if (!cyc_slot_set_[s] || cyc_slot_n_[s] == n) {
                cyc_slot_[s]     = ci;
                cyc_slot_n_[s]   = n;
                cyc_slot_set_[s] = true;
                return;
            }
        }
        // both slots busy with other n's: overwrite slot 0 (older). This only
        // happens if the core stashed >2 before retiring; not expected in-order.
        cyc_slot_[0]     = ci;
        cyc_slot_n_[0]   = n;
        cyc_slot_set_[0] = true;
    }

    // Return the stashed cycle info for `n` if present; clear it. Sets `present`
    // to whether a matching stash was found. When absent, returns the default
    // (pipe=U paired=false) so the record is still well-formed.
    CycleInfo take_cycle(uint64_t n, bool* present) {
        for (int s = 0; s < 2; ++s) {
            if (cyc_slot_set_[s] && cyc_slot_n_[s] == n) {
                cyc_slot_set_[s] = false;
                *present = true;
                return cyc_slot_[s];
            }
        }
        *present = false;
        return CycleInfo{};   // pipe=U paired=false
    }

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
    bool     cycle_   = false;
    bool     sys_     = false;

    X87State x87_pending_;
    uint64_t x87_pending_n_   = 0;
    bool     x87_pending_set_ = false;

    SysState sys_pending_;
    uint64_t sys_pending_n_   = 0;
    bool     sys_pending_set_ = false;

    // cycle-mode: TB-owned clock counter + 2-slot {pipe,paired} stash.
    uint64_t  clock_ = 0;
    CycleInfo cyc_slot_[2];
    uint64_t  cyc_slot_n_[2]   = {0, 0};
    bool      cyc_slot_set_[2] = {false, false};
};

// Defined in dpi_retire.cpp; set by tb_main before clocking begins.
extern TraceWriter* g_trace;

}  // namespace ventium

#endif  // VENTIUM_TRACE_WRITER_H
