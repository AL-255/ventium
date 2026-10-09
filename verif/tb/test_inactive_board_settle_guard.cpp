// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "inactive_board_settle_guard.h"
#include <cassert>

#define ZERO_INPUTS(X) \
    X(boot_mode) X(bus_mode) X(l1axi_en) X(shutdown) X(golden_l1) \
    X(soc_en) X(intr) X(inta_vector) X(cosim_en) \
    X(dbg_halt_req) X(dbg_step) X(dbg_bp_en) X(dbg_bp_clr) X(dbg_bp_addr) \
    X(dbg_arch_sel) X(dbg_hook_cfg) X(dbg_cmp_cfg) X(dbg_cmp_range) \
    X(m_axi_awvalid) X(m_axi_wvalid) X(m_axi_arvalid) X(m_axi_bvalid) X(m_axi_rvalid)
struct FakeTop {
    unsigned rst_n = 1, cycle_mode = 1;
#define FIELD(name) unsigned name = 0;
    ZERO_INPUTS(FIELD)
#undef FIELD
};
int main() {
    FakeTop top;
    assert(inactive_board_settle_inputs(top));
#define MUTATE(name) top.name = 1; assert(!inactive_board_settle_inputs(top)); top.name = 0;
    ZERO_INPUTS(MUTATE)
#undef MUTATE
    top.rst_n = 0; assert(!inactive_board_settle_inputs(top)); top.rst_n = 1;
    top.cycle_mode = 0; assert(!inactive_board_settle_inputs(top)); top.cycle_mode = 1;
    char allowed0[] = "PATH=/bin", allowed1[] = "TB_CLOCK_CYCLE_PROBE=1";
    char allowed2[] = "TB_SETTLE_FINAL_STATE=/run/model";
    char* allowed[] = {allowed0, allowed1, allowed2, nullptr};
    assert(inactive_board_settle_environment(allowed));
    const char* rejected[] = {"VEN_HOOK=0", "VEN_NEW_DEVICE=1", "AXI_STUCK=1",
        "TB_NEW_PROBE=1", "TB_SETTLE_FINAL_STATE_X=x", "TB_CLOCK_CYCLE_PROBE_X=1"};
    for (const char* value : rejected) {
        char* env[] = {const_cast<char*>(value), nullptr};
        assert(!inactive_board_settle_environment(env));
    }
    std::puts("INACTIVE_BOARD_GUARD_OK 25 control mutations + 6 environment refusals");
}
