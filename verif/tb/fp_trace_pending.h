// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#ifndef VENTIUM_FP_TRACE_PENDING_H
#define VENTIUM_FP_TRACE_PENDING_H

#include "trace_writer.h"
#include <cstddef>
#include <deque>
#include <optional>
#include <stdexcept>

namespace ventium {

// Observation only: never defer runtime callbacks, syscalls, counters, memory
// inspection, or g_last_arch updates. Capture those at the real retirement.
// This record is a frozen input to the *formatter*, not another retirement.
struct FPTraceRecord {
    LastArch arch;
    SysState sys;
    CycleInfo pipe;
    uint64_t clock = 0;
    bool sys_present = false;
    bool pipe_present = false;
};

// Ordered x87 owners. The RTL integration must call begin at
// its ordered issue/retire observation, then push its record, then complete
// only after the actual state-file commit. begin() retains single-owner mode;
// begin_stream() explicitly permits at most four ordered owners. Debug/exception
// drain or end-of-run must not silently bypass an outstanding owner.
//
// No result is calculated here. The supplied completion state comes from RTL,
// never from QEMU or a software FPU. Filling the owner's and younger integer
// records up to (but excluding) the next FP owner with that state reconstructs
// sequential architectural observation;
// their captured clocks/PCs/GPRs/system state remain untouched.
class FPTracePending {
public:
    explicit FPTracePending(size_t limit = 4096) : limit_(limit) {
        if (!limit_) fail("zero capacity");
    }

    bool pending() const { return !owners_.empty(); }
    size_t buffered() const { return records_.size(); }

    void begin(uint64_t owner) {
        begin_owner(owner, false);
    }

    // Explicit opt-in; ordinary begin retains the single-owner rejection.
    void begin_stream(uint64_t owner) { begin_owner(owner, true); }

    template<class Emit>
    void push(const FPTraceRecord& record, const X87State& live, Emit emit) {
        const uint64_t n = record.arch.n;
        if (next_ && n != *next_) fail("nonconsecutive retirement");
        if (last_clock_ && record.clock < *last_clock_)
            fail("retirement clock moved backwards");
        if (n == UINT64_MAX) fail("retirement sequence overflow");
        if (pending()) {
            if (records_.empty() && n != owners_.front()) fail("missing owner record");
            if (records_.size() == limit_) fail("pending trace capacity exceeded");
            records_.push_back(record);
        } else {
            emit(record, live);
        }
        next_ = n + 1;
        last_clock_ = record.clock;
    }

    template<class Emit>
    void complete(uint64_t owner, const X87State& committed, Emit emit) {
        if (!pending() || owners_.front() != owner) fail("unmatched FP completion");
        if (records_.empty() || records_.front().arch.n != owner)
            fail("FP completion precedes owner record");
        // A failing sink terminates the run: callers must not catch and retry
        // partially emitted output. No record may be dropped to recover space.
        const uint64_t stop = owners_.size() > 1 ? owners_[1] : UINT64_MAX;
        while (!records_.empty() && records_.front().arch.n < stop) {
            emit(records_.front(), committed);
            records_.pop_front();
        }
        owners_.pop_front();
        if (!pending()) streaming_ = false;
    }

    void finish() const {
        if (pending() || !records_.empty()) fail("unresolved FP at trace end");
    }

private:
    void begin_owner(uint64_t owner, bool streaming) {
        if (pending() && !(streaming && streaming_)) fail("second outstanding FP owner");
        if (owners_.size() == 4) fail("FP owner capacity exceeded");
        if (owner == UINT64_MAX) fail("FP owner sequence overflow");
        if (next_ && owner != *next_) fail("FP owner is not next retirement");
        if (pending() && (records_.empty() || records_.back().arch.n < owners_.back()))
            fail("previous FP owner has no retirement record");
        owners_.push_back(owner);
        streaming_ = streaming;
    }
    [[noreturn]] static void fail(const char* reason) {
        throw std::logic_error(reason);
    }
    const size_t limit_;
    std::optional<uint64_t> next_, last_clock_;
    std::deque<uint64_t> owners_;
    bool streaming_ = false;
    std::deque<FPTraceRecord> records_;
};
} // namespace ventium
#endif
