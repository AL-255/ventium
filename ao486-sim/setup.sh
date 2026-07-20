#!/usr/bin/env bash
# setup.sh — reproducible build of the ao486 Win95 SoC simulator from a clean clone.
#
# Steps: init the ao486_MiSTer RTL submodule, apply the boot-path RTL patch, build the
# time() shim, and build the Verilator sim. Idempotent: safe to re-run.
#
# Prereqs: git, verilator (>= 5.0), a C++17 g++/clang, GNU make, mtools (for the disk
# fix). On Debian/Ubuntu: apt-get install verilator g++ make mtools git
#
# After this, see REPRODUCE.md for obtaining the disk image and running to the desktop.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."   # repo root

SUB=3rd-party/ao486_MiSTer
PATCH="$(pwd)/ao486-sim/patches/ao486_MiSTer.patch"

echo "==> [1/4] init submodule $SUB"
git submodule update --init --recursive "$SUB"

echo "==> [2/4] apply boot-path RTL patch to $SUB"
if git -C "$SUB" apply --check --reverse "$PATCH" 2>/dev/null; then
  echo "    already applied."
elif git -C "$SUB" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SUB" apply "$PATCH"; echo "    applied ao486_MiSTer.patch."
else
  echo "    ERROR: patch does not apply cleanly. Is the submodule at the pinned commit?" >&2
  echo "    Expected base: $(git ls-tree HEAD "$SUB" | awk '{print $3}')" >&2
  exit 1
fi

echo "==> [3/4] build the time() shim -> tmp/time_shim.so"
mkdir -p tmp
cc -shared -fPIC -O2 -o tmp/time_shim.so ao486-sim/tools/time_shim.c
echo "    ok."

echo "==> [4/4] build the sim (verilator + c++)"
# Default: release build -> ao486-sim/obj_dir/ao486sim (fastest; boots to desktop).
# For the eip-traced diagnostic build used in AO486_SOC_FIX.md examples, run instead:
#   make -C ao486-sim FAST=1 OBJDIR=ao486-sim/obj_dir_dbg EXE=ao486sim_dbg
make -C ao486-sim
echo
echo "==> done. Binary: ao486-sim/obj_dir/ao486sim"
echo "    Next: place a Win95 raw HDD image at ao486-sim/run_w95/w95_200.vhd,"
echo "    run  ao486-sim/tools/apply_win95_display_fix.sh ao486-sim/run_w95/w95_200.vhd,"
echo "    then follow REPRODUCE.md to boot to the desktop."
