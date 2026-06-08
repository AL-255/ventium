#!/usr/bin/env bash
# verif/l1/run-l1axi-verify.sh — P1-1 mode-2 (L1+AXI) FUNCTIONAL gate vs QEMU.
#
# Boots the WHOLE core through ventium_l1_axi (the `+VEN_L1_AXI` build, `--l1-axi`)
# and compares each program's RTL retire trace against the QEMU GOLDEN — the proper
# functional-equivalence proof (mode 2 timing is emergent, so only func is graded).
# Reuses verify_worker.sh verbatim (ELF build, golden gen/CACHE, init-esp, compare)
# with TB_BIN pointed at obj_dir_l1axi/tb_ventium + TB_EXTRA_FLAGS="--l1-axi
# --quiesce ...". The golden is QEMU (mode-independent) so the mode-0 golden cache
# is reused as-is. A high --quiesce is REQUIRED: a multi-cycle mode-2 access (an
# icache/L1 fill, a 27-beat FNSAVE) can go many clocks without retiring, which the
# default --quiesce 64 would mistake for an idle core. Runs parallel across cores.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
export QEMU="$REFS/build/qemu/build/qemu-i386"
export ISA_VERIFY="$REFS/tools/isa_verify.py"
export GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
export COMPARE="$ROOT/verif/diff/compare.py"
export ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
export M5_METRICS="$ROOT/verif/m5_metrics.py"
export PYTHON="${PYTHON:-python3}"
export CC="${CC:-gcc}"
export CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
export WORKDIR="$ROOT/build/verify-l1axi"
export CACHE_DIR="$ROOT/build/golden-cache"          # REUSE the mode-0 QEMU goldens
export PORTBASE="${PORTBASE:-27000}"
export TB_BIN="$ROOT/verif/tb/obj_dir_l1axi/tb_ventium"
export TB_EXTRA_FLAGS="--l1-axi --quiesce ${L1AXI_QUIESCE:-200000}"
TESTS_DIR="$ROOT/verif/tests"
WORKER="$ROOT/verif/lib/verify_worker.sh"
NCPU="$(nproc 2>/dev/null || echo 4)"; [ "$NCPU" -gt 3 ] && NCPU=$(( NCPU - 2 ))

[ -x "$QEMU" ]     || { echo "L1AXI-VERIFY-FAIL: qemu-i386 missing: $QEMU"; exit 1; }
[ -f "$COMPARE" ]  || { echo "L1AXI-VERIFY-FAIL: compare.py missing"; exit 1; }
mkdir -p "$WORKDIR"
rm -f "$WORKDIR"/*.result 2>/dev/null || true

echo "== build the +VEN_L1_AXI tb (obj_dir_l1axi) =="
make -C "$ROOT/verif/tb" l1axi > "$WORKDIR/build.log" 2>&1 \
    || { echo "L1AXI-VERIFY-FAIL (build)"; tail -15 "$WORKDIR/build.log"; exit 1; }

# ---- build the FUNC job list (one per manifest) ----------------------------
JOBS="$WORKDIR/jobs.txt"; : > "$JOBS"; IDX=0
for MF in $(find "$TESTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json | sort); do
    read -r NAME SRC_REL LOAD ENTRY MAX X87 < <("$PYTHON" - "$MF" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
def g(k,d=""):
    v=m.get(k,d); return d if v is None else v
x87=m.get("x87",False)
if isinstance(x87,str): x87=x87.strip().lower() in ("1","true","yes","on")
print(g("name"),g("src"),g("load_addr"),g("entry"),g("max_insn"),"1" if x87 else "0")
PY
)
    SRC="$TESTS_DIR/$SRC_REL"
    [ -n "$NAME" ] && [ -f "$SRC" ] || continue
    printf 'func\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t-\tINT\n' \
        "$NAME" "$SRC" "$LOAD" "$ENTRY" "$MAX" "$X87" "$IDX" >> "$JOBS"
    IDX=$(( IDX + 1 ))
done
TOTAL=$(wc -l < "$JOBS")
echo "== mode-2 func vs golden: $TOTAL programs, $NCPU workers, quiesce ${L1AXI_QUIESCE:-200000} =="

# ---- run the worker per job, in parallel -----------------------------------
xargs -P "$NCPU" -L1 bash "$WORKER" < "$JOBS" > "$WORKDIR/run.log" 2>&1 || true

# ---- tally -----------------------------------------------------------------
PASS=0; FAIL=0; FAILED=""
while IFS= read -r line; do
    NAME=$(cut -d'	' -f2 <<<"$line")
    RES="$WORKDIR/${NAME}.func.result"
    if [ -f "$RES" ] && grep -q '|PASS|' "$RES"; then PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); FAILED="$FAILED $NAME"; fi
done < "$JOBS"

echo
echo "=== L1AXI-VERIFY (mode-2 functional vs QEMU): PASS=$PASS FAIL=$FAIL / $TOTAL ==="
if [ "$FAIL" -eq 0 ]; then echo "L1AXI-VERIFY-OK"; else echo "FAILING:$FAILED"; echo "L1AXI-VERIFY-FAIL"; fi
