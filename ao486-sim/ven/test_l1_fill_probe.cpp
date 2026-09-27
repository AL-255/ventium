#include "l1_fill_probe.h"
#include <cassert>
#include <cstring>
#include <type_traits>

#define L1(name) system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__##name
#define DC(name) L1(u_l1d__DOT__##name)
#define CORE(name) system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name
struct Partial {
    unsigned L1(l1d_c_req) = 1;
};
struct Observation : Partial {
    unsigned L1(l1d_c_ack) = 0, L1(l1d_cacheable) = 1;
    unsigned L1(__Vcellinp__u_l1d__flush_all) = 0;
    unsigned CORE(bd_addr) = 0x12345678, CORE(bd_we) = 0;
    unsigned DC(st) = 1, DC(rd_hit) = 1, DC(xline) = 0;
    unsigned DC(fbase) = 0x8765432c, DC(fw) = 3;
    unsigned DC(fill_poison) = 0, DC(bypass_q) = 0;
    unsigned DC(early_addr_q) = 0x8765432c;
};
#undef CORE
#undef DC
#undef L1

#ifdef VEN_L1_PROBE_GENERATED
#include "Vsystem___024root.h"
// Syntax-only instantiation verifies the real frozen generated hierarchy.
void check_generated(const Vsystem___024root &root) {
    static_assert(std::is_same_v<decltype(ven_l1_fill_probe(nullptr, root, 0, 0)), bool>);
    // Taking the int-overload specialization explicitly prevents an accidental
    // missing-field fallback from passing this hierarchy check.
    bool (*probe)(FILE *, const Vsystem___024root &, uint64_t, int) =
        &ven_l1_fill_probe<Vsystem___024root>;
    (void)probe;
}
#endif

int main() {
    FILE *out = std::tmpfile();
    assert(out);
    struct Absent {};
    assert(!ven_l1_fill_probe(out, Absent{}, 1, 0));
    assert(!ven_l1_fill_probe(out, Partial{}, 2, 0));
    assert(std::ftell(out) == 0);
    const Observation observation;
    assert(ven_l1_fill_probe(out, observation, 1301000000, 0));
    std::rewind(out);
    char line[512]{};
    assert(std::fgets(line, sizeof line, out));
    assert(!std::strcmp(line,
        "VENL1 cyc=1301000000 req=1 ack=0 we=0 addr=12345678 cacheable=1 "
        "state=1 hit=1 xline=0 fill=8765432c words=3 poison=0 bypass=0 flush=0 owner=8765432c\n"));
    assert(!std::fgets(line, sizeof line, out));
    std::fclose(out);
    std::puts("L1-FILL-PROBE-OK (present, partial, absent)");
}
