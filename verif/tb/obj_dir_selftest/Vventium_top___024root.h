// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vventium_top.h for the primary calling header

#ifndef VERILATED_VVENTIUM_TOP___024ROOT_H_
#define VERILATED_VVENTIUM_TOP___024ROOT_H_  // guard

#include "verilated.h"


class Vventium_top__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vventium_top___024root final {
  public:

    // DESIGN SPECIFIC STATE
    VL_IN8(clk,0,0);
    VL_IN8(rst_n,0,0);
    VL_OUT8(mem_req,0,0);
    VL_OUT8(mem_we,0,0);
    VL_OUT8(mem_wstrb,3,0);
    VL_IN8(mem_ack,0,0);
    CData/*0:0*/ ventium_top__DOT__done;
    CData/*0:0*/ __VstlFirstIteration;
    CData/*0:0*/ __VstlPhaseResult;
    CData/*0:0*/ __VicoFirstIteration;
    CData/*0:0*/ __VicoPhaseResult;
    CData/*0:0*/ __Vtrigprevexpr___TOP__clk__0;
    CData/*0:0*/ __VactPhaseResult;
    CData/*0:0*/ __VnbaPhaseResult;
    VL_OUT(mem_addr,31,0);
    VL_OUT(mem_wdata,31,0);
    VL_IN(mem_rdata,31,0);
    IData/*31:0*/ __VactIterCount;
    QData/*63:0*/ ventium_top__DOT__seq;
    VlUnpacked<QData/*63:0*/, 1> __VstlTriggered;
    VlUnpacked<QData/*63:0*/, 1> __VicoTriggered;
    VlUnpacked<QData/*63:0*/, 1> __VactTriggered;
    VlUnpacked<QData/*63:0*/, 1> __VnbaTriggered;

    // INTERNAL VARIABLES
    Vventium_top__Syms* vlSymsp;
    const char* vlNamep;

    // CONSTRUCTORS
    Vventium_top___024root(Vventium_top__Syms* symsp, const char* namep);
    ~Vventium_top___024root();
    VL_UNCOPYABLE(Vventium_top___024root);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};


#endif  // guard
