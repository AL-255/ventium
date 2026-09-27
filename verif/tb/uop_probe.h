// Optional host-only diagnostic. No signal writes, extra evals, or RTL ports.
#pragma once
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "Vventium_top___024root.h"

struct UopProbe {
    bool enabled=false, all=false;
    uint32_t pc=0;
    uint64_t start=0;
    unsigned emitted=0;
    static uint64_t number(const char* text) {
        char* end=nullptr;
        errno=0;
        unsigned long long n=std::strtoull(text,&end,0);
        if (errno || !*text || *end || *text=='-') {
            std::fprintf(stderr,"Invalid VEN_UOP_PROBE numeric value\n");
            std::exit(2);
        }
        return n;
    }
    UopProbe() {
        const char* value=std::getenv("VEN_UOP_PROBE_PC");
        if (!value) return;
        enabled=true; all=std::strcmp(value,"all")==0;
        if (!all) {
            uint64_t n=number(value);
            if (n>UINT32_MAX) std::exit(2);
            pc=static_cast<uint32_t>(n);
        }
        if (const char* s=std::getenv("VEN_UOP_PROBE_START")) start=number(s);
    }
    template<class T>
    auto sample(T* r,uint64_t cycle,int) ->
        decltype((void)r->ventium_top__DOT__u_core__DOT__uc_cross_sources_ready,void()) {
        if (!enabled || emitted>=512 || cycle<start) return;
        if (!all && r->ventium_top__DOT__u_core__DOT__flin!=pc) return;
        ++emitted;
#define C(name) unsigned(r->ventium_top__DOT__u_core__DOT__##name)
#define W(name) unsigned(r->ventium_top__DOT__u_core__DOT__u_uopcache__DOT__##name)
        std::fprintf(stderr,"[UOPPROBE] cyc=%llu flin=%08x state=%u ready=%u pdv=%u bv=%u repair=%u accept=%u sources=%u cross=%u walker=%u wrepair=%u set=%u off=%u anchor=%u poison=%u len=%u exec=%u fits=%u\n",
                     static_cast<unsigned long long>(cycle),C(flin),C(state),C(ic_fetch_ready),
                     C(uc_updvalid),C(uc_ubvalid),C(uc_repair_start),W(repair_ready),
                     C(uc_cross_sources_ready),C(uc_cross_ready),W(wst),W(wrepair),W(wset),
                     W(woff),W(wanchor),W(wpz),W(pd_len),W(pd_exec),W(pd_map_fits));
        // Pre-edge, registered ownership witness: this is an admitted packet,
        // not a live decode opportunity or an assertion of successful retire.
        // Keep separate from UOPPROBE so existing cache parsers retain their ABI.
        std::fprintf(stderr,"[MEMOWNER] cyc=%llu state=%u active=%u pc=%08x ea=%08x write=%u\n",
                     static_cast<unsigned long long>(cycle),C(state),C(pipe_mem_active_q),
                     C(pipe_mem_eip_q),C(pipe_mem_ea_q),C(pipe_mem_we_q));
#undef W
#undef C
    }
    template<class T> void sample(T*,uint64_t,long) {
        if (enabled) {
            std::fprintf(stderr,"VEN_UOP_PROBE requires a cross-line model\n");
            std::exit(2);
        }
    }
};
