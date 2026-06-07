// rtl/ventium.f — explicit Verilator filelist for the Ventium core.
//
// Deterministic compile order (R1 modularization, docs/rtl-refactor-plan.md):
// PACKAGES FIRST (types/enums/pure functions other files import), THEN the
// modules that import them. This replaces the testbench's glob
// $(wildcard rtl/*.sv rtl/**/*.sv), whose alphabetical ordering put packages
// AFTER the modules that use their types (IEEE 1800 "reference before
// declaration"). Paths are relative to this file's directory ($VENTIUM_ROOT/rtl).
//
// One module per file; file name == module name. Packages are *_pkg.sv.

// ---- include dir for core_*.svh (RAW case-arm text `included by core.sv) ----
// core.sv's giant always_ff `unique case (state)` is split across core_*.svh
// files (R2 modularization); they are textually pasted at the original site, so
// the netlist is identical. +incdir lets `include "core_*.svh" resolve.
+incdir+core

// ---- packages (must precede every module that imports them) ----------------
ventium_pkg.sv
core/ventium_alu_pkg.sv
core/ventium_decode_pkg.sv
fpu/fpu_x87_pkg.sv
core/ventium_sys_pkg.sv
core/ventium_x87_pkg.sv

// ---- top ------------------------------------------------------------------
ventium_top.sv

// ---- core -----------------------------------------------------------------
core/core.sv
core/bpred_btb.sv
core/decode.sv
core/issue_uv.sv
// iterative integer DIV/IDIV engine (the FPGA-synthesizable form of the native
// '/'/'%'). Instantiated by core.sv only under +define+VEN_IDIV_ITER; harmless
// (uninstantiated) in the default build.
core/ven_idiv.sv

// ---- fpu ------------------------------------------------------------------
fpu/fpu_top.sv
// iterative radix-4 SRT FDIV + iterative FSQRT engines (the FPGA-synthesizable
// one-step-per-clock form of fx_srt_div/fx_sqrt). Instantiated by core.sv only
// under +define+VEN_SRT_ITER; harmless (uninstantiated) in the default build.
fpu/fpu_srt_div.sv
fpu/fpu_sqrt_iter.sv
// iterative FP->packed-BCD (FBSTP) engine — instantiated under +VEN_BCD_ITER.
fpu/ven_bcd.sv

// ---- mem ------------------------------------------------------------------
mem/dcache_timing.sv
mem/icache.sv
mem/tlb.sv

// ---- bus ------------------------------------------------------------------
// M5B-int: biu_p5 (the standalone pin-level 64-bit P5 bus FSM, M5B) is now in
// its canonical RTL home and in the build. `biu` is the gated bus SUBSYSTEM
// (front 32b adapter + biu_p5 instance + loopback pin-level responder),
// instantiated by ventium_top under bus_mode (default 0 = inert/bypassed).
// biu_p5 is self-contained (its own localparams, no ventium_pkg import).
bus/biu_p5.sv
bus/biu.sv
