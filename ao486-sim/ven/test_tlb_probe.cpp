#include "tlb_probe.h"
#include <array>
#include <cstdio>

template<unsigned Ways> void check() {
    std::array<uint8_t, 16 * Ways> valid{}, dirty{};
    std::array<uint32_t, 16 * Ways> tags{};
    constexpr uint32_t linear = 0x1234a000;
    constexpr unsigned base = 10 * Ways;
    auto probe = [&] { return ven_tlb_probe(linear, valid, tags, dirty); };
    assert(!probe().hit && probe().has_invalid);
    // A valid tag at the old direct-map index must not fake a hit.
    if (Ways > 1) {
        valid[10] = 1; tags[10] = linear >> 12; dirty[10] = 1;
        assert(!probe().hit);
    }
    for (unsigned w = 0; w < Ways; ++w) {
        valid[base + w] = 1;
        tags[base + w] = (linear >> 12) + 16 * (w + 1);
    }
    assert(!probe().hit && !probe().has_invalid);
    for (unsigned w = 0; w < Ways; ++w) {
        const auto old = tags[base + w];
        tags[base + w] = linear >> 12;
        assert(probe().hit && !probe().dirty);
        dirty[base + w] = 1;
        assert(probe().hit && probe().dirty);
        if (Ways > 1) {
            const unsigned other = base + (w + 1) % Ways;
            valid[other] = 0;
            assert(probe().hit && probe().has_invalid); // same beats invalid
            valid[other] = 1;
        }
        tags[base + w] = old; dirty[base + w] = 0;
    }
    valid.fill(0); // stale tags after flush cannot count as resident
    assert(!probe().hit && probe().has_invalid);
}

int main() {
    check<1>(); check<2>(); check<4>();
    std::puts("TLB-PROBE-OK (direct, 2-way, 4-way)");
}
