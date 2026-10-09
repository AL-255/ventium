#include "../ven_posted_reset_guard.h"
#include <assert.h>
#include <stdio.h>
#include <vector>
using ven_posted::DrainResult;
struct Fake {
    uint32_t ctrl = 1, sel = 17;
    std::vector<uint32_t> statuses = {0x50440003};
    unsigned polls = 0, sleeps = 0, writes = 0;
    unsigned lose_reset = 0, lose_selector = 0, fail_sleep = 0;
    bool corrupt_after_data = false, corrupt_restore = false;
    uint32_t read(uint32_t off) {
        if (off == ven_posted::control) return ctrl;
        if (off == ven_posted::selector) return sel;
        assert(off == ven_posted::data && sel == 79);
        if (corrupt_after_data) sel = 42;
        unsigned index = polls++;
        return statuses[index < statuses.size() ? index : statuses.size()-1];
    }
    void write(uint32_t off, uint32_t value) {
        assert(off == ven_posted::selector); // no reset/data/guest write permitted
        ++writes;
        sel = corrupt_restore && value == 17 ? 41 : value;
    }
    bool pause() {
        ++sleeps;
        if (sleeps == lose_reset) ctrl = 0x102;
        if (sleeps == lose_selector) sel = 43;
        return sleeps != fail_sleep;
    }
    DrainResult run() {
        return ven_posted::wait_for_reset_drain(
            [this](uint32_t o) { return read(o); },
            [this](uint32_t o, uint32_t v) { write(o,v); },
            [this]() { return pause(); });
    }
};
int main() {
    unsigned cases = 0;
    { Fake f; assert(f.run()==DrainResult::ready && f.polls==2 && f.sel==17 && f.writes==2); ++cases; }
    { Fake f; f.statuses={0x50440002,0x50440003,0x50440002,0x50440003};
      assert(f.run()==DrainResult::ready && f.polls==5 && f.sel==17); ++cases; }
    for (uint32_t s : {0u, 0x50440001u, 0x5044000bu, 0x55563634u, 0xffffffffu}) {
        Fake f; f.statuses={s}; assert(f.run()==DrainResult::unsupported && f.polls==1 && f.sel==17); ++cases;
    }
    for (uint32_t s : {0x50440006u, 0x50440007u}) {
        Fake f; f.statuses={s}; assert(f.run()==DrainResult::fault && f.polls==1 && f.sel==17); ++cases;
    }
    { Fake f; f.statuses={0x50440002}; assert(f.run()==DrainResult::timeout && f.polls==1000 && f.sel==17); ++cases; }
    { Fake f; f.statuses.assign(999,0x50440002); f.statuses.push_back(0x50440003);
      assert(f.run()==DrainResult::timeout && f.polls==1000); ++cases; }
    for (uint32_t ctrl : {0u,2u,0x101u,0x102u,0xffffffffu}) {
        Fake f; f.ctrl=ctrl; assert(f.run()==DrainResult::reset_not_held && !f.writes && !f.polls); ++cases;
    }
    { Fake f; f.sel=128; assert(f.run()==DrainResult::bad_selector && !f.writes); ++cases; }
    for (unsigned at : {1u,2u}) {
        Fake f; f.lose_reset=at; assert(f.run()==DrainResult::reset_not_held && f.sel==17 && f.polls==at-1); ++cases;
        Fake g; g.lose_selector=at; assert(g.run()==DrainResult::contention && g.sel==43 && g.writes==1); ++cases;
        Fake h; h.fail_sleep=at; assert(h.run()==DrainResult::sleep_failed && h.sel==17); ++cases;
    }
    { Fake f; f.corrupt_after_data=true; assert(f.run()==DrainResult::contention && f.sel==42 && f.writes==1); ++cases; }
    { Fake f; f.corrupt_restore=true; assert(f.run()==DrainResult::contention && f.sel==41); ++cases; }
    printf("POSTED-RESET-GUARD-OK: %u cases\n", cases);
}
