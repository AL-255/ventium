#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0 # the intentional old-source assertion must not leave a core dump
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-window-keep-store.XXXXXX")"
echo "Artifacts: $OUT"
sha256sum "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/window-keep-store.patch" \
    "$ROOT/verif/l1/tb_l1d_window_keep_store.sv" "$0" > "$OUT/source-before.sha256"
mkdir -p "$OUT/original/rtl/mem" "$OUT/patched/rtl/mem"
cp "$ROOT/rtl/mem/ven_l1d.sv" "$OUT/original/rtl/mem/ven_l1d.sv"
cp "$ROOT/rtl/mem/ven_l1d.sv" "$OUT/patched/rtl/mem/ven_l1d.sv"
if grep -q '^`ifdef VEN_L1D_WINDOW_KEEP_STORE$' "$ROOT/rtl/mem/ven_l1d.sv"; then
    # After production application, reconstruct only the scratch old-source
    # control. The candidate copy stays byte-identical to the live source.
    patch --batch --reverse --fuzz=0 -p1 -d "$OUT/original" \
        < "$ROOT/verif/l1/window-keep-store.patch" > "$OUT/patch.log"
else
    patch --batch --forward --fuzz=0 -p1 -d "$OUT/patched" \
        < "$ROOT/verif/l1/window-keep-store.patch" > "$OUT/patch.log"
fi
build_run() {
    local label="$1" source="$2" keep="$3" tag="$4"
    local extra=()
    if [[ "$keep" == 1 ]]; then extra+=(+define+VEN_L1D_WINDOW_KEEP_STORE); fi
    if [[ "$tag" == 1 ]]; then extra+=(+define+VEN_L1D_TAG_INVALIDATE); fi
    (
        set -x
        "$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
            -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
            -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_L1D_WINDOW_REUSE \
            +define+VEN_FP_LOAD64 +define+VEN_L1D_HIT_STREAM +define+VEN_PIPE_MEM_CHAIN \
            "${extra[@]}" --top-module tb_l1d_window_keep_store -Mdir "$OUT/$label" \
            "$source" "$ROOT/verif/l1/tb_l1d_window_keep_store.sv"
    ) > "$OUT/$label.build.log" 2>&1 || { tail -50 "$OUT/$label.build.log"; return 1; }
    "$OUT/$label/Vtb_l1d_window_keep_store" > "$OUT/$label.run.log" 2>&1 || {
        tail -8 "$OUT/$label.run.log"; return 1;
    }
}
for tag in 0 1; do
    build_run "original_$tag" "$OUT/original/rtl/mem/ven_l1d.sv" 0 "$tag"
    build_run "off_$tag" "$OUT/patched/rtl/mem/ven_l1d.sv" 0 "$tag"
    build_run "on_$tag" "$OUT/patched/rtl/mem/ven_l1d.sv" 1 "$tag"
done
# The original source with the candidate's expected policy must fail the first
# actual retention/reuse witness. A compile error is NOT a valid negative.
if build_run old_negative "$OUT/original/rtl/mem/ven_l1d.sv" 1 1; then
    echo "FAIL: original source unexpectedly passed candidate witness"; exit 1
fi
test -x "$OUT/old_negative/Vtb_l1d_window_keep_store"
grep -q 'window store policy' "$OUT/old_negative.run.log"
python3 - "$OUT" <<'PY'
import json
from pathlib import Path
import re
import sys
out=Path(sys.argv[1])
results={}
for tag in (0,1):
    for mode in ('original','off','on'):
        key=f'{mode}_{tag}'
        log=(out/f'{key}.run.log').read_text()
        assert 'L1D-WINDOW-KEEP-STORE-OK' in log, key
        matches=re.findall(r'^WINDOW-KEEP-STORE-RESULT (.*)$',log,re.M)
        assert len(matches)==1, key
        results[key]=dict(item.split('=') for item in matches[0].split())
    a,b=results[f'off_{tag}'],results[f'on_{tag}']
    assert a==results[f'original_{tag}'], 'default-off behavior changed'
    for field in ('reads','writes','checksum','backing_reads'):
        assert a[field]==b[field], (tag,field,a,b)
    saved=int(a['clocks'])-int(b['clocks'])
    captures=int(a['captures'])-int(b['captures'])
    assert saved==captures and saved>0, (tag,saved,captures)
    assert int(b['reuse'])>0 and int(a['reuse'])==0
    print(f'tag={tag} saved_capture_slots={saved} reads={a["reads"]} writes={a["writes"]} checksum={a["checksum"]}')
(out/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
PY
sha256sum -c "$OUT/source-before.sha256" > "$OUT/source-stability.log"
sha256sum "$OUT"/*/Vtb_l1d_window_keep_store > "$OUT/binaries.sha256"
echo "L1D-WINDOW-KEEP-STORE-AB-OK $OUT"
