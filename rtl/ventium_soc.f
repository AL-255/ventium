// rtl/ventium_soc.f — Verilator filelist for the M8.1 SoC-integration top.
//
// Deterministic compile order (packages first, then the modules that import
// their types — IEEE 1800). This is the ventium.f core set with the SoC top +
// the M8 PC peripheral devices (8259 PIC + 8254 PIT) ADDED, and ventium_top
// REPLACED by ventium_soc as the integration top (--top-module ventium_soc).
// ventium_top is intentionally OMITTED so this build has a single coherent top;
// the existing make-verify / sys-gate build (verif/tb/Makefile) is unchanged.
// Paths are relative to this file's directory ($VENTIUM_ROOT/rtl).

// ---- packages (must precede every module that imports them) ----------------
ventium_pkg.sv
core/ventium_alu_pkg.sv
core/ventium_decode_pkg.sv
fpu/fpu_x87_pkg.sv

// ---- SoC integration top ---------------------------------------------------
soc/ventium_soc.sv

// ---- core ------------------------------------------------------------------
core/core.sv
core/bpred_btb.sv
core/decode.sv
core/issue_uv.sv

// ---- fpu -------------------------------------------------------------------
fpu/fpu_top.sv

// ---- mem -------------------------------------------------------------------
mem/dcache_timing.sv
mem/icache.sv
mem/tlb.sv

// ---- M8 SoC PC-peripheral devices (the on-die interrupt subsystem) ---------
soc/ven_pic.sv
soc/ven_pit.sv
