#include "slow_decode_profile.h"
#include <cassert>
#include <cstring>
#include <numeric>

int main() {
    SlowDecodeProfile p;
    std::array<uint8_t, 16> b{};
    b[0] = 0x8a;
    p.observe(1, b);
    assert(p.clocks[0x8a] == 0);
    p.observe(2, b);
    p.observe(2, b); // a held decode is deliberately two residency clocks
    assert(p.clocks[0x8a] == 2);
    b = {0x66, 0x67, 0x2e, 0x0f, 0xb6};
    p.observe(2, b);
    assert(p.clocks[256 + 0xb6] == 1 && p.prefixed == 1);
    b.fill(0x66);
    b[15] = 0x90; // byte 16 cannot make an overlength instruction valid
    p.observe(2, b);
    assert(p.clocks[512] == 1);
    b[14] = 0x0f;
    p.observe(2, b);
    assert(p.clocks[512] == 2);
    b[13] = 0x0f; b[14] = 0x90;
    p.observe(2, b);
    assert(p.clocks[256 + 0x90] == 1);
    std::array<uint8_t, 0> empty{};
    p.observe(2, empty);
    assert(p.clocks[512] == 3);
    assert(std::accumulate(p.clocks.begin(), p.clocks.end(), uint64_t(0)) == 7);
    FILE *f = std::tmpfile();
    assert(f);
    p.report(f, 123);
    std::rewind(f);
    char line[8192]{};
    assert(std::fgets(line, sizeof line, f));
    assert(std::strstr(line, "[VEN-SLOW-DECODE] cycle=123 prefixed=4 clocks=") == line);
    unsigned commas = 0;
    for (const char *c = line; *c; ++c) commas += *c == ',';
    assert(commas == 512);
    std::fclose(f);
    std::puts("SLOW-DECODE-PROFILE-OK");
}
