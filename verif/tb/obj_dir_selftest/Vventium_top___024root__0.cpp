// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vventium_top.h for the primary calling header

#include "Vventium_top__pch.h"

extern "C" void vtm_retire(unsigned long long n, unsigned int pc, unsigned int eflags, unsigned int eax, unsigned int ecx, unsigned int edx, unsigned int ebx, unsigned int esp, unsigned int ebp, unsigned int esi, unsigned int edi, unsigned short cs, unsigned short ss, unsigned short ds, unsigned short es, unsigned short fs, unsigned short gs);

void Vventium_top___024root____Vdpiimwrap_ventium_top__DOT__vtm_retire_TOP(const VerilatedScope* __Vscopep, const char* __Vfilenamep, IData/*31:0*/ __Vlineno, QData/*63:0*/ n, IData/*31:0*/ pc, IData/*31:0*/ eflags, IData/*31:0*/ eax, IData/*31:0*/ ecx, IData/*31:0*/ edx, IData/*31:0*/ ebx, IData/*31:0*/ esp, IData/*31:0*/ ebp, IData/*31:0*/ esi, IData/*31:0*/ edi, SData/*15:0*/ cs, SData/*15:0*/ ss, SData/*15:0*/ ds, SData/*15:0*/ es, SData/*15:0*/ fs, SData/*15:0*/ gs) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root____Vdpiimwrap_ventium_top__DOT__vtm_retire_TOP\n"); );
    // Body
    unsigned long long n__Vcvt;
    n__Vcvt = n;
    unsigned int pc__Vcvt;
    pc__Vcvt = pc;
    unsigned int eflags__Vcvt;
    eflags__Vcvt = eflags;
    unsigned int eax__Vcvt;
    eax__Vcvt = eax;
    unsigned int ecx__Vcvt;
    ecx__Vcvt = ecx;
    unsigned int edx__Vcvt;
    edx__Vcvt = edx;
    unsigned int ebx__Vcvt;
    ebx__Vcvt = ebx;
    unsigned int esp__Vcvt;
    esp__Vcvt = esp;
    unsigned int ebp__Vcvt;
    ebp__Vcvt = ebp;
    unsigned int esi__Vcvt;
    esi__Vcvt = esi;
    unsigned int edi__Vcvt;
    edi__Vcvt = edi;
    unsigned short cs__Vcvt;
    cs__Vcvt = cs;
    unsigned short ss__Vcvt;
    ss__Vcvt = ss;
    unsigned short ds__Vcvt;
    ds__Vcvt = ds;
    unsigned short es__Vcvt;
    es__Vcvt = es;
    unsigned short fs__Vcvt;
    fs__Vcvt = fs;
    unsigned short gs__Vcvt;
    gs__Vcvt = gs;
    Verilated::dpiContext(__Vscopep, __Vfilenamep, __Vlineno);
    vtm_retire(n__Vcvt, pc__Vcvt, eflags__Vcvt, eax__Vcvt, ecx__Vcvt, edx__Vcvt, ebx__Vcvt, esp__Vcvt, ebp__Vcvt, esi__Vcvt, edi__Vcvt, cs__Vcvt, ss__Vcvt, ds__Vcvt, es__Vcvt, fs__Vcvt, gs__Vcvt);
}

void Vventium_top___024root___eval_triggers_vec__ico(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_triggers_vec__ico\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.__VicoTriggered[0U] = ((0xfffffffffffffffeULL 
                                      & vlSelfRef.__VicoTriggered[0U]) 
                                     | (IData)((IData)(vlSelfRef.__VicoFirstIteration)));
}

bool Vventium_top___024root___trigger_anySet__ico(const VlUnpacked<QData/*63:0*/, 1> &in) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___trigger_anySet__ico\n"); );
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

void Vventium_top___024root___ico_sequent__TOP__0(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___ico_sequent__TOP__0\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.mem_req = ((~ (IData)(vlSelfRef.ventium_top__DOT__done)) 
                         & (IData)(vlSelfRef.rst_n));
}

void Vventium_top___024root___eval_ico(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_ico\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1ULL & vlSelfRef.__VicoTriggered[0U])) {
        vlSelfRef.mem_req = ((~ (IData)(vlSelfRef.ventium_top__DOT__done)) 
                             & (IData)(vlSelfRef.rst_n));
    }
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vventium_top___024root___dump_triggers__ico(const VlUnpacked<QData/*63:0*/, 1> &triggers, const std::string &tag);
#endif  // VL_DEBUG

