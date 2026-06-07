// rtl/ventium_soc.f — Verilator filelist for the M8.1 SoC-integration top.
//
// Deterministic compile order (packages first, then the modules that import
// their types — IEEE 1800). This is the ventium.f core set with the SoC top +
// the M8 PC peripheral devices (8259 PIC + 8254 PIT) ADDED, and ventium_top
// REPLACED by ventium_soc as the integration top (--top-module ventium_soc).
// ventium_top is intentionally OMITTED so this build has a single coherent top;
// the existing make-verify / sys-gate build (verif/tb/Makefile) is unchanged.
// Paths are relative to this file's directory ($VENTIUM_ROOT/rtl).

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

// ---- SoC integration top ---------------------------------------------------
soc/ventium_soc.sv

// ---- core ------------------------------------------------------------------
core/core.sv
core/bpred_btb.sv
core/decode.sv
core/issue_uv.sv
core/ven_idiv.sv

// ---- fpu -------------------------------------------------------------------
fpu/fpu_top.sv
// iterative SRT FDIV + FSQRT engines (instantiated by core.sv under
// +define+VEN_SRT_ITER; harmless when not).
fpu/fpu_srt_div.sv
fpu/fpu_sqrt_iter.sv
fpu/ven_bcd.sv

// ---- mem -------------------------------------------------------------------
mem/dcache_timing.sv
mem/icache.sv
mem/tlb.sv

// ---- M8 SoC PC-peripheral devices ------------------------------------------
// M8.1 on-die interrupt subsystem:
soc/ven_pic.sv
soc/ven_pit.sv
// M8.2 RTC + keyboard controller + fast-A20 (wired into ventium_soc):
soc/ven_rtc.sv
soc/ven_i8042.sv
soc/ven_port92.sv
// M8.3 VGA register file + ACPI PM timer (wired into ventium_soc):
soc/ven_vgaregs.sv
soc/ven_acpipm.sv
// M8.4 IDE/ATA controller (primary master, PIO):
soc/ven_ide.sv
