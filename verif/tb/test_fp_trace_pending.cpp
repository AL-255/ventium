// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "fp_trace_pending.h"
#include <cassert>
#include <cstdio>
#include <vector>

using namespace ventium;
struct Output { FPTraceRecord record; X87State fp; };

template<class F> void rejects(F f) {
    bool rejected = false;
    try { f(); } catch (const std::logic_error&) { rejected = true; }
    assert(rejected);
}

FPTraceRecord record(uint64_t n, uint64_t clock) {
    FPTraceRecord r;
    r.arch.n = n; r.clock = clock; r.arch.pc = 0x1000 + n * 4;
    r.arch.eflags = 0x202 + n;
    for (unsigned i = 0; i < 8; ++i) r.arch.gpr[i] = n * 32 + i;
    for (unsigned i = 0; i < 6; ++i) r.arch.seg[i] = n * 8 + i;
    r.sys = {0x80000011, uint32_t(n), 0x123000, 0};
    r.sys_present = true; r.pipe_present = true;
    r.pipe = {uint8_t(n % 2), true};
    return r;
}

int main() {
    X87State old, committed;
    old.fctrl = committed.fctrl = 0x37f;
    committed.fstat = 0x8088; committed.ftag = 0xfffc;
    for (unsigned i = 0; i < 8; ++i) {
        committed.st_lo[i] = 0x8000000000000000ULL + i;
        committed.st_hi[i] = 0x3fff + i;
    }
    std::vector<Output> out;
    auto emit = [&](const FPTraceRecord& r, const X87State& f) {
        out.push_back({r, f});
    };
    FPTracePending q(3);
    q.push(record(0, 10), old, emit);
    assert(out.size() == 1 && out[0].fp.fstat == 0);
    q.begin(1);
    q.push(record(1, 11), old, emit);  // owner
    q.push(record(2, 12), old, emit);  // U
    q.push(record(3, 12), old, emit);  // paired V, same real clock
    assert(out.size() == 1 && q.buffered() == 3);
    rejects([&] { q.begin(4); });
    rejects([&] { q.complete(2, committed, emit); });
    rejects([&] { q.finish(); });
    rejects([&] { q.push(record(4, 13), old, emit); });
    assert(out.size() == 1 && q.buffered() == 3);
    q.complete(1, committed, emit);
    assert(out.size() == 4 && !q.pending() && !q.buffered());
    for (unsigned n = 1; n < 4; ++n) {
        const auto& o = out[n];
        const auto want = record(n, n == 1 ? 11 : 12);
        assert(o.record.arch.n == n && o.record.clock == want.clock);
        assert(o.record.arch.pc == want.arch.pc);
        assert(o.record.arch.eflags == want.arch.eflags);
        for (unsigned i = 0; i < 8; ++i) {
            assert(o.record.arch.gpr[i] == want.arch.gpr[i]);
            assert(o.fp.st_lo[i] == committed.st_lo[i]);
            assert(o.fp.st_hi[i] == committed.st_hi[i]);
        }
        for (unsigned i = 0; i < 6; ++i)
            assert(o.record.arch.seg[i] == want.arch.seg[i]);
        assert(o.record.sys.cr0 == want.sys.cr0 && o.record.sys.cr2 == n);
        assert(o.record.sys.cr3 == want.sys.cr3 && o.record.sys.cr4 == 0);
        assert(o.record.sys_present && o.record.pipe_present);
        assert(o.record.pipe.pipe == want.pipe.pipe && o.record.pipe.paired);
        assert(o.fp.fstat == committed.fstat && o.fp.ftag == committed.ftag);
        assert(o.fp.fctrl == committed.fctrl);
    }
    // Subsequent live state must not be overwritten by the prior completion.
    q.push(record(4, 20), old, emit);
    assert(out.back().fp.fstat == 0);
    q.begin(5); q.push(record(5, 21), old, emit);
    q.complete(5, committed, emit); q.finish();
    rejects([&] { q.complete(5, committed, emit); });
    rejects([&] { q.push(record(5, 22), old, emit); });
    rejects([&] { q.push(record(7, 22), old, emit); });
    rejects([&] { q.push(record(6, 20), old, emit); });
    rejects([&] { q.begin(7); });
    q.push(record(6, 22), old, emit); q.finish();
    rejects([] { FPTracePending zero(0); });
    FPTracePending fresh;
    fresh.begin(100); // Nonzero sequence after a qualified restore is allowed.
    rejects([&] { fresh.push(record(101, 0), old, emit); });
    rejects([&] { fresh.complete(100, committed, emit); });
    fresh.push(record(100, 0), old, emit);
    fresh.complete(100, committed, emit); fresh.finish();
    FPTracePending wrap;
    rejects([&] { wrap.push(record(UINT64_MAX, 0), old, emit); });
    rejects([&] { wrap.begin_stream(UINT64_MAX); });

    // Older completions may release only their architectural prefix. Younger
    // FP owners and their following integer records retain their own result.
    out.clear();
    FPTracePending multi;
    X87State first=committed, second=committed;
    first.fstat=0x10; second.fstat=0x20;
    first.st_lo[0]=11; second.st_lo[0]=22;
    multi.begin_stream(10);
    rejects([&] { multi.begin_stream(11); }); // missing first owner record
    multi.push(record(10,100),old,emit);
    multi.push(record(11,101),old,emit);
    multi.begin_stream(12);
    multi.push(record(12,102),old,emit);
    multi.push(record(13,102),old,emit);
    rejects([&] { multi.begin(14); }); // no mixing single/stream contracts
    rejects([&] { multi.complete(12,second,emit); });
    multi.complete(10,first,emit);
    assert(multi.pending() && multi.buffered()==2 && out.size()==2);
    for (unsigned i=0; i<2; ++i) {
        assert(out[i].record.arch.n==10+i);
        assert(out[i].fp.fstat==0x10 && out[i].fp.st_lo[0]==11);
    }
    // Complete on an edge that also admits another owner; the later prefix
    // must stay buffered even when it has no record yet.
    multi.begin_stream(14);
    multi.complete(12,second,emit);
    assert(out.size()==4 && multi.pending() && multi.buffered()==0);
    for (unsigned i=2; i<4; ++i) {
        assert(out[i].record.arch.n==10+i);
        assert(out[i].record.clock==102);
        assert(out[i].fp.fstat==0x20 && out[i].fp.st_lo[0]==22);
    }
    rejects([&] { multi.finish(); });
    multi.push(record(14,103),old,emit);
    multi.complete(14,committed,emit);
    multi.finish();
    assert(out.size()==5 && out.back().record.arch.gpr[3]==14*32+3);

    FPTracePending capacity;
    for (unsigned n=0; n<4; ++n) {
        capacity.begin_stream(n);
        capacity.push(record(n,n),old,emit);
    }
    rejects([&] { capacity.begin_stream(4); });
    capacity.complete(0,first,emit);
    capacity.begin_stream(4);
    capacity.push(record(4,4),old,emit);
    for (unsigned n=1; n<=4; ++n) capacity.complete(n,second,emit);
    capacity.finish();
    std::puts("FP-TRACE-PENDING-OK");
}
