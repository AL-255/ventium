#include "debug_breakpoint_drain.h"
#include <cassert>
#include <cstdio>

struct Model {
    bool dbg_halted = false;
    unsigned dbg_arch_sel = 11;
    uint32_t dbg_arch_data = 0;
    unsigned evaluations = 0;
    std::array<uint32_t, 76> state{};
    void eval() { ++evaluations; dbg_arch_data = state.at(dbg_arch_sel); }
};

template<class F> void rejects(F f) {
    bool failed = false;
    try { f(); } catch (const std::runtime_error&) { failed = true; }
    assert(failed);
}

int main() {
    using Action = DebugBreakpointDrain::Action;
    Model top;
    DebugBreakpointDrain drain;
    assert(drain.observe(top, 1) == Action::Running && top.evaluations == 0);
    top.dbg_halted = true;
    assert(drain.observe(top, 100) == Action::Drain);
    assert(top.dbg_arch_sel == 11);
    top.state[75] = 2; // nonarchitectural breakpoint-cause latch may settle
    assert(drain.observe(top, 101) == Action::Stop);
    assert(top.dbg_arch_sel == 11);
    for (unsigned field = 0; field < 75; ++field) {
        Model changed;
        changed.dbg_halted = true;
        DebugBreakpointDrain probe;
        assert(probe.observe(changed, 10) == Action::Drain);
        ++changed.state[field];
        rejects([&] { probe.observe(changed, 11); });
    }
    for (uint64_t cycle : {9, 10, 12}) {
        DebugBreakpointDrain probe;
        assert(probe.observe(top, 10) == Action::Drain);
        rejects([&] { probe.observe(top, cycle); });
    }
    DebugBreakpointDrain released;
    assert(released.observe(top, 10) == Action::Drain);
    top.dbg_halted = false;
    rejects([&] { released.observe(top, 11); });
    std::puts("DEBUG-BREAKPOINT-DRAIN-HOST-OK (75 mutation, 3 clock, released-halt negatives)");
}
