#include "perf_sample.h"
#include <array>
#include <cassert>
#include <cstring>

#define FIELD(name) system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name
struct Profile {
    uint64_t FIELD(pp_cycles) = 100, FIELD(pp_ret1) = 20, FIELD(pp_ret2) = 5;
    uint64_t FIELD(pp_memwait_load) = 30, FIELD(pp_memwait_store) = 4;
    std::array<uint64_t, 3> FIELD(pp_state){{10, 20, 70}};
    std::array<uint64_t, 3> FIELD(pp_mem_wait){{1, 2, 3}};
    std::array<uint64_t, 3> FIELD(pp_mem_ack){{4, 5, 6}};
    std::array<uint64_t, 2> FIELD(pp_bail){{7, 8}};
    std::array<uint64_t, 3> FIELD(pp_slow_alu_load_op){{9, 10, 11}};
    std::array<uint64_t, 3> FIELD(pp_slow_alu_load_wait_op){{3, 4, 5}};
    std::array<uint64_t, 3> FIELD(pp_slow_alu_load_ack_op){{6, 6, 6}};
};
struct CheckProfile : Profile {
    uint64_t FIELD(pp_umap_raw) = 40, FIELD(pp_umap_ref_would_issue) = 9;
    uint64_t FIELD(pp_umap_ref_fp) = 2, FIELD(pp_umap_ref_nonsimple) = 3;
    uint64_t FIELD(pp_umap_ref_simple_mem) = 4;
    uint64_t FIELD(pp_umap_ref_simple_fastctx) = 12;
    uint64_t FIELD(pp_umap_ref_simple_sysblock) = 5;
    std::array<uint64_t, 3> FIELD(pp_umap_fastend){{6, 4, 2}};
    std::array<uint64_t, 3> FIELD(pp_umap_would_issue_end){{5, 3, 1}};
};
#undef FIELD
int main() {
    FILE *f = std::tmpfile();
    assert(f);
    struct NoProfile {};
    assert(!ven_perf_sample(f, NoProfile{}, 100, 25, 0));
    assert(std::ftell(f) == 0);
    const Profile p;
    assert(ven_perf_sample(f, p, 120, 25, 0));
    std::rewind(f);
    char line[1024]{};
    assert(std::fgets(line, sizeof line, f));
    assert(!std::strcmp(line, "[VEN-PERF] cycle=120 retires=25 clocks=100 u=20 v=5 load_wait=30 store_wait=4 state=10,20,70 mem_wait=1,2,3 mem_ack=4,5,6 bail=7,8 alu_load=9,10,11 alu_load_wait=3,4,5 alu_load_ack=6,6,6\n"));
    assert(!std::fgets(line, sizeof line, f));
    std::fclose(f);
    f = std::tmpfile();
    assert(f);
    assert(ven_perf_sample(f, CheckProfile{}, 200, 25, 0));
    std::rewind(f);
    assert(std::fgets(line, sizeof line, f));
    assert(std::strstr(line, "[VEN-PERF] cycle=200 ") == line);
    assert(std::fgets(line, sizeof line, f));
    assert(!std::strcmp(line, "[VEN-UMAP] cycle=200 raw=40 would_issue=9 fp=2 nonsimple=3 simple_mem=4 fastctx=12 sysblock=5 fastend=6,4,2 would_issue_end=5,3,1\n"));
    assert(!std::fgets(line, sizeof line, f));
    std::fclose(f);
    std::puts("PERF-SAMPLE-OK (absent, PERF-only, PERF+CHECK)");
}
