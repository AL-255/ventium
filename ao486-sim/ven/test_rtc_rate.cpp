#include "rtc_rate.h"
#include <cassert>
#include <cstdio>

int main() {
    uint32_t rate = 17;
    const char *bad[] = {nullptr, "", "0", "8191", "-45000000", "+45000000",
        "45000000x", " 45000000", "45000000 ", "0x2aea540", "268435456",
        "268435455", "268427265",
        "4294967296", "999999999999999999999999999999999999"};
    for (auto text : bad) {
        assert(!ven_parse_rtc_rate(text, rate));
        assert(rate == 17);
    }
    assert(ven_parse_rtc_rate("8192", rate) && rate == 8192);
    assert(ven_parse_rtc_rate("80000", rate) && rate == 80000);
    assert(ven_parse_rtc_rate("45000000", rate) && rate == 45000000);
    assert(ven_parse_rtc_rate("268427264", rate) && rate == 268427264);
    std::puts("RTC-RATE-PARSER-OK");
}
