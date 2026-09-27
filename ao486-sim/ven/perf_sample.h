#pragma once
#include <cstdio>
#include <cstdint>

// Optional generated members are detected in C++, not via RTL +defines (which
// do not propagate to the C++ compiler). These are cumulative observations,
// not architectural .vtrace records. Difference samples within one reset epoch.
#define VEN_PP(root, field) ((root).system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##field)
// CHECK-only counters must remain optional even in PERF builds. Periodic
// samples permit gameplay-only deltas; the RTL final report includes startup.
template<class Root>
auto ven_umap_sample(FILE *out, const Root &root, uint64_t cycle, int)
    -> decltype((void)VEN_PP(root, pp_umap_ref_would_issue), bool()) {
    std::fprintf(out, "[VEN-UMAP] cycle=%llu raw=%llu would_issue=%llu fp=%llu nonsimple=%llu simple_mem=%llu fastctx=%llu sysblock=%llu",
        (unsigned long long)cycle,
        (unsigned long long)VEN_PP(root, pp_umap_raw),
        (unsigned long long)VEN_PP(root, pp_umap_ref_would_issue),
        (unsigned long long)VEN_PP(root, pp_umap_ref_fp),
        (unsigned long long)VEN_PP(root, pp_umap_ref_nonsimple),
        (unsigned long long)VEN_PP(root, pp_umap_ref_simple_mem),
        (unsigned long long)VEN_PP(root, pp_umap_ref_simple_fastctx),
        (unsigned long long)VEN_PP(root, pp_umap_ref_simple_sysblock));
    const auto array = [out](const char *name, const auto &values) {
        std::fprintf(out, " %s=", name);
        for (unsigned i = 0; i < values.size(); ++i)
            std::fprintf(out, "%s%llu", i ? "," : "", (unsigned long long)values[i]);
    };
    array("fastend", VEN_PP(root, pp_umap_fastend));
    array("would_issue_end", VEN_PP(root, pp_umap_would_issue_end));
    std::fprintf(out, "\n");
    return true;
}
template<class Root>
bool ven_umap_sample(FILE *, const Root &, uint64_t, long) { return false; }

// Pairing rejection counters already exist in the generated model. Export
// them separately so existing VEN-PERF consumers retain their fixed schema.
// These classify the live-descriptor profiler's issue-eligible bucket, not
// committed packets or all stall clocks; see pp_pair/pp_pair_deny in core.sv.
template<class Root>
auto ven_pair_sample(FILE *out, const Root &root, uint64_t cycle, int)
    -> decltype((void)VEN_PP(root, pp_pair),
                (void)VEN_PP(root, pp_pair_deny), bool()) {
    std::fprintf(out, "[VEN-PAIR] cycle=%llu", (unsigned long long)cycle);
    const auto array = [out](const char *name, const auto &values) {
        std::fprintf(out, " %s=", name);
        for (unsigned i = 0; i < values.size(); ++i)
            std::fprintf(out, "%s%llu", i ? "," : "", (unsigned long long)values[i]);
    };
    array("issue", VEN_PP(root, pp_pair));
    array("deny", VEN_PP(root, pp_pair_deny));
    std::fprintf(out, "\n");
    return true;
}
template<class Root>
bool ven_pair_sample(FILE *, const Root &, uint64_t, long) { return false; }

template<class Root>
auto ven_perf_sample(FILE *out, const Root &root, uint64_t cycle, uint64_t retires, int)
    -> decltype((void)VEN_PP(root, pp_cycles), bool()) {
    std::fprintf(out, "[VEN-PERF] cycle=%llu retires=%llu clocks=%llu u=%llu v=%llu load_wait=%llu store_wait=%llu",
        (unsigned long long)cycle, (unsigned long long)retires,
        (unsigned long long)VEN_PP(root, pp_cycles),
        (unsigned long long)VEN_PP(root, pp_ret1),
        (unsigned long long)VEN_PP(root, pp_ret2),
        (unsigned long long)VEN_PP(root, pp_memwait_load),
        (unsigned long long)VEN_PP(root, pp_memwait_store));
    const auto array = [out](const char *name, const auto &values) {
        std::fprintf(out, " %s=", name);
        for (unsigned i = 0; i < values.size(); ++i)
            std::fprintf(out, "%s%llu", i ? "," : "", (unsigned long long)values[i]);
    };
    array("state", VEN_PP(root, pp_state));
    array("mem_wait", VEN_PP(root, pp_mem_wait));
    array("mem_ack", VEN_PP(root, pp_mem_ack));
    array("bail", VEN_PP(root, pp_bail));
    // Indexed by ventium_alu_pkg's ALU_* enum. Residency is only the slow
    // operand-load phase, not the whole instruction's execution cost.
    array("alu_load", VEN_PP(root, pp_slow_alu_load_op));
    array("alu_load_wait", VEN_PP(root, pp_slow_alu_load_wait_op));
    array("alu_load_ack", VEN_PP(root, pp_slow_alu_load_ack_op));
    std::fprintf(out, "\n");
    ven_umap_sample(out, root, cycle, 0);
    ven_pair_sample(out, root, cycle, 0);
    std::fflush(out);
    return true;
}
template<class Root>
bool ven_perf_sample(FILE *, const Root &, uint64_t, uint64_t, long) {
    return false; // Non-profile elaborations remain buildable.
}
#undef VEN_PP
