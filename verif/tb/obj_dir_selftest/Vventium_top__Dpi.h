// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Prototypes for DPI import and export functions.
//
// Verilator includes this file in all generated .cpp files that use DPI functions.
// Manually include this file where DPI .c import functions are declared to ensure
// the C functions match the expectations of the DPI imports.

#ifndef VERILATED_VVENTIUM_TOP__DPI_H_
#define VERILATED_VVENTIUM_TOP__DPI_H_  // guard

#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif


    // DPI IMPORTS
    // DPI import at /home/yukidama/github/ventium/verif/tb/selftest/ventium_top.sv:42:42
    extern void vtm_retire(unsigned long long n, unsigned int pc, unsigned int eflags, unsigned int eax, unsigned int ecx, unsigned int edx, unsigned int ebx, unsigned int esp, unsigned int ebp, unsigned int esi, unsigned int edi, unsigned short cs, unsigned short ss, unsigned short ds, unsigned short es, unsigned short fs, unsigned short gs);

#ifdef __cplusplus
}
#endif

#endif  // guard
