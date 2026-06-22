#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# verif/gls/run_gls_freedos.sh — xsim gate-level FreeDOS boot harness.
#
# Two modes (env GLS_MODE):
#   GLS_MODE=rtl   (default) : compile the SV testbench against the RTL ventium_top
#                              (rtl/ventium.f + the L1AXI leaves) with the deployed
#                              KV260 defines. Debugs the harness against known-good
#                              RTL — confirms SeaBIOS POST + IDE reads.
#   GLS_MODE=net             : compile against the synthesized funcsim netlist
#                              (fpga/build/ventop_funcsim/ventium_top_funcsim.v) +
#                              the Xilinx sim libs (unisims_ver / secureip) + glbl.
#
# Other env:
#   GLS_DISK=<img>        FreeDOS disk image for ven_ide  (default verif/freedos/f4a/fdhi.img)
#   GLS_BIOS=<bin>        SeaBIOS rom                      (default sw/ps/kv260/assets/seabios.bin)
#   GLS_MAX_CYCLES=<n>    sim cycle cap                    (default 20000000)
#   GLS_REPORT=<n>        progress report period (cycles)  (default 200000)
#   GLS_SKIP_COMPILE=1    reuse the existing xsim.dir/xsc lib (re-run only)
#   VIVADO_SETTINGS=<sh>  Vivado settings64.sh             (default /tools/Xilinx/2025.2/Vivado/settings64.sh)
#
# Output: verif/gls/gls_<mode>.log

set -o pipefail
# NOTE: no `set -u` — Vivado's settings64.sh dereferences unset vars (PYTHONPATH).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GLS="$ROOT/verif/gls"
TB="$ROOT/verif/tb"
RTL="$ROOT/rtl"
PERIPH="$ROOT/sw/ps_periph"

GLS_MODE="${GLS_MODE:-rtl}"
GLS_DISK="${GLS_DISK:-$ROOT/verif/freedos/f4a/fdhi.img}"
GLS_BIOS="${GLS_BIOS:-$ROOT/sw/ps/kv260/assets/seabios.bin}"
GLS_MAX_CYCLES="${GLS_MAX_CYCLES:-20000000}"
GLS_REPORT="${GLS_REPORT:-200000}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/2025.2/Vivado/settings64.sh}"

# GLS_DBG=1 (net mode only): use the +VEN_DBG_CORE funcsim netlist
# (synth_ventop_funcsim_dbg.tcl) and define VEN_DBG_CORE so the tb wires + dumps
# ventium_top's dbg_* observability taps (committed PC ring, wedge/fault auto-
# detector). Default 0 = the non-DBG netlist (no dbg_* ports).
GLS_DBG="${GLS_DBG:-0}"
if [ "$GLS_MODE" = "net" ] && [ "$GLS_DBG" = "1" ]; then
  NETLIST="${GLS_NETLIST:-$ROOT/fpga/build/ventop_funcsim_dbg/ventium_top_funcsim_dbg.v}"
else
  NETLIST="${GLS_NETLIST:-$ROOT/fpga/build/ventop_funcsim/ventium_top_funcsim.v}"
fi

TAG="$GLS_MODE"
if [ "$GLS_DBG" = "1" ]; then TAG="${GLS_MODE}_dbg"; fi
LOG="$GLS/gls_${TAG}.log"
WORK="$GLS/work_${TAG}"

# All work happens inside a per-mode work dir so xsim.dir/.jou/.pb stay isolated.
mkdir -p "$WORK"
cd "$WORK" || exit 2

# ---- Vivado/xsim environment ----
if [ -f "$VIVADO_SETTINGS" ]; then
  # shellcheck disable=SC1090
  source "$VIVADO_SETTINGS"
else
  echo "ERROR: Vivado settings not found: $VIVADO_SETTINGS" | tee "$LOG"
  exit 2
fi

echo "=== GLS FreeDOS harness (mode=$GLS_MODE) ===" | tee "$LOG"
echo "disk=$GLS_DISK bios=$GLS_BIOS max_cycles=$GLS_MAX_CYCLES" | tee -a "$LOG"

