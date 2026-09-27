#pragma once
#include <cstdint>

// The RTC accumulator consumes one clk_sys edge per simulated core cycle.
// Require at least its fastest 8192-Hz enable rate. Reserve 8192 counts below
// 2^28 so the RTL's 28-bit sum + 8192 cannot overflow before the comparison.
// Decimal only: reject overflow, trailing junk, signs and silent truncation.
inline bool ven_parse_rtc_rate(const char *text, uint32_t &rate) {
    if (!text || !*text) return false;
    uint32_t value = 0;
    for (const char *p = text; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
        const uint32_t digit = uint32_t(*p - '0');
        if (value > (0x0fffffffu - digit) / 10u) return false;
        value = value * 10u + digit;
    }
    if (value < 8192u || value > 0x10000000u - 8192u) return false;
    rate = value;
    return true;
}
