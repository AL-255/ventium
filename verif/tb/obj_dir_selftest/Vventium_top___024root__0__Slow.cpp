// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vventium_top.h for the primary calling header

#include "Vventium_top__pch.h"

VL_ATTR_COLD void Vventium_top___024root___eval_static(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_static\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.__Vtrigprevexpr___TOP__clk__0 = vlSelfRef.clk;
}

VL_ATTR_COLD void Vventium_top___024root___eval_initial(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_initial\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.mem_we = 0U;
    vlSelfRef.mem_wdata = 0U;
    vlSelfRef.mem_wstrb = 0U;
}

VL_ATTR_COLD void Vventium_top___024root___eval_initial__TOP(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_initial__TOP\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.mem_we = 0U;
    vlSelfRef.mem_wdata = 0U;
    vlSelfRef.mem_wstrb = 0U;
}

VL_ATTR_COLD void Vventium_top___024root___eval_final(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_final\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vventium_top___024root___dump_triggers__stl(const VlUnpacked<QData/*63:0*/, 1> &triggers, const std::string &tag);
#endif  // VL_DEBUG
VL_ATTR_COLD bool Vventium_top___024root___eval_phase__stl(Vventium_top___024root* vlSelf);

VL_ATTR_COLD void Vventium_top___024root___eval_settle(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_settle\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    IData/*31:0*/ __VstlIterCount;
    // Body
    __VstlIterCount = 0U;
    vlSelfRef.__VstlFirstIteration = 1U;
    do {
        if (VL_UNLIKELY(((0x00002710U < __VstlIterCount)))) {
#ifdef VL_DEBUG
            Vventium_top___024root___dump_triggers__stl(vlSelfRef.__VstlTriggered, "stl"s);
#endif
            VL_FATAL_MT("/home/yukidama/github/ventium/verif/tb/selftest/ventium_top.sv", 20, "", "DIDNOTCONVERGE: Settle region did not converge after '--converge-limit' of 10000 tries");
        }
        __VstlIterCount = ((IData)(1U) + __VstlIterCount);
        vlSelfRef.__VstlPhaseResult = Vventium_top___024root___eval_phase__stl(vlSelf);
        vlSelfRef.__VstlFirstIteration = 0U;
    } while (vlSelfRef.__VstlPhaseResult);
}

VL_ATTR_COLD void Vventium_top___024root___eval_triggers_vec__stl(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_triggers_vec__stl\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.__VstlTriggered[0U] = ((0xfffffffffffffffeULL 
                                      & vlSelfRef.__VstlTriggered[0U]) 
                                     | (IData)((IData)(vlSelfRef.__VstlFirstIteration)));
}

VL_ATTR_COLD bool Vventium_top___024root___trigger_anySet__stl(const VlUnpacked<QData/*63:0*/, 1> &in);

#ifdef VL_DEBUG
VL_ATTR_COLD void Vventium_top___024root___dump_triggers__stl(const VlUnpacked<QData/*63:0*/, 1> &triggers, const std::string &tag) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___dump_triggers__stl\n"); );
    // Body
    if ((1U & (~ (IData)(Vventium_top___024root___trigger_anySet__stl(triggers))))) {
        VL_DBG_MSGS("         No '" + tag + "' region triggers active\n");
    }
    if ((1U & (IData)(triggers[0U]))) {
        VL_DBG_MSGS("         '" + tag + "' region trigger index 0 is active: Internal 'stl' trigger - first iteration\n");
    }
}
#endif  // VL_DEBUG

VL_ATTR_COLD bool Vventium_top___024root___trigger_anySet__stl(const VlUnpacked<QData/*63:0*/, 1> &in) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___trigger_anySet__stl\n"); );
    // Locals
    IData/*31:0*/ n;
    // Body
    n = 0U;
    do {
        if (in[n]) {
            return (1U);
        }
        n = ((IData)(1U) + n);
    } while ((1U > n));
    return (0U);
}

VL_ATTR_COLD void Vventium_top___024root___stl_sequent__TOP__0(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___stl_sequent__TOP__0\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.mem_addr = ((IData)(0x08048000U) + (IData)(vlSelfRef.ventium_top__DOT__seq));
    vlSelfRef.mem_req = ((~ (IData)(vlSelfRef.ventium_top__DOT__done)) 
                         & (IData)(vlSelfRef.rst_n));
}

VL_ATTR_COLD void Vventium_top___024root___eval_stl(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_stl\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1ULL & vlSelfRef.__VstlTriggered[0U])) {
        vlSelfRef.mem_addr = ((IData)(0x08048000U) 
                              + (IData)(vlSelfRef.ventium_top__DOT__seq));
        vlSelfRef.mem_req = ((~ (IData)(vlSelfRef.ventium_top__DOT__done)) 
                             & (IData)(vlSelfRef.rst_n));
    }
}