# Deployed KV260 L1AXI define set (matches synth_ventop_funcsim.tcl / the Makefile
# l1axi_kv_full set) + VTM_NO_DPI (no retire DPI).
#
# IMPORTANT: the funcsim netlist (synth_ventop_funcsim.tcl) was synthesized WITHOUT
# VEN_DBG_CORE, so the netlist ventium_top has NO dbg_* ports. The tb's dbg port
# connections are under `ifdef VEN_DBG_CORE, so net mode must NOT define it. RTL
# mode CAN (the RTL ventium_top has the ports) — but the tb leaves them
# unconnected either way, so we simply never define VEN_DBG_CORE here to keep the
# tb's port list matching the netlist exactly.
DEFINES=(
  VTM_NO_DPI VEN_L1_AXI VEN_KV260_SOC VEN_IC_BRAM VEN_UOPCACHE VEN_CACHE_HALF
  VEN_FE_PIPE VEN_BTB_PIPE VEN_FP_PIPE VEN_FP_PIPE2 VEN_FP_PC_RELAX VEN_FPREM
  VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER
)
# GLS_DBG=1: the dbg netlist HAS the dbg_* ports, so the tb must connect them
# (its `ifdef VEN_DBG_CORE port arms + the ring/wedge/fault detector). The
# port list MUST match the netlist's, so only define this with the dbg netlist.
if [ "$GLS_DBG" = "1" ]; then DEFINES+=(VEN_DBG_CORE); fi
DFLAGS=()
for d in "${DEFINES[@]}"; do DFLAGS+=(-d "$d"); done

