// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vventium_top.h for the primary calling header

#include "Vventium_top__pch.h"

void Vventium_top___024root___ctor_var_reset(Vventium_top___024root* vlSelf);

Vventium_top___024root::Vventium_top___024root(Vventium_top__Syms* symsp, const char* namep)
 {
    vlSymsp = symsp;
    vlNamep = strdup(namep);
    // Reset structure values
    Vventium_top___024root___ctor_var_reset(this);
}

void Vventium_top___024root::__Vconfigure(bool first) {
    (void)first;  // Prevent unused variable warning
}

Vventium_top___024root::~Vventium_top___024root() {
    VL_DO_DANGLING(std::free(const_cast<char*>(vlNamep)), vlNamep);
}
