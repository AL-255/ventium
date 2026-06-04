#!/usr/bin/env bash
# Ventium M2S.0 — build qemu-system-i386 (i386-softmmu) for the SYSTEM-MODE oracle.
#
# The user-mode roadmap (M0..M6) verifies against qemu-i386 (linux-user), built by
# ventium-refs/07-p5-emulation-harness/scripts/10-build-emulator.sh into
#   .../build/qemu/build/qemu-i386     <-- DO NOT DISTURB (make verify depends on it)
#
# System mode (protected mode, paging, interrupts, TSS, SMM, debug) needs the FULL
# machine model, i.e. the i386-softmmu target.  We build that out-of-tree in a
# SEPARATE build dir so the user-mode build is never touched:
#   .../build/qemu/build-sys/qemu-system-i386   <-- this script's output
#
# Idempotent: if the binary already exists and runs, we skip (re)building.
# Logs to .../build/qemu-system-{configure,build}.log.
set -euo pipefail

# Resolve the qemu source tree (the same shallow clone the user-mode build used).
# This script lives in verif/sys/ of the ventium repo.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REFS="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU_SRC="$REFS/build/qemu"
BUILD_SYS="$QEMU_SRC/build-sys"
LOGDIR="$REFS/build"
JOBS="$(nproc)"

QEMU_REF="${QEMU_REF:-v8.2.2}"
SYS_BIN="$BUILD_SYS/qemu-system-i386"

log(){ echo "[$(date +%H:%M:%S)] $*"; }

# --- 0. sanity: the source tree must exist (cloned by 10-build-emulator.sh) -----
if [[ ! -d "$QEMU_SRC" ]]; then
  echo "ERROR: qemu source tree not found at $QEMU_SRC" >&2
  echo "       Run ventium-refs/07-p5-emulation-harness/scripts/10-build-emulator.sh first" >&2
  echo "       (it shallow-clones qemu $QEMU_REF for the user-mode build)." >&2
  exit 1
fi

# --- 1. idempotent skip ---------------------------------------------------------
if [[ -x "$SYS_BIN" ]] && "$SYS_BIN" --version 2>/dev/null | grep -qi "QEMU emulator"; then
  log "qemu-system-i386 already built ($SYS_BIN) — skipping"
  "$SYS_BIN" --version | head -1
  echo "BUILD-COMPLETE"
  exit 0
fi

# --- 2. configure (out-of-tree, system target, plugins) -------------------------
# QEMU's build bootstraps a venv; force the system python which has venv+ensurepip
# (the conda python3 that may be first on PATH lacks ensurepip and breaks it).
PYBIN=/usr/bin/python3
command -v "$PYBIN" >/dev/null || PYBIN="$(command -v python3)"

mkdir -p "$BUILD_SYS"
log "configuring qemu-system (i386-softmmu, plugins) with python=$PYBIN"
( cd "$BUILD_SYS" && "$QEMU_SRC/configure" \
      --target-list=i386-softmmu \
      --enable-plugins \
      --python="$PYBIN" \
      --disable-tools \
      --disable-docs \
      --disable-werror \
      >"$LOGDIR/qemu-system-configure.log" 2>&1 )

# --- 3. build -------------------------------------------------------------------
log "building qemu-system-i386 (this is the long pole, ~10 min)"
make -C "$BUILD_SYS" -j"$JOBS" qemu-system-i386 >"$LOGDIR/qemu-system-build.log" 2>&1 \
  || make -C "$BUILD_SYS" -j"$JOBS"             >"$LOGDIR/qemu-system-build.log" 2>&1
log "qemu-system done -> $SYS_BIN"

# --- 4. summary -----------------------------------------------------------------
echo "=== BUILD SUMMARY ==="
echo "qemu-system-i386 : $SYS_BIN $( [[ -x $SYS_BIN ]] && echo OK || echo MISSING )"
[[ -x "$SYS_BIN" ]] && "$SYS_BIN" --version | head -1
echo "BUILD-COMPLETE"
