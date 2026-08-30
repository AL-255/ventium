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
// +incdir for fpu_f2xm1_rom.svh (the F2XM1 constant ROM `included by fpu_f2xm1.sv).
+incdir+fpu

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
// architectural GPR file extracted VERBATIM from core.sv (R3): registered storage
// + synchronous dual-boot-mode reset + per-register write bus. Driven by core.sv's
// gpr writeback driver (core_gpr_wb.svh).
core/regfile.sv
core/bpred_btb.sv
core/decode.sv
core/issue_uv.sv
// shared U/V integer-execution building blocks (BCD/ASCII-adjust datapath, ...)
// extracted from core.sv (R3). One module per file; behaviour-preserving.
core/uv_common.sv
// P5 dual-issue integer execution datapaths (R3): U-pipe = full ALU member,
// V-pipe = restricted ALU/branch member. Combinational; netlist-identical.
core/u_pipe.sv
core/v_pipe.sv
// SLOW-PATH instruction decoder extracted VERBATIM from core.sv (R3).
core/decode_stages.sv
// x87 FP WRITE-DRIVER (the combinational fpu_top state-mutation driver) extracted
// VERBATIM from core.sv (R3). MUST come after core/core.sv (uses the $unit-scope
// state_e enum promoted at the top of core.sv).
core/fpu_writeback.sv
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
// iterative FP->packed-BCD (FBSTP) engine — instantiated under +VEN_BCD_ITER.
fpu/ven_bcd.sv
fpu/ven_bcd_to_fp.sv
// Area-shared x87 hierarchy.  The guarded VEN_FP_SHARED production profile
// makes ven_fp_top the sole architectural owner; the legacy implementation is
// retained only for non-shared regression configurations.
../fp_shared/ven_fp_state.sv
../fp_shared/ven_fp_alu.sv
../fp_shared/ven_fp_misc.sv
../fp_shared/ven_fp_widemul.sv
../fp_shared/ven_fp_estdiv.sv
../fp_shared/ven_fp_trans.sv
../fp_shared/ven_fp_top.sv
// iterative x87 transcendental engine (F2XM1, #11) — instantiated by core.sv only
// under +define+VEN_TRANSCENDENTAL; harmless (uninstantiated) in the default build.
fpu/fpu_f2xm1.sv
fpu/fpu_fpatan.sv
fpu/fpu_fprem.sv
fpu/fpu_fyl2x.sv
fpu/fpu_fsincos.sv

// ---- mem ------------------------------------------------------------------
mem/dcache_timing.sv
mem/icache.sv
// predecoded micro-op cache (predecode-on-fill, P0-11). Instantiated by core.sv
// only under +define+VEN_UOPCACHE; harmless (uninstantiated) in the default build.
mem/uopcache.sv
mem/tlb.sv

// ---- bus ------------------------------------------------------------------
// M5B-int: biu_p5 (the standalone pin-level 64-bit P5 bus FSM, M5B) is now in
// its canonical RTL home and in the build. `biu` is the gated bus SUBSYSTEM
// (front 32b adapter + biu_p5 instance + loopback pin-level responder),
// instantiated by ventium_top under bus_mode (default 0 = inert/bypassed).
// biu_p5 is self-contained (its own localparams, no ventium_pkg import).
bus/biu_p5.sv
bus/biu.sv
