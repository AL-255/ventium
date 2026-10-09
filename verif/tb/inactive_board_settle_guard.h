// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Runtime-disabled AXI/debug circuitry is not permission to elide an active
// device simulation. Check before EACH optional same-clock eval, not just once
// at launch. All generated inputs still participate in ModelInputSnapshot.
template<class T> bool inactive_board_settle_inputs(const T& t) {
    return t.rst_n && !t.boot_mode && !t.bus_mode && t.cycle_mode &&
           !t.l1axi_en && !t.shutdown && !t.golden_l1 &&
           !t.soc_en && !t.intr && !t.inta_vector && !t.cosim_en &&
           !t.dbg_halt_req && !t.dbg_step && !t.dbg_bp_en && !t.dbg_bp_clr &&
           !t.dbg_bp_addr && !t.dbg_arch_sel && !t.dbg_hook_cfg &&
           !t.dbg_cmp_cfg && !t.dbg_cmp_range &&
           !t.m_axi_awvalid && !t.m_axi_wvalid && !t.m_axi_arvalid &&
           !t.m_axi_bvalid && !t.m_axi_rvalid;
}

inline bool inactive_board_settle_environment(char** entries) {
    for (char** entry = entries; *entry; ++entry) {
        // Reject device/probe/state-injection controls, including future ones.
        // These two read-only observers are explicitly covered by the A/B gate.
        if (!std::strncmp(*entry, "TB_CLOCK_CYCLE_PROBE=", 21) ||
            !std::strncmp(*entry, "TB_SETTLE_FINAL_STATE=", 22)) continue;
        if (!std::strncmp(*entry, "VEN_", 4) || !std::strncmp(*entry, "AXI_", 4) ||
            !std::strncmp(*entry, "TB_", 3)) return false;
    }
    return true;
}

template<class T> void require_inactive_board_settle(const T& top) {
    if (!inactive_board_settle_inputs(top)) {
        std::fprintf(stderr, "tb: inactive-board settle profile became active; refusing elision\n");
        std::exit(2);
    }
}
