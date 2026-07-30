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
ARGS=()
for a in "$@"; do
  if [ "$a" = "--build" ]; then
    BUILD=1
  elif [ "$a" = "--check" ]; then
    CHECK=1
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

BACKEND="$HERE/libventium_viz.so"
REBUILD_REASON=""
if [ "$BUILD" = "1" ]; then
  REBUILD_REASON="requested by --build"
elif [ ! -f "$BACKEND" ]; then
  REBUILD_REASON="backend is missing"
else
  for dep in "$HERE/ventium_viz.cpp" "$HERE/ventium_viz.h" \
             "$HERE/build.sh" "$HERE/pipeviz/backend.py"; do
    if [ -f "$dep" ] && [ "$dep" -nt "$BACKEND" ]; then
      REBUILD_REASON="$dep changed"
      break
    fi
  done
  if [ -z "$REBUILD_REASON" ]; then
    RTL_NEWER="$(find "$ROOT/rtl" -type f \
      \( -name '*.sv' -o -name '*.svh' -o -name '*.f' \) \
      -newer "$BACKEND" -print -quit 2>/dev/null || true)"
    [ -z "$RTL_NEWER" ] || REBUILD_REASON="$RTL_NEWER changed"
  fi
  if [ -z "$REBUILD_REASON" ]; then
    for dep in "$ROOT/verif/tb/memmodel.cpp" "$ROOT/verif/tb/memmodel.h"; do
      if [ -f "$dep" ] && [ "$dep" -nt "$BACKEND" ]; then
        REBUILD_REASON="$dep changed"
        break
      fi
    done
  fi
fi

if [ "$CHECK" = "1" ]; then
  if [ -n "$REBUILD_REASON" ]; then
    echo "[run] backend stale: $REBUILD_REASON" >&2
    echo "[run] rebuild with: $HERE/run.sh --build" >&2
    exit 2
  fi
  echo "[run] backend ready: $BACKEND"
  exit 0
fi

if [ -n "$REBUILD_REASON" ]; then
  echo "[run] building backend ($REBUILD_REASON) ..."
  bash "$HERE/build.sh"
fi

# run from the repo root so default image paths (build/...) resolve, with the
# package dir on PYTHONPATH so `import pipeviz` works.
cd "$ROOT"
exec env PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" \
  "$PYTHON_BIN" -m pipeviz.main "${ARGS[@]}"
