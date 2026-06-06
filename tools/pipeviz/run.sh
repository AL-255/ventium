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

if [ "$BUILD" = "1" ] || [ ! -f "$HERE/libventium_viz.so" ]; then
  echo "[run] building backend ..."
  bash "$HERE/build.sh"
fi

# run from the repo root so default image paths (build/...) resolve, with the
# package dir on PYTHONPATH so `import pipeviz` works.
cd "$ROOT"
exec env PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" python3 -m pipeviz.main "${ARGS[@]}"
