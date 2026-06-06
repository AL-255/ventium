#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tools/pipeviz/build.sh — verilate ventium_top with --public-flat-rw (so the
# pipeline visualizer's C++ bridge can read every internal core/cache/TLB/FPU
# signal via the generated ___024root struct) and link the bridge into the
# shared library libventium_viz.so consumed by the PySide6 GUI (pipeviz/).
#
# Reuses the production BFM memory (verif/tb/memmodel.cpp). Self-contained: never
# touches rtl/ or the verification build dirs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="$HERE/obj_dir"
OBJO="$HERE/build_o"
RTL_F="$ROOT/rtl/ventium.f"
TB="$ROOT/verif/tb"
VERILATOR="${VERILATOR:-verilator}"
JOBS="$(nproc 2>/dev/null || echo 4)"

echo "[pipeviz] verilator: $($VERILATOR --version 2>&1 | head -1)"

# ---- locate the Verilator runtime include dir ------------------------------
VINC=""
if VR="$($VERILATOR --getenv VERILATOR_ROOT 2>/dev/null)" && [ -n "$VR" ] && [ -d "$VR/include" ]; then
  VINC="$VR/include"
else
  for c in /usr/share/verilator/include /usr/local/share/verilator/include \
           "$(dirname "$(command -v "$VERILATOR")")/../share/verilator/include"; do
    [ -d "$c" ] && { VINC="$c"; break; }
  done
fi
[ -n "$VINC" ] && [ -f "$VINC/verilated.cpp" ] || {
  echo "[pipeviz] ERROR: cannot find the Verilator include dir (verilated.cpp)." >&2
  echo "          Set VERILATOR_ROOT or install verilator's runtime sources." >&2
  exit 1
}
echo "[pipeviz] verilator runtime include: $VINC"

# build_variant <top-module> <filelist> <objdir> <extra-define> <out.so>
build_variant() {
  local top="$1" flist="$2" objd="$3" define="$4" out="$5"
  local objo="$objd.o"
  echo "[pipeviz] verilating $top (--public-flat-rw) ..."
  rm -rf "$objd"
  "$VERILATOR" --cc --public-flat-rw \
    -sv --top-module "$top" \
    -Wall -Wno-UNUSED -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-LATCH \
    -Mdir "$objd" \
    -F "$flist"

  echo "[pipeviz] compiling $top bridge + model (-fPIC, -j$JOBS) ..."
  rm -rf "$objo"; mkdir -p "$objo"
  local CXXFLAGS=(-std=c++17 -O1 -fPIC -fno-strict-aliasing -Wno-attributes
                  -I"$objd" -I"$VINC" -I"$VINC/vltstd" -I"$TB" -I"$HERE")
  [ -n "$define" ] && CXXFLAGS+=("$define")
  local SRCS=( "$objd"/*.cpp "$VINC/verilated.cpp" "$VINC/verilated_threads.cpp"
               "$VINC/verilated_dpi.cpp" "$HERE/ventium_viz.cpp" "$TB/memmodel.cpp" )
  local fail=0
  for src in "${SRCS[@]}"; do
    local o="$objo/$(printf '%s' "$src" | md5sum | cut -c1-16)_$(basename "$src").o"
    ( g++ "${CXXFLAGS[@]}" -c "$src" -o "$o" || { echo "[pipeviz] COMPILE FAILED: $src" >&2; exit 1; } ) &
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || fail=1; done
  done
  wait || fail=1
  [ "$fail" -eq 0 ] || { echo "[pipeviz] ERROR: compile failed for $top." >&2; exit 1; }

  echo "[pipeviz] linking $out ..."
  g++ -shared -fPIC "$objo"/*.o -o "$out" -lpthread -latomic 2>/dev/null \
    || g++ -shared -fPIC "$objo"/*.o -o "$out" -lpthread
  echo "[pipeviz] OK -> $out"
}

# default: build the ventium_top library; with `--soc` (or SOC=1) ALSO build the
# full-SoC library (libventium_viz_soc.so) so bare-metal images like test386 run.
build_variant ventium_top "$RTL_F" "$OBJ" "" "$HERE/libventium_viz.so"

SOC_F="$ROOT/rtl/ventium_soc.f"
if [ "${1:-}" = "--soc" ] || [ "${SOC:-0}" = "1" ] || [ "${BUILD_SOC:-0}" = "1" ]; then
  if [ -f "$SOC_F" ]; then
    build_variant ventium_soc "$SOC_F" "$HERE/obj_dir_soc" "-DVV_SOC" "$HERE/libventium_viz_soc.so"
  else
    echo "[pipeviz] WARNING: $SOC_F not found; skipping SoC library." >&2
  fi
fi
ls -la "$HERE"/libventium_viz*.so
