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

# Mode-2 verification forks a worker tree after the Verilator build.  Scope
# the driver so the worker fan-out cannot bypass the generated-code guard.
if [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" != "1" ]; then
    exec "$ROOT/tools/build_scope.sh" -- "$0" "$@"
fi

export REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
export QEMU="$REFS/build/qemu/build/qemu-i386"
export ISA_VERIFY="$REFS/tools/isa_verify.py"
export GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
export COMPARE="$ROOT/verif/diff/compare.py"
export ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
# verify_worker hashes every oracle input even for a functional job.  The
# functional golden does not load this plug-in, but it still needs a stable
# value here so `set -u` cannot abort a wholly functional L1/AXI sweep.
export P5TRACE="${P5TRACE:-$ROOT/build/p5trace.so}"
export M5_METRICS="$ROOT/verif/m5_metrics.py"
export PYTHON="${PYTHON:-python3}"
export CC="${CC:-gcc}"
export CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
# env overrides let run-l1axi-cdc-verify.sh reuse this script verbatim for the
# dual-clock build (L1AXI_TARGET=l1axi_cdc, a separate obj dir + workdir + portbase).
export WORKDIR="${L1AXI_WORKDIR:-$ROOT/build/verify-l1axi}"
export CACHE_DIR="${L1AXI_CACHE_DIR:-$ROOT/build/golden-cache}" # REUSE mode-0 goldens
export PORTBASE="${PORTBASE:-27000}"
export TB_BIN="${L1AXI_TB_BIN:-$ROOT/verif/tb/${L1AXI_OBJDIR:-obj_dir_l1axi}/tb_ventium}"
export TB_EXTRA_FLAGS="--l1-axi --quiesce ${L1AXI_QUIESCE:-200000}"
L1AXI_TARGET="${L1AXI_TARGET:-l1axi}"
TESTS_DIR="$ROOT/verif/tests"
WORKER="$ROOT/verif/lib/verify_worker.sh"
# A whole-core Verilator compile consumes several GiB per C++ process.  Keep the
# correctness gate safe by default: one compile job, one functional worker, and
# ungrouped/split C++ sources.  A deliberately provisioned CI host may override
# these three variables, but an ordinary `make l1` must not OOM the workstation.
VL_J="${VL_J:-1}"
[[ "$VL_J" =~ ^[0-9]+$ ]] || { echo "L1AXI-VERIFY-FAIL: VL_J must be a non-negative integer"; exit 2; }
VL_SPLIT="${VL_SPLIT:---output-groups 0 --output-split 20000 --output-split-cfuncs 20000}"
VL_OPT_FAST="${VL_OPT_FAST:--O1}"
NCPU="${L1AXI_JOBS:-1}"
[[ "$NCPU" =~ ^[1-9][0-9]*$ ]] || { echo "L1AXI-VERIFY-FAIL: L1AXI_JOBS must be a positive integer"; exit 2; }

[ -x "$QEMU" ]     || { echo "L1AXI-VERIFY-FAIL: qemu-i386 missing: $QEMU"; exit 1; }
[ -f "$COMPARE" ]  || { echo "L1AXI-VERIFY-FAIL: compare.py missing"; exit 1; }
mkdir -p "$WORKDIR"
rm -f "$WORKDIR"/*.result 2>/dev/null || true

echo "== build the +VEN_L1_AXI tb ($L1AXI_TARGET, VL_J=$VL_J, workers=$NCPU) =="
make -C "$ROOT/verif/tb" "VL_J=$VL_J" "VL_SPLIT=$VL_SPLIT" "VL_OPT_FAST=$VL_OPT_FAST" "$L1AXI_TARGET" > "$WORKDIR/build.log" 2>&1 \
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
echo "=== L1AXI-VERIFY user-mode (mode-2 functional vs QEMU): PASS=$PASS FAIL=$FAIL / $TOTAL ==="

# ---- SYSTEM-MODE equivalence: mode-0 vs mode-2 retire trace -----------------
# The user-mode corpus does NOT exercise the slow-FSM arms (page-walk, descriptor/
# TSS reads, IDT delivery, SMRAM). Those address PHYSICAL memory through the same
# mem port, so a stalling L1 must not corrupt them. The system golden is infeasible
# for some (SMM), but mode-0 --system is already proven vs QEMU (the sys gate), so
# mode-0-vs-mode-2 equivalence is the right check here.
SYS_DIR="$ROOT/verif/sys/tests"
SYS_TESTS="pmode ppage pseg ptask pde pcpl pfault pv86 pintr pdebug"
TB0="$ROOT/verif/tb/obj_dir/tb_ventium"
[ -x "$TB0" ] || make -C "$ROOT/verif/tb" "VL_J=$VL_J" "VL_SPLIT=$VL_SPLIT" "VL_OPT_FAST=$VL_OPT_FAST" rtl > "$WORKDIR/build0.log" 2>&1 || true
SPASS=0; SFAIL=0; SFAILED=""
if [ -x "$TB0" ]; then
  for t in $SYS_TESTS; do
    img="$SYS_DIR/$t/$t.bin"; [ -f "$img" ] || continue
    mx=$(grep -oP '"max_insn":\s*\K[0-9]+' "$SYS_DIR/$t/manifest.json" 2>/dev/null || echo 4000)
    "$TB0" --image "$img" --system --out "$WORKDIR/${t}.m0" --max-insn "$mx" --quiesce 200000 >/dev/null 2>&1 || { SFAIL=$((SFAIL+1)); SFAILED="$SFAILED $t(m0)"; continue; }
    "$TB_BIN" --image "$img" --system --l1-axi --out "$WORKDIR/${t}.m2" --max-insn "$mx" --quiesce 200000 >/dev/null 2>&1
    grep '^{' "$WORKDIR/${t}.m2" > "$WORKDIR/${t}.m2c" 2>/dev/null
    if diff -q "$WORKDIR/${t}.m0" "$WORKDIR/${t}.m2c" >/dev/null 2>&1; then SPASS=$((SPASS+1)); else SFAIL=$((SFAIL+1)); SFAILED="$SFAILED $t"; fi
  done
  echo "=== L1AXI-VERIFY system-mode (mode-0 vs mode-2 equiv): PASS=$SPASS FAIL=$SFAIL ==="
fi

echo
# ---- REVIEW1_Aug2 M-08: harness self-test --------------------------------------
# The failure branch below used to print and then return zero. Fixing that is not
# self-proving: a gate that CANNOT fail looks identical to one that never does. With
# VEN_L1AXI_SELFTEST=1 a failure is injected here, so the exit path can be exercised
# on demand -- `VEN_L1AXI_SELFTEST=1 bash verif/l1/run-l1axi-verify.sh; echo $?`
# must print L1AXI-VERIFY-FAIL and 1.
if [ "${VEN_L1AXI_SELFTEST:-0}" != "0" ]; then
  echo "SELFTEST: injecting one deliberate failure to exercise the exit path"
  FAIL=$((FAIL+1)); FAILED="$FAILED <selftest-injected>"
fi
if [ "$FAIL" -eq 0 ] && [ "$SFAIL" -eq 0 ]; then
  echo "L1AXI-VERIFY-OK  (user $PASS/$TOTAL vs QEMU + system $SPASS mode-2==mode-0)"
else
  [ "$FAIL"  -ne 0 ] && echo "USER FAILING:$FAILED"
  [ "$SFAIL" -ne 0 ] && echo "SYS FAILING:$SFAILED"
  echo "L1AXI-VERIFY-FAIL"
  # REVIEW1_Aug2 M-08: this branch printed the failure and then RETURNED ZERO,
  # because `echo` was the last command. `make l1` -- and therefore verify-all --
  # reported this sweep as passing while its own summary said PASS=51 FAIL=47.
  # run-l1axi-cdc-verify.sh `exec`s this script, so both sweeps lied the same way.
  exit 1
fi
