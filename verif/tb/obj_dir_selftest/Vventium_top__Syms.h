// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Symbol table internal header
//
// Internal details; most calling programs do not need this header,
// unless using verilator public meta comments.

#ifndef VERILATED_VVENTIUM_TOP__SYMS_H_
#define VERILATED_VVENTIUM_TOP__SYMS_H_  // guard

#include "verilated.h"

// INCLUDE MODEL CLASS

#include "Vventium_top.h"

// INCLUDE MODULE CLASSES
#include "Vventium_top___024root.h"

// DPI TYPES for DPI Export callbacks (Internal use)

// SYMS CLASS (contains all model state)
class alignas(VL_CACHE_LINE_BYTES) Vventium_top__Syms final : public VerilatedSyms {
  public:
    // INTERNAL STATE
    Vventium_top* const __Vm_modelp;
    VlDeleter __Vm_deleter;
    bool __Vm_didInit = false;

    // MODULE INSTANCE STATE
    Vventium_top___024root         TOP;

    // SCOPE NAMES
    VerilatedScope* __Vscopep_ventium_top;

    // CONSTRUCTORS
    Vventium_top__Syms(VerilatedContext* contextp, const char* namep, Vventium_top* modelp);
    ~Vventium_top__Syms();

    // METHODS
    const char* name() const { return TOP.vlNamep; }
};

#endif  // guard
