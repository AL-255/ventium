#include "perf_sample.h"
#include <array>
#include <cassert>
#include <cstring>

struct Counters {
    std::array<uint64_t, 9> system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__pp_pair
        {{0, 1, 2, 3, 4, 5, 6, 7, 8}};
    std::array<uint64_t, 7> system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__pp_pair_deny
        {{0, 1, 2, 3, 4, 5, 6}};
};
struct Missing {};
struct Partial {
    std::array<uint64_t, 9> system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__pp_pair{};
};
int main() {
    FILE *out = std::tmpfile();
    assert(out);
    assert(!ven_pair_sample(out, Missing{}, 5, 0));
    assert(!ven_pair_sample(out, Partial{}, 5, 0));
    assert(std::ftell(out) == 0);
    const Counters counters;
    assert(ven_pair_sample(out, counters, 1300000000, 0));
    std::rewind(out);
    char line[256];
    assert(std::fgets(line, sizeof(line), out));
    assert(!std::strcmp(line, "[VEN-PAIR] cycle=1300000000 issue=0,1,2,3,4,5,6,7,8 deny=0,1,2,3,4,5,6\n"));
    assert(std::fgetc(out) == EOF);
    std::fclose(out);
    std::puts("PAIR-SAMPLE-OK (optional members and exact schema)");
}
