// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Symbol table implementation internals

#include "Vventium_top__pch.h"

Vventium_top__Syms::Vventium_top__Syms(VerilatedContext* contextp, const char* namep, Vventium_top* modelp)
    : VerilatedSyms{contextp}
    // Setup internal state of the Syms class
    , __Vm_modelp{modelp}
    // Setup top module instance
    , TOP{this, namep}
{
    // Check resources
    Verilated::stackCheck(518);
    // Setup sub module instances
    // Configure time unit / time precision
    _vm_contextp__->timeunit(-12);
    _vm_contextp__->timeprecision(-12);
    // Setup each module's pointers to their submodules
    // Setup each module's pointer back to symbol table (for public functions)
    TOP.__Vconfigure(true);
    // Setup scopes
    __Vscopep_ventium_top = new VerilatedScope{this, "ventium_top", "ventium_top", "<null>", -12, VerilatedScope::SCOPE_OTHER};
    // Setup export functions - final: 0
    // Setup export functions - final: 1
}

Vventium_top__Syms::~Vventium_top__Syms() {
    // Tear down scopes
    VL_DO_CLEAR(delete __Vscopep_ventium_top, __Vscopep_ventium_top = nullptr);
    // Tear down sub module instances
}
