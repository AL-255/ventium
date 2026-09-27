#pragma once
#include <array>
#include <cstdint>
#include <stdexcept>

// Host-only terminal breakpoint bookkeeping. A parked core can still have a
// registered retirement waiting for the next DPI sampling edge. Permit exactly
// one ordinary clock with issue held, then require the architectural scan to be
// unchanged. Never step, inject state, or fabricate a retirement record.
class DebugBreakpointDrain {
public:
    enum class Action { Running, Drain, Stop };
    template<class T> Action observe(T& top, uint64_t cycle) {
        if (!pending_ && !top.dbg_halted) return Action::Running;
        if (!top.dbg_halted) throw std::runtime_error("breakpoint drain released halt");
        std::array<uint32_t, 75> state{};
        const auto selector = top.dbg_arch_sel;
        // Selectors 0..74 are architectural registers/hidden descriptor state;
        // 75 is the debug stop-cause latch and may settle on this last edge.
        for (unsigned i = 0; i < state.size(); ++i) {
            top.dbg_arch_sel = i;
            top.eval();
            state[i] = top.dbg_arch_data;
        }
        top.dbg_arch_sel = selector;
        top.eval();
        if (!pending_) {
            state_ = state;
            cycle_ = cycle;
            pending_ = true;
            return Action::Drain;
        }
        if (cycle <= cycle_ || cycle - cycle_ != 1)
            throw std::runtime_error("breakpoint drain did not span exactly one clock");
        if (state != state_)
            throw std::runtime_error("architectural state changed while breakpoint parked");
        return Action::Stop;
    }
private:
    bool pending_ = false;
    uint64_t cycle_ = 0;
    std::array<uint32_t, 75> state_{};
};