VL_ATTR_COLD bool Vventium_top___024root___eval_phase__stl(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_phase__stl\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    CData/*0:0*/ __VstlExecute;
    // Body
    Vventium_top___024root___eval_triggers_vec__stl(vlSelf);
#ifdef VL_DEBUG
    if (VL_UNLIKELY(vlSymsp->_vm_contextp__->debug())) {
        Vventium_top___024root___dump_triggers__stl(vlSelfRef.__VstlTriggered, "stl"s);
    }
#endif
    __VstlExecute = Vventium_top___024root___trigger_anySet__stl(vlSelfRef.__VstlTriggered);
    if (__VstlExecute) {
        Vventium_top___024root___eval_stl(vlSelf);
    }
    return (__VstlExecute);
}

bool Vventium_top___024root___trigger_anySet__ico(const VlUnpacked<QData/*63:0*/, 1> &in);

#ifdef VL_DEBUG
VL_ATTR_COLD void Vventium_top___024root___dump_triggers__ico(const VlUnpacked<QData/*63:0*/, 1> &triggers, const std::string &tag) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___dump_triggers__ico\n"); );
    // Body
    if ((1U & (~ (IData)(Vventium_top___024root___trigger_anySet__ico(triggers))))) {
        VL_DBG_MSGS("         No '" + tag + "' region triggers active\n");
    }
    if ((1U & (IData)(triggers[0U]))) {
        VL_DBG_MSGS("         '" + tag + "' region trigger index 0 is active: Internal 'ico' trigger - first iteration\n");
    }
}
#endif  // VL_DEBUG

bool Vventium_top___024root___trigger_anySet__act(const VlUnpacked<QData/*63:0*/, 1> &in);

#ifdef VL_DEBUG
VL_ATTR_COLD void Vventium_top___024root___dump_triggers__act(const VlUnpacked<QData/*63:0*/, 1> &triggers, const std::string &tag) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___dump_triggers__act\n"); );
    // Body
    if ((1U & (~ (IData)(Vventium_top___024root___trigger_anySet__act(triggers))))) {
        VL_DBG_MSGS("         No '" + tag + "' region triggers active\n");
    }
    if ((1U & (IData)(triggers[0U]))) {
        VL_DBG_MSGS("         '" + tag + "' region trigger index 0 is active: @(posedge clk)\n");
    }
}
#endif  // VL_DEBUG

VL_ATTR_COLD void Vventium_top___024root___ctor_var_reset(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___ctor_var_reset\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    const uint64_t __VscopeHash = VL_MURMUR64_HASH(vlSelf->vlNamep);
    vlSelf->clk = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 16707436170211756652ull);
    vlSelf->rst_n = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 1638864771569018232ull);
    vlSelf->mem_req = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 14303737313341316090ull);
    vlSelf->mem_we = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 15973559030946811212ull);
    vlSelf->mem_addr = VL_SCOPED_RAND_RESET_I(32, __VscopeHash, 326597072690670135ull);
    vlSelf->mem_wdata = VL_SCOPED_RAND_RESET_I(32, __VscopeHash, 5431754401481461448ull);
    vlSelf->mem_wstrb = VL_SCOPED_RAND_RESET_I(4, __VscopeHash, 8859681292774497410ull);
    vlSelf->mem_rdata = VL_SCOPED_RAND_RESET_I(32, __VscopeHash, 9659133473039683418ull);
    vlSelf->mem_ack = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 18086694085071741504ull);
    vlSelf->ventium_top__DOT__seq = VL_SCOPED_RAND_RESET_Q(64, __VscopeHash, 9121443820594509923ull);
    vlSelf->ventium_top__DOT__done = VL_SCOPED_RAND_RESET_I(1, __VscopeHash, 14235143756803353506ull);
    for (int __Vi0 = 0; __Vi0 < 1; ++__Vi0) {
        vlSelf->__VstlTriggered[__Vi0] = 0;
    }
    for (int __Vi0 = 0; __Vi0 < 1; ++__Vi0) {
        vlSelf->__VicoTriggered[__Vi0] = 0;
    }
    for (int __Vi0 = 0; __Vi0 < 1; ++__Vi0) {
        vlSelf->__VactTriggered[__Vi0] = 0;
    }
    vlSelf->__Vtrigprevexpr___TOP__clk__0 = 0;
    for (int __Vi0 = 0; __Vi0 < 1; ++__Vi0) {
        vlSelf->__VnbaTriggered[__Vi0] = 0;
    }
}
