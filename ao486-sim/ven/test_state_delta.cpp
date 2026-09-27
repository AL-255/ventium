#include "state_delta.h"
#include <array>
#include <cassert>
int main(int argc, char** argv) {
    assert(argc == 2);
    StateDelta delta;
    uint32_t counter = 0;
    std::array<uint8_t, 35> cache{};
    delta.add("counter", counter, "uint32_t");
    delta.add("cache", cache, "uint8_t[35]");
    delta.open(argv[1], 100, 4);
    counter = 1; cache[0] = 42; cache[34] = 255;
    delta.sample(101);
    delta.sample(102); // Completely unchanged cycle must still be present.
    cache[0] = 0; cache[17] = 17; counter = 0xffffffff;
    delta.sample(103);
    counter = 0;
    delta.sample(104);
    assert(delta.complete());
}
