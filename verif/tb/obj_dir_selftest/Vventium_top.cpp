// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Model implementation (design independent parts)

#include "Vventium_top__pch.h"

//============================================================
// Constructors

Vventium_top::Vventium_top(VerilatedContext* _vcontextp__, const char* _vcname__)
    : VerilatedModel{*_vcontextp__}
    , vlSymsp{new Vventium_top__Syms(contextp(), _vcname__, this)}
    , clk{vlSymsp->TOP.clk}
    , rst_n{vlSymsp->TOP.rst_n}
    , mem_req{vlSymsp->TOP.mem_req}
    , mem_we{vlSymsp->TOP.mem_we}
    , mem_wstrb{vlSymsp->TOP.mem_wstrb}
    , mem_ack{vlSymsp->TOP.mem_ack}
    , mem_addr{vlSymsp->TOP.mem_addr}
    , mem_wdata{vlSymsp->TOP.mem_wdata}
    , mem_rdata{vlSymsp->TOP.mem_rdata}
    , rootp{&(vlSymsp->TOP)}
{
    // Register model with the context
    contextp()->addModel(this);
}

Vventium_top::Vventium_top(const char* _vcname__)
    : Vventium_top(Verilated::threadContextp(), _vcname__)
{
}

//============================================================
// Destructor

Vventium_top::~Vventium_top() {
    delete vlSymsp;
}

//============================================================
// Evaluation function

#ifdef VL_DEBUG
void Vventium_top___024root___eval_debug_assertions(Vventium_top___024root* vlSelf);
#endif  // VL_DEBUG
void Vventium_top___024root___eval_static(Vventium_top___024root* vlSelf);
void Vventium_top___024root___eval_initial(Vventium_top___024root* vlSelf);
void Vventium_top___024root___eval_settle(Vventium_top___024root* vlSelf);
void Vventium_top___024root___eval(Vventium_top___024root* vlSelf);

void Vventium_top::eval_step() {
    VL_DEBUG_IF(VL_DBG_MSGF("+++++TOP Evaluate Vventium_top::eval_step\n"); );
#ifdef VL_DEBUG
    // Debug assertions
    Vventium_top___024root___eval_debug_assertions(&(vlSymsp->TOP));
#endif  // VL_DEBUG
    vlSymsp->__Vm_deleter.deleteAll();
    if (VL_UNLIKELY(!vlSymsp->__Vm_didInit)) {
        VL_DEBUG_IF(VL_DBG_MSGF("+ Initial\n"););
        Vventium_top___024root___eval_static(&(vlSymsp->TOP));
        Vventium_top___024root___eval_initial(&(vlSymsp->TOP));
        Vventium_top___024root___eval_settle(&(vlSymsp->TOP));
        vlSymsp->__Vm_didInit = true;
    }
    VL_DEBUG_IF(VL_DBG_MSGF("+ Eval\n"););
    Vventium_top___024root___eval(&(vlSymsp->TOP));
    // Evaluate cleanup
    Verilated::endOfEval(vlSymsp->__Vm_evalMsgQp);
}

//============================================================
// Events and timing
bool Vventium_top::eventsPending() { return false; }

uint64_t Vventium_top::nextTimeSlot() {
    VL_FATAL_MT(__FILE__, __LINE__, "", "No delays in the design");
    return 0;
}

//============================================================
// Utilities

const char* Vventium_top::name() const {
    return vlSymsp->name();
}

//============================================================
// Invoke final blocks

void Vventium_top___024root___eval_final(Vventium_top___024root* vlSelf);

VL_ATTR_COLD void Vventium_top::final() {
    contextp()->executingFinal(true);
    Vventium_top___024root___eval_final(&(vlSymsp->TOP));
    contextp()->executingFinal(false);
}

//============================================================
// Implementations of abstract methods from VerilatedModel

const char* Vventium_top::hierName() const { return vlSymsp->name(); }
const char* Vventium_top::modelName() const { return "Vventium_top"; }
unsigned Vventium_top::threads() const { return 1; }
void Vventium_top::prepareClone() const { contextp()->prepareClone(); }
void Vventium_top::atClone() const {
    contextp()->threadPoolpOnClone();
}
