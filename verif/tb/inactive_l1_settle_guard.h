// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "inactive_board_settle_guard.h"
#include <type_traits>
#include <utility>

// In the non-KV260 verification top the SoC interrupt inputs are absent,
// and u_core's soc_en/INTR/NMI/INTA-valid/vector are tied to zero in RTL.
// Never instantiate this narrower guard for a model exposing those inputs.
template<class T, class = void> struct HasSettleSocEn : std::false_type {};
template<class T> struct HasSettleSocEn<T, std::void_t<decltype(std::declval<T>().soc_en)>> : std::true_type {};
template<class T, class = void> struct HasSettleIntr : std::false_type {};
template<class T> struct HasSettleIntr<T, std::void_t<decltype(std::declval<T>().intr)>> : std::true_type {};
template<class T, class = void> struct HasSettleVector : std::false_type {};
template<class T> struct HasSettleVector<T, std::void_t<decltype(std::declval<T>().inta_vector)>> : std::true_type {};

template<class T> bool inactive_l1_settle_inputs(const T& t) {
    static_assert(!HasSettleSocEn<T>::value && !HasSettleIntr<T>::value &&
                  !HasSettleVector<T>::value, "use the complete board guard for exposed interrupt ports");
    return t.rst_n && !t.boot_mode && !t.bus_mode && t.cycle_mode &&
           !t.l1axi_en && !t.shutdown && !t.golden_l1 && !t.cosim_en &&
           !t.dbg_halt_req && !t.dbg_step && !t.dbg_bp_en && !t.dbg_bp_clr &&
           !t.dbg_bp_addr && !t.dbg_arch_sel && !t.dbg_hook_cfg &&
           !t.dbg_cmp_cfg && !t.dbg_cmp_range &&
           !t.m_axi_awvalid && !t.m_axi_wvalid && !t.m_axi_arvalid &&
           !t.m_axi_bvalid && !t.m_axi_rvalid;
}

template<class T> void require_inactive_l1_settle(const T& top) {
    if (!inactive_l1_settle_inputs(top)) {
        std::fprintf(stderr, "tb: inactive-L1 settle profile became active; refusing elision\n");
        std::exit(2);
    }
}
