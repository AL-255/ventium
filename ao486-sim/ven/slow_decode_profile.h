#pragma once
#include <array>
#include <cstdint>
#include <cstdio>

// Host-only observation of S_DECODE residency, NOT accepted instructions or
// retirements. Includes retries and held decode clocks. Counters span guest
// resets; a new host process starts a new series. No guest state is modified.
struct SlowDecodeProfile {
    std::array<uint64_t, 513> clocks{}; // 00..ff, 0f00..0fff, no opcode in 15 bytes
    uint64_t prefixed = 0;

    static bool prefix(uint8_t b) {
        switch (b) {
        case 0x26: case 0x2e: case 0x36: case 0x3e: case 0x64: case 0x65:
        case 0x66: case 0x67: case 0xf0: case 0xf2: case 0xf3: return true;
        default: return false;
        }
    }

    template<class Bytes> void observe(unsigned state, const Bytes &bytes) {
        // S_DECODE=2 precedes every conditional member of core.sv's state_e.
        if (state != 2) return;
        const unsigned limit = bytes.size() < 15 ? bytes.size() : 15;
        unsigned i = 0, bucket = 512;
        while (i < limit && prefix(bytes[i])) ++i;
        if (i) ++prefixed;
        if (i < limit) {
            bucket = bytes[i];
            if (bucket == 0x0f)
                bucket = i + 1 < limit ? 256 + unsigned(bytes[i + 1]) : 512;
        }
        ++clocks[bucket];
    }

    void report(FILE *out, uint64_t cycle) const {
        std::fprintf(out, "[VEN-SLOW-DECODE] cycle=%llu prefixed=%llu clocks=",
                     (unsigned long long)cycle, (unsigned long long)prefixed);
        for (unsigned i = 0; i < clocks.size(); ++i)
            std::fprintf(out, "%s%llu", i ? "," : "",
                         (unsigned long long)clocks[i]);
        std::fprintf(out, "\n");
        std::fflush(out);
    }
};
