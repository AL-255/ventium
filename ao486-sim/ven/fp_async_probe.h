// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include <cstdint>
#include <cstdio>

// Called only inside the existing bounded pre-rising-edge state trace. These
// are live request/commit predicates, not the previous edge's retire pulse.
// No host state is retained, so native checkpoint contents are unaffected.
#define VEN_ASYNC_OBS(r, name) ((r).system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name)
template<class Root>
auto ven_fp_async_probe(FILE *out, const Root &r, uint64_t cycle, int)
    -> decltype((void)VEN_ASYNC_OBS(r, fp_async_pending),
                (void)VEN_ASYNC_OBS(r, fp_async_hold),
                (void)VEN_ASYNC_OBS(r, fp_async_fault_hold),
                (void)VEN_ASYNC_OBS(r, fp_async_start),
                (void)VEN_ASYNC_OBS(r, pipe_int_commit),
                (void)VEN_ASYNC_OBS(r, pipe_pair), bool()) {
    std::fprintf(out, "[VEN-FPASYNC] cyc=%llu pending=%u hold=%u fault_hold=%u start=%u int_commit=%u pair=%u\n",
        (unsigned long long)cycle,
        (unsigned)VEN_ASYNC_OBS(r, fp_async_pending),
        (unsigned)VEN_ASYNC_OBS(r, fp_async_hold),
        (unsigned)VEN_ASYNC_OBS(r, fp_async_fault_hold),
        (unsigned)VEN_ASYNC_OBS(r, fp_async_start),
        (unsigned)VEN_ASYNC_OBS(r, pipe_int_commit),
        (unsigned)VEN_ASYNC_OBS(r, pipe_pair));
    return true;
}
template<class Root>
bool ven_fp_async_probe(FILE *, const Root &, uint64_t, long) { return false; }
#undef VEN_ASYNC_OBS
