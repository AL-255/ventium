#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Launch the Ventium pipeline visualizer. Builds libventium_viz.so on first run
# (or when --build is given), then starts the PySide6 GUI. Any extra args are
# passed through to the app (e.g. an image path, --entry 0x..., --esp 0x...).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

BUILD=0
CHECK=0
SOC_REQUESTED=0
HELP=0
ARGS=()
for a in "$@"; do
  if [ "$a" = "--build" ]; then
    BUILD=1
  elif [ "$a" = "--check" ]; then
    CHECK=1
  elif [ "$a" = "--soc" ]; then
    SOC_REQUESTED=1
    ARGS+=("$a")
  elif [ "$a" = "--help" ] || [ "$a" = "-h" ]; then
    HELP=1
    ARGS+=("$a")
  else
    ARGS+=("$a")
  fi
done

# Validate the cheap Python side before a potentially long first Verilator
# build. A missing GUI environment should fail in milliseconds, not afterward.
PYTHON_BIN="${PIPEVIZ_PYTHON:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "[run] Python interpreter not found: $PYTHON_BIN" >&2
  echo "[run] set PIPEVIZ_PYTHON=/path/to/python" >&2
  exit 1
fi
if ! "$PYTHON_BIN" -c 'import PySide6, capstone' >/dev/null 2>&1; then
  echo "[run] missing Python GUI dependencies for $PYTHON_BIN" >&2
  echo "[run] install with: $PYTHON_BIN -m pip install -r $HERE/requirements.txt" >&2
  exit 1
fi

launch_app() {
  cd "$ROOT"
  exec env PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" \
    "$PYTHON_BIN" -m pipeviz.main "${ARGS[@]}"
}

# argparse help imports the Python UI but never constructs a backend. Do not
# turn a usage question into a multi-minute Verilator build.
if [ "$HELP" = "1" ]; then
  launch_app
fi

backend_reason() {
  local backend="$1" label="$2" dep rtl_newer
  if [ ! -f "$backend" ]; then
    echo "$label backend is missing"
    return
  fi
  for dep in "$HERE/ventium_viz.cpp" "$HERE/ventium_viz.h" \
             "$HERE/build.sh" "$HERE/pipeviz/backend.py"; do
    if [ -f "$dep" ] && [ "$dep" -nt "$backend" ]; then
      echo "$dep changed"
      return
    fi
  done
  rtl_newer="$(find "$ROOT/rtl" -type f \
    \( -name '*.sv' -o -name '*.svh' -o -name '*.f' \) \
    -newer "$backend" -print -quit 2>/dev/null || true)"
  if [ -n "$rtl_newer" ]; then
    echo "$rtl_newer changed"
    return
  fi
  for dep in "$ROOT/verif/tb/memmodel.cpp" "$ROOT/verif/tb/memmodel.h"; do
    if [ -f "$dep" ] && [ "$dep" -nt "$backend" ]; then
      echo "$dep changed"
      return
    fi
  done
}

BACKEND="$HERE/libventium_viz.so"
SOC_BACKEND="$HERE/libventium_viz_soc.so"
SOC_FILELIST="$ROOT/rtl/ventium_soc.f"
if [ "$BUILD" = "1" ]; then
  REBUILD_REASON="requested by --build"
else
  REBUILD_REASON="$(backend_reason "$BACKEND" "core")"
fi
SOC_REASON=""
if [ "$SOC_REQUESTED" = "1" ]; then
  if [ ! -f "$SOC_FILELIST" ]; then
    SOC_REASON="SoC RTL file list is missing: $SOC_FILELIST"
  elif [ "$BUILD" = "1" ]; then
    SOC_REASON="requested by --build --soc"
  else
    SOC_REASON="$(backend_reason "$SOC_BACKEND" "SoC")"
  fi
fi

if [ "$CHECK" = "1" ]; then
  if [ -n "$REBUILD_REASON" ]; then
    echo "[run] backend stale: $REBUILD_REASON" >&2
    echo "[run] rebuild with: $HERE/run.sh --build" >&2
    exit 2
  fi
  if [ -n "$SOC_REASON" ]; then
    echo "[run] SoC backend unavailable or stale: $SOC_REASON" >&2
    echo "[run] rebuild with: $HERE/run.sh --build --soc" >&2
    exit 2
  fi
  echo "[run] backend ready: $BACKEND"
  if [ "$SOC_REQUESTED" = "1" ]; then
    echo "[run] SoC backend ready: $SOC_BACKEND"
  fi
  exit 0
fi

if [ -n "$REBUILD_REASON" ] \
   || { [ -n "$SOC_REASON" ] && [ -f "$SOC_FILELIST" ]; }; then
  BUILD_REASON="$REBUILD_REASON"
  [ -n "$BUILD_REASON" ] || BUILD_REASON="$SOC_REASON"
  echo "[run] building backend ($BUILD_REASON) ..."
  if [ "$SOC_REQUESTED" = "1" ]; then
    bash "$HERE/build.sh" --soc
  else
    bash "$HERE/build.sh"
  fi
fi

# Run from the repo root so default image paths (build/...) resolve, with the
# package dir on PYTHONPATH so `import pipeviz` works.
launch_app
