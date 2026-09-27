#pragma once
#include <cassert>
#include <cstdint>

// Passive view of the current 16-set direct/2-way/4-way TLB layouts.
// Infer ways from the generated arrays, not C++ defines (Verilog +defines
// are not automatically propagated to the harness compiler).
struct VenTlbProbe {
    bool hit = false;
    bool dirty = false;
    bool has_invalid = false;
};

template<class Valid, class Tags, class Dirty>
VenTlbProbe ven_tlb_probe(uint32_t linear, const Valid& valid,
                         const Tags& tags, const Dirty& dirty) {
    const unsigned entries = valid.size();
    assert((entries == 16 || entries == 32 || entries == 64) &&
           tags.size() == entries && dirty.size() == entries);
    const unsigned ways = entries / 16;
    const unsigned base = ((linear >> 12) & 15u) * ways;
    VenTlbProbe result;
    for (unsigned w = 0; w < ways; ++w) {
        const unsigned slot = base + w;
        result.has_invalid |= !valid[slot];
        if (!result.hit && valid[slot] && tags[slot] == (linear >> 12)) {
            result.hit = true;
            result.dirty = dirty[slot];
        }
    }
    // Fill policy: matching tag first, then invalid way, then replacement.
    // The exact RR victim is irrelevant when classifying a full-set conflict.
    return result;
}
