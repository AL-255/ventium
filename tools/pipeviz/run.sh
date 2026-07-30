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
ARGS=()
for a in "$@"; do
  if [ "$a" = "--build" ]; then BUILD=1; else ARGS+=("$a"); fi
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

if [ "$BUILD" = "1" ] || [ ! -f "$HERE/libventium_viz.so" ] \
   || [ "$HERE/ventium_viz.cpp" -nt "$HERE/libventium_viz.so" ] \
   || [ "$HERE/ventium_viz.h" -nt "$HERE/libventium_viz.so" ] \
   || [ "$HERE/build.sh" -nt "$HERE/libventium_viz.so" ]; then
  echo "[run] building backend ..."
  bash "$HERE/build.sh"
fi

# run from the repo root so default image paths (build/...) resolve, with the
# package dir on PYTHONPATH so `import pipeviz` works.
cd "$ROOT"
exec env PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" \
  "$PYTHON_BIN" -m pipeviz.main "${ARGS[@]}"
