#pragma once
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Read-only pre-edge sample. Counts primary retirements in a named integer
// block while the shared FPU's registered state is non-IDLE. No extra evals.
struct FpOverlapProbe {
    bool enabled=false;
    uint32_t lo=0,hi=0;
    uint64_t busy=0,integer=0,overlap=0;
    uint64_t overlap_at_commit=0;
    bool previous_busy=false;
    static uint32_t address(const char* text) {
        if (!text) std::abort();
        if (text[0]=='0' && (text[1]=='x'||text[1]=='X')) text+=2;
        uint32_t value=0;
        const auto end=text+std::strlen(text);
        auto result=std::from_chars(text,end,value,16);
        if (result.ec!=std::errc() || result.ptr!=end || text==end) std::abort();
        return value;
    }
    FpOverlapProbe() {
        const char* lower=std::getenv("VEN_FP_OVERLAP_LO");
        const char* upper=std::getenv("VEN_FP_OVERLAP_HI");
        if (!lower && !upper) return;
        lo=address(lower); hi=address(upper);
        if (lo>=hi) std::abort();
        enabled=true;
    }
    template<class T> void record(const T& r,bool pending) {
        if (!enabled) return;
        busy+=pending;
        const uint32_t pc=r.ventium_top__DOT__core_retire_pc;
        if (r.ventium_top__DOT__core_retire_valid && pc>=lo && pc<hi) {
            ++integer;
            overlap+=pending;
            // retire_valid/PC describe the preceding rising-edge commit.
            // The FPU may have transitioned to IDLE on that same edge. Keep
            // the original simultaneous-level counter above for comparison,
            // but align this witness to the sampled pre-commit busy state.
            overlap_at_commit+=previous_busy;
        }
        previous_busy=pending;
    }
    // The shared-FP wrapper now contains a u_fp leaf. Keep the old hierarchy
    // for archived testbench builds; an absent busy signal must fail loudly,
    // never turn a throughput gate into a zero-overlap false measurement.
    template<class T> auto sample(const T& r,int) -> decltype(
        (void)r.ventium_top__DOT__u_core__DOT__u_fp_shared__DOT__u_fp__DOT__top_state,void()) {
        record(r,r.ventium_top__DOT__u_core__DOT__u_fp_shared__DOT__u_fp__DOT__top_state!=0);
    }
    template<class T> auto sample(const T& r,long) -> decltype(
        (void)r.ventium_top__DOT__u_core__DOT__u_fp_shared__DOT__top_state,void()) {
        record(r,r.ventium_top__DOT__u_core__DOT__u_fp_shared__DOT__top_state!=0);
    }
    template<class T> void sample(const T&,...) {
        if (enabled) { std::fprintf(stderr,"FP overlap probe requires shared-FPU model\n"); std::abort(); }
    }
    ~FpOverlapProbe() {
        if (enabled) std::fprintf(stderr,"[FP-OVERLAP] busy_cycles=%llu integer_primary=%llu overlapping_primary=%llu\n",
            (unsigned long long)busy,(unsigned long long)integer,(unsigned long long)overlap);
        if (enabled) std::fprintf(stderr,"[FP-OVERLAP-COMMIT] overlapping_primary=%llu\n",
            (unsigned long long)overlap_at_commit);
    }
};
