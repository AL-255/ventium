#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Reuse both P54 queue slots across fused/nonfused packet generations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-axi-quad-reuse.XXXXXX")"
run_args=("$@")
# Preserve red evidence; the caller can remove validated temporary targets later.
echo "artifacts: $OBJ"
receipt() {
    python3 - "$OBJ" "$ROOT" "$1" "$2" "${run_args[@]}" <<'PY'
import hashlib, json, pathlib, sys
out, root = map(pathlib.Path, sys.argv[1:3])
paths = ("rtl/mem/ven_axi_master.sv", "verif/l1/tb_axi_quad_reuse.sv")
(out / "receipt.json").write_text(json.dumps({
    "status": sys.argv[3], "returncode": int(sys.argv[4]),
    "args": sys.argv[5:], "scope_profile": "default",
    "source_sha256": {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in paths},
    "production_rtl_modified_by_test": False,
}, indent=2) + "\n")
PY
}
extra=()
quad=1
for arg in "$@"; do
    case "$arg" in
        --slot1) extra+=(+define+VEN_AXI_QUAD_REUSE_SLOT1) ;;
        --backpressure) extra+=(+define+VEN_AXI_QUAD_REUSE_BACKPRESSURE) ;;
        --pipe-dispatch) extra+=(+define+VEN_P54_WBUF_PIPE_DISPATCH) ;;
        --aligned-v) extra+=(+define+VEN_AXI_QUAD_REUSE_ALIGNED_V) ;;
        --no-quad) quad=0 ;;
        *) echo "usage: $0 [--no-quad] [--slot1] [--backpressure] [--pipe-dispatch] [--aligned-v]" >&2; exit 2 ;;
    esac
done
if (( quad )); then extra+=(+define+VEN_P54_WBUF_QUAD_COMBINE); fi
timeout 120 "$ROOT/tools/verilator_serial.sh" -j 2 --binary -sv --assert \
    -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    +define+VEN_P54_DUAL_STORE_PAIR "${extra[@]}" \
    --top-module tb_axi_quad_reuse -Mdir "$OBJ" -o tb_axi_quad_reuse \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/verif/l1/tb_axi_quad_reuse.sv" \
    > "$OBJ/build.log" 2>&1 || { rc=$?; receipt BUILD_FAIL "$rc"; tail -50 "$OBJ/build.log"; exit 1; }
timeout 10 "$OBJ/tb_axi_quad_reuse" > "$OBJ/run.log" 2>&1 || { rc=$?; receipt RUN_FAIL "$rc"; tail -30 "$OBJ/run.log"; exit 1; }
if rg 'AXI-QUAD-REUSE-GATE-OK' "$OBJ/run.log"; then
    receipt PASS 0
else
    receipt MISSING_PASS_MARKER 1
    exit 1
fi
