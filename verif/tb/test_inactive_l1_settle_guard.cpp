// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "inactive_l1_settle_guard.h"
#include <cassert>
#define ZERO_INPUTS(X) \
    X(boot_mode) X(bus_mode) X(l1axi_en) X(shutdown) X(golden_l1) X(cosim_en) \
    X(dbg_halt_req) X(dbg_step) X(dbg_bp_en) X(dbg_bp_clr) X(dbg_bp_addr) \
    X(dbg_arch_sel) X(dbg_hook_cfg) X(dbg_cmp_cfg) X(dbg_cmp_range) \
    X(m_axi_awvalid) X(m_axi_wvalid) X(m_axi_arvalid) X(m_axi_bvalid) X(m_axi_rvalid)
struct FakeTop {
    unsigned rst_n=1, cycle_mode=1;
#define FIELD(name) unsigned name=0;
    ZERO_INPUTS(FIELD)
#undef FIELD
#ifdef TEST_EXPOSED_SOC_PORT
    unsigned soc_en=0;
#endif
};
int main() {
    FakeTop top;
    assert(inactive_l1_settle_inputs(top));
#define MUTATE(name) top.name=1; assert(!inactive_l1_settle_inputs(top)); top.name=0;
    ZERO_INPUTS(MUTATE)
#undef MUTATE
    top.rst_n=0;assert(!inactive_l1_settle_inputs(top));top.rst_n=1;
    top.cycle_mode=0;assert(!inactive_l1_settle_inputs(top));
    std::puts("INACTIVE_L1_GUARD_OK 22 control mutations");
}
