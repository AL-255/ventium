#pragma once
#include <cstdint>
#include <cstdio>

// Read-only, pre-edge observations. No inferred transactions or saved state.
// The generated hierarchy is optional: other elaborations emit no record.
#define VEN_L1_OBS(name) r.system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__##name
#define VEN_DC_OBS(name) VEN_L1_OBS(u_l1d__DOT__##name)
#define VEN_CORE_OBS(name) r.system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name
// This input alias is optimized away in some generated models. Its absence
// must not disable all other observations or be misreported as flush=0.
template<class Root>
auto ven_l1_flush_observation(const Root &r, int)
    -> decltype((void)VEN_L1_OBS(__Vcellinp__u_l1d__flush_all), int()) {
    return int(VEN_L1_OBS(__Vcellinp__u_l1d__flush_all));
}
template<class Root>
int ven_l1_flush_observation(const Root &, long) { return -1; }
template<class Root>
auto ven_l1_fill_probe(FILE *out, const Root &r, uint64_t cycle, int)
    -> decltype((void)VEN_L1_OBS(l1d_c_req), (void)VEN_L1_OBS(l1d_c_ack),
                (void)VEN_L1_OBS(l1d_cacheable),
                (void)VEN_CORE_OBS(bd_addr), (void)VEN_CORE_OBS(bd_we),
                (void)VEN_DC_OBS(st), (void)VEN_DC_OBS(rd_hit),
                (void)VEN_DC_OBS(xline), (void)VEN_DC_OBS(fbase),
                (void)VEN_DC_OBS(fw), (void)VEN_DC_OBS(fill_poison),
                (void)VEN_DC_OBS(bypass_q), (void)VEN_DC_OBS(early_addr_q), bool()) {
    std::fprintf(out,
        "VENL1 cyc=%llu req=%u ack=%u we=%u addr=%08x cacheable=%u "
        "state=%u hit=%u xline=%u fill=%08x words=%u poison=%u bypass=%u flush=%d owner=%08x\n",
        (unsigned long long)cycle,
        (unsigned)VEN_L1_OBS(l1d_c_req), (unsigned)VEN_L1_OBS(l1d_c_ack),
        (unsigned)VEN_CORE_OBS(bd_we), (unsigned)VEN_CORE_OBS(bd_addr),
        (unsigned)VEN_L1_OBS(l1d_cacheable), (unsigned)VEN_DC_OBS(st),
        (unsigned)VEN_DC_OBS(rd_hit), (unsigned)VEN_DC_OBS(xline),
        (unsigned)VEN_DC_OBS(fbase), (unsigned)VEN_DC_OBS(fw),
        (unsigned)VEN_DC_OBS(fill_poison), (unsigned)VEN_DC_OBS(bypass_q),
        ven_l1_flush_observation(r, 0),
        (unsigned)VEN_DC_OBS(early_addr_q));
    return true;
}
template<class Root>
bool ven_l1_fill_probe(FILE *, const Root &, uint64_t, long) { return false; }
#undef VEN_CORE_OBS
#undef VEN_DC_OBS
#undef VEN_L1_OBS