bool Vventium_top___024root___eval_phase__ico(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_phase__ico\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    CData/*0:0*/ __VicoExecute;
    // Body
    Vventium_top___024root___eval_triggers_vec__ico(vlSelf);
#ifdef VL_DEBUG
    if (VL_UNLIKELY(vlSymsp->_vm_contextp__->debug())) {
        Vventium_top___024root___dump_triggers__ico(vlSelfRef.__VicoTriggered, "ico"s);
    }
#endif
    __VicoExecute = Vventium_top___024root___trigger_anySet__ico(vlSelfRef.__VicoTriggered);
    if (__VicoExecute) {
        Vventium_top___024root___eval_ico(vlSelf);
    }
    return (__VicoExecute);
}

void Vventium_top___024root___eval_triggers_vec__act(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_triggers_vec__act\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.__VactTriggered[0U] = (QData)((IData)(
                                                    ((IData)(vlSelfRef.clk) 
                                                     & (~ (IData)(vlSelfRef.__Vtrigprevexpr___TOP__clk__0)))));
    vlSelfRef.__Vtrigprevexpr___TOP__clk__0 = vlSelfRef.clk;
}

bool Vventium_top___024root___trigger_anySet__act(const VlUnpacked<QData/*63:0*/, 1> &in) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___trigger_anySet__act\n"); );
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

void Vventium_top___024root___nba_sequent__TOP__0(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___nba_sequent__TOP__0\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    QData/*63:0*/ __Vdly__ventium_top__DOT__seq;
    __Vdly__ventium_top__DOT__seq = 0;
    // Body
    __Vdly__ventium_top__DOT__seq = vlSelfRef.ventium_top__DOT__seq;
    if (vlSelfRef.rst_n) {
        if ((1U & (~ (IData)(vlSelfRef.ventium_top__DOT__done)))) {
            if (((IData)(vlSelfRef.mem_req) & (IData)(vlSelfRef.mem_ack))) {
                Vventium_top___024root____Vdpiimwrap_ventium_top__DOT__vtm_retire_TOP(
                                                                                (vlSymsp->__Vscopep_ventium_top), 
                                                                                "/home/yukidama/github/ventium/verif/tb/selftest/ventium_top.sv", 0x00000052U, vlSelfRef.ventium_top__DOT__seq, 
                                                                                ((IData)(0x08048000U) 
                                                                                + (IData)(vlSelfRef.ventium_top__DOT__seq)), 2U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U);
                __Vdly__ventium_top__DOT__seq = (1ULL 
                                                 + vlSelfRef.ventium_top__DOT__seq);
                if ((7ULL == vlSelfRef.ventium_top__DOT__seq)) {
                    vlSelfRef.ventium_top__DOT__done = 1U;
                }
            }
        }
    } else {
        __Vdly__ventium_top__DOT__seq = 0ULL;
        vlSelfRef.ventium_top__DOT__done = 0U;
    }
    vlSelfRef.ventium_top__DOT__seq = __Vdly__ventium_top__DOT__seq;
    vlSelfRef.mem_addr = ((IData)(0x08048000U) + (IData)(vlSelfRef.ventium_top__DOT__seq));
    vlSelfRef.mem_req = ((~ (IData)(vlSelfRef.ventium_top__DOT__done)) 
                         & (IData)(vlSelfRef.rst_n));
}

void Vventium_top___024root___eval_nba(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_nba\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if ((1ULL & vlSelfRef.__VnbaTriggered[0U])) {
        Vventium_top___024root___nba_sequent__TOP__0(vlSelf);
    }
}

void Vventium_top___024root___trigger_orInto__act_vec_vec(VlUnpacked<QData/*63:0*/, 1> &out, const VlUnpacked<QData/*63:0*/, 1> &in) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___trigger_orInto__act_vec_vec\n"); );
    // Locals
    IData/*31:0*/ n;
    // Body
    n = 0U;
    do {
        out[n] = (out[n] | in[n]);
        n = ((IData)(1U) + n);
    } while ((0U >= n));
}

#ifdef VL_DEBUG
VL_ATTR_COLD void Vventium_top___024root___dump_triggers__act(const VlUnpacked<QData/*63:0*/, 1> &triggers, const std::string &tag);
#endif  // VL_DEBUG

bool Vventium_top___024root___eval_phase__act(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_phase__act\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    Vventium_top___024root___eval_triggers_vec__act(vlSelf);
#ifdef VL_DEBUG
    if (VL_UNLIKELY(vlSymsp->_vm_contextp__->debug())) {
        Vventium_top___024root___dump_triggers__act(vlSelfRef.__VactTriggered, "act"s);
    }
#endif
    Vventium_top___024root___trigger_orInto__act_vec_vec(vlSelfRef.__VnbaTriggered, vlSelfRef.__VactTriggered);
    return (0U);
}

