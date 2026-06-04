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

// ---- packages (must precede every module that imports them) ----------------
ventium_pkg.sv
core/ventium_alu_pkg.sv
core/ventium_decode_pkg.sv
fpu/fpu_x87_pkg.sv

// ---- top ------------------------------------------------------------------
ventium_top.sv

// ---- core -----------------------------------------------------------------
core/core.sv
core/bpred_btb.sv
core/decode.sv
core/exec_int.sv
core/fetch.sv
core/issue_uv.sv
core/regfile.sv

// ---- fpu ------------------------------------------------------------------
fpu/fpu_top.sv

// ---- mem ------------------------------------------------------------------
mem/dcache.sv
mem/icache.sv
mem/tlb.sv

// ---- sys ------------------------------------------------------------------
sys/sys_state.sv

// ---- ucode ----------------------------------------------------------------
ucode/ucode_rom.sv

// ---- bus ------------------------------------------------------------------
bus/biu.sv