# ---- 1. DPI-C shared object (xsc): gls_dpi.cpp + memmodel.cpp + ps_periph/*.c ----
# Mirror the verif/tb/Makefile compile: -DVEN_DOS_MODELS + ps_periph include dir.
if [ "${GLS_SKIP_COMPILE:-0}" != "1" ]; then
  echo "--- xsc: building DPI shared lib ---" | tee -a "$LOG"
  XSC_SRCS=(
    "$GLS/gls_dpi.cpp"
    "$TB/memmodel.cpp"
  )
  # ps_periph C models (compiled as C by xsc via the .c extension).
  for c in "$PERIPH"/*.c; do XSC_SRCS+=("$c"); done

  # A single xsc invocation (NO --shared) compiles each source (gcc for .c -> C
  # linkage, g++ for .cpp -> C++) AND links the .so. .c models keep C linkage so
  # the extern "C" decls in gls_dpi.cpp resolve. Output: xsim.dir/work/xsc/dpi.so.
  xsc "${XSC_SRCS[@]}" \
    --gcc_compile_options "-I$TB -I$PERIPH -DVEN_DOS_MODELS -std=c++17" \
    -o dpi.so >>"$LOG" 2>&1
  rc=$?
  # xsc writes the .so to ./dpi.so (cwd) when -o is a bare name; mirror a copy
  # into xsim.dir/work/xsc/ so xelab -sv_lib dpi finds it on the default path.
  if [ -f dpi.so ]; then mkdir -p xsim.dir/work/xsc && cp -f dpi.so xsim.dir/work/xsc/dpi.so; fi
  if [ $rc -ne 0 ] || [ ! -f xsim.dir/work/xsc/dpi.so ]; then
    echo "ERROR: xsc DPI compile failed (rc=$rc); see $LOG" | tee -a "$LOG"
    tail -40 "$LOG"
    exit 2
  fi
fi

# ---- 2. xvlog: compile the SV sources ----
if [ "${GLS_SKIP_COMPILE:-0}" != "1" ]; then
  echo "--- xvlog: compiling SV ---" | tee -a "$LOG"
  if [ "$GLS_MODE" = "net" ]; then
    if [ ! -f "$NETLIST" ]; then
      echo "ERROR: netlist not found: $NETLIST" | tee -a "$LOG"; exit 2
    fi
    # Netlist mode: the funcsim .v (already flattened, no packages) + the tb.
    # No core defines needed for the netlist itself; the tb still needs VEN_*
    # for its `ifdef port-list arms.
    xvlog --relax -sv "${DFLAGS[@]}" \
      "$NETLIST" \
      "$GLS/tb_gls_soc.sv" >>"$LOG" 2>&1
  else
    # RTL mode: the same svfiles list as synth_ventop_funcsim.tcl, in ventium.f
    # order, + the L1AXI leaves (appended like the Makefile), + the tb.
    SV=(
      "$RTL/ventium_pkg.sv"
      "$RTL/core/ventium_alu_pkg.sv" "$RTL/core/ventium_decode_pkg.sv"
      "$RTL/fpu/fpu_x87_pkg.sv" "$RTL/core/ventium_sys_pkg.sv" "$RTL/core/ventium_x87_pkg.sv"
      "$RTL/ventium_top.sv"
      "$RTL/core/core.sv" "$RTL/core/bpred_btb.sv" "$RTL/core/decode.sv" "$RTL/core/issue_uv.sv"
      "$RTL/core/ven_idiv.sv" "$RTL/core/regfile.sv" "$RTL/core/decode_stages.sv"
      "$RTL/core/uv_common.sv" "$RTL/core/u_pipe.sv" "$RTL/core/v_pipe.sv" "$RTL/core/fpu_writeback.sv"
      "$RTL/fpu/fpu_top.sv" "$RTL/fpu/fpu_srt_div.sv" "$RTL/fpu/fpu_sqrt_iter.sv"
      "$RTL/fpu/ven_bcd.sv" "$RTL/fpu/ven_bcd_to_fp.sv"
      "$RTL/fpu/fpu_fpatan.sv" "$RTL/fpu/fpu_fyl2x.sv" "$RTL/fpu/fpu_fsincos.sv"
      "$RTL/fpu/fpu_f2xm1.sv" "$RTL/fpu/fpu_fprem.sv"
      "$RTL/mem/dcache_timing.sv" "$RTL/mem/icache.sv" "$RTL/mem/uopcache.sv" "$RTL/mem/tlb.sv"
      "$RTL/bus/biu_p5.sv" "$RTL/bus/biu.sv"
      "$RTL/mem/ven_l1d.sv" "$RTL/mem/ven_axi_master.sv" "$RTL/mem/ventium_l1_axi.sv"
      "$GLS/tb_gls_soc.sv"
    )
    xvlog --relax -sv "${DFLAGS[@]}" \
      -i "$RTL/core" -i "$RTL/fpu" \
      "${SV[@]}" >>"$LOG" 2>&1
  fi
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: xvlog failed (rc=$rc); see $LOG" | tee -a "$LOG"
    grep -i "error" "$LOG" | tail -30
    exit 2
  fi
fi

# ---- 3. xelab: elaborate ----
echo "--- xelab: elaborating ---" | tee -a "$LOG"
XELAB_LIBS=()
if [ "$GLS_MODE" = "net" ]; then
  XELAB_LIBS=(-L unisims_ver -L secureip)
  TOP_ARGS=(tb_gls_soc glbl)
else
  TOP_ARGS=(tb_gls_soc)
fi

xelab "${TOP_ARGS[@]}" \
  -sv_lib dpi \
  -timescale 1ns/1ps \
  --relax \
  "${XELAB_LIBS[@]}" \
  -s gls_sim >>"$LOG" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "ERROR: xelab failed (rc=$rc); see $LOG" | tee -a "$LOG"
  grep -i "error" "$LOG" | tail -40
  exit 2
fi

# ---- 4. xsim: run ----
echo "--- xsim: running ---" | tee -a "$LOG"
# GLS_TRACE=1 enables the +gls_trace AR/beat fetch-forensic dump (first N bursts).
XSIM_PLUSARGS=(
  -testplusarg "disk=$GLS_DISK"
  -testplusarg "bios=$GLS_BIOS"
  -testplusarg "max_cycles=$GLS_MAX_CYCLES"
  -testplusarg "report_every=$GLS_REPORT"
)
if [ "${GLS_TRACE:-0}" = "1" ]; then
  XSIM_PLUSARGS+=(-testplusarg "gls_trace" -testplusarg "gls_trace_n=${GLS_TRACE_N:-8}")
fi
# DBG mode knobs (GLS_DBG=1): GLS_WEDGE_K cycles-with-no-retire wedge threshold
# (0 disables), GLS_NO_STOP_FAULT=1 keeps running past a detected exception.
if [ "$GLS_DBG" = "1" ]; then
  XSIM_PLUSARGS+=(-testplusarg "dbg_wedge_k=${GLS_WEDGE_K:-200000}")
  if [ "${GLS_NO_STOP_FAULT:-0}" = "1" ]; then
    XSIM_PLUSARGS+=(-testplusarg "dbg_no_stop_fault")
  fi
fi
xsim gls_sim --runall "${XSIM_PLUSARGS[@]}" 2>&1 | tee -a "$LOG"

echo "=== GLS run complete (mode=$GLS_MODE); log: $LOG ===" | tee -a "$LOG"