void Vventium_top___024root___trigger_clear__act(VlUnpacked<QData/*63:0*/, 1> &out) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___trigger_clear__act\n"); );
    // Locals
    IData/*31:0*/ n;
    // Body
    n = 0U;
    do {
        out[n] = 0ULL;
        n = ((IData)(1U) + n);
    } while ((1U > n));
}

bool Vventium_top___024root___eval_phase__nba(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_phase__nba\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    CData/*0:0*/ __VnbaExecute;
    // Body
    __VnbaExecute = Vventium_top___024root___trigger_anySet__act(vlSelfRef.__VnbaTriggered);
    if (__VnbaExecute) {
        Vventium_top___024root___eval_nba(vlSelf);
        Vventium_top___024root___trigger_clear__act(vlSelfRef.__VnbaTriggered);
    }
    return (__VnbaExecute);
}

void Vventium_top___024root___eval(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Locals
    IData/*31:0*/ __VicoIterCount;
    IData/*31:0*/ __VnbaIterCount;
    // Body
    __VicoIterCount = 0U;
    vlSelfRef.__VicoFirstIteration = 1U;
    do {
        if (VL_UNLIKELY(((0x00002710U < __VicoIterCount)))) {
#ifdef VL_DEBUG
            Vventium_top___024root___dump_triggers__ico(vlSelfRef.__VicoTriggered, "ico"s);
#endif
            VL_FATAL_MT("/home/yukidama/github/ventium/verif/tb/selftest/ventium_top.sv", 20, "", "DIDNOTCONVERGE: Input combinational region did not converge after '--converge-limit' of 10000 tries");
        }
        __VicoIterCount = ((IData)(1U) + __VicoIterCount);
        vlSelfRef.__VicoPhaseResult = Vventium_top___024root___eval_phase__ico(vlSelf);
        vlSelfRef.__VicoFirstIteration = 0U;
    } while (vlSelfRef.__VicoPhaseResult);
    __VnbaIterCount = 0U;
    do {
        if (VL_UNLIKELY(((0x00002710U < __VnbaIterCount)))) {
#ifdef VL_DEBUG
            Vventium_top___024root___dump_triggers__act(vlSelfRef.__VnbaTriggered, "nba"s);
#endif
            VL_FATAL_MT("/home/yukidama/github/ventium/verif/tb/selftest/ventium_top.sv", 20, "", "DIDNOTCONVERGE: NBA region did not converge after '--converge-limit' of 10000 tries");
        }
        __VnbaIterCount = ((IData)(1U) + __VnbaIterCount);
        vlSelfRef.__VactIterCount = 0U;
        do {
            if (VL_UNLIKELY(((0x00002710U < vlSelfRef.__VactIterCount)))) {
#ifdef VL_DEBUG
                Vventium_top___024root___dump_triggers__act(vlSelfRef.__VactTriggered, "act"s);
#endif
                VL_FATAL_MT("/home/yukidama/github/ventium/verif/tb/selftest/ventium_top.sv", 20, "", "DIDNOTCONVERGE: Active region did not converge after '--converge-limit' of 10000 tries");
            }
            vlSelfRef.__VactIterCount = ((IData)(1U) 
                                         + vlSelfRef.__VactIterCount);
            vlSelfRef.__VactPhaseResult = Vventium_top___024root___eval_phase__act(vlSelf);
        } while (vlSelfRef.__VactPhaseResult);
        vlSelfRef.__VnbaPhaseResult = Vventium_top___024root___eval_phase__nba(vlSelf);
    } while (vlSelfRef.__VnbaPhaseResult);
}

#ifdef VL_DEBUG
void Vventium_top___024root___eval_debug_assertions(Vventium_top___024root* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+    Vventium_top___024root___eval_debug_assertions\n"); );
    Vventium_top__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    if (VL_UNLIKELY(((vlSelfRef.clk & 0xfeU)))) {
        Verilated::overWidthError("clk");
    }
    if (VL_UNLIKELY(((vlSelfRef.rst_n & 0xfeU)))) {
        Verilated::overWidthError("rst_n");
    }
    if (VL_UNLIKELY(((vlSelfRef.mem_ack & 0xfeU)))) {
        Verilated::overWidthError("mem_ack");
    }
}
#endif  // VL_DEBUG
