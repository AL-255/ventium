#!/usr/bin/env bash
# =============================================================================
# verif/run-m0-smoke.sh — Ventium M0 end-to-end smoke runner.
#
# Wires the six M0 components together and runs the differential pipeline once
# on the smoke corpus:
#
#   A) build the smoke test     (verif/tests)            -> smoke.elf + smoke.flat
#   B) build the cycle plugin   (verif/qemu-plugins)     -> build/p5trace.so
#   C) build the RTL testbench  (verif/tb against rtl/)  -> obj_dir/tb_ventium
#   D) golden FUNC trace        (verif/qemu-trace, gdbstub single-step)
#   E) golden CYCLE trace       (qemu-i386 -cpu pentium + p5trace.so)
#   F) RTL FUNC trace           (tb_ventium on smoke.flat)
#   G) compare A-vs-C func, and validate the cycle trace (E)
#
# M0 GATE (docs/trace-format.md §4, PLAN.md §7 M0) is INFRASTRUCTURE, not
# functional correctness: the RTL is a NOP stub, so the func comparator is
# EXPECTED to report a coherent first divergence (exit 1). SUCCESS == all three
# producers emit well-formed .vtrace and the comparator runs end-to-end with a
# sensible verdict.
#
# Usage:  bash verif/run-m0-smoke.sh    (or: make m0-smoke)
# =============================================================================

set -uo pipefail
# NOTE: we deliberately do NOT use `set -e`. The whole point of M0 is to run the
# comparator and PRINT its (expected-nonzero) verdict; an errexit would abort
# before we report. Build/producer steps are checked explicitly via die().

# ---- locate the repo root (this script lives in <root>/verif) ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- pinned paths (all absolute) --------------------------------------------
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QEMU="$REFS/build/qemu/build/qemu-i386"
QEMU_SRC="$REFS/build/qemu"
CAPSTONE="$REFS/build/capstone"

GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
TRACEFMT_DIR="$ROOT/verif/diff"

TESTS_DIR="$ROOT/verif/tests"
MANIFEST="$TESTS_DIR/smoke/manifest.json"

BUILD="$ROOT/build"
M0="$BUILD/m0"
PLUGIN_SO="$BUILD/p5trace.so"
TB_BIN="$ROOT/verif/tb/obj_dir/tb_ventium"

QEMU_FUNC="$M0/qemu_func.vtrace"
QEMU_CYCLE="$M0/qemu_cycle.vtrace"
RTL_FUNC="$M0/rtl_func.vtrace"

PYTHON="${PYTHON:-python3}"

# ---- helpers ----------------------------------------------------------------
say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Validate a .vtrace via the shared parser; prints "<label>: <mode> trace OK,
# N records" or dies. Args: <label> <path> <expect-producer> <expect-mode>.
validate_vtrace() {
    local label="$1" path="$2" want_prod="$3" want_mode="$4"
    [ -s "$path" ] || die "$label: trace file is empty/missing ($path)"
    PYTHONPATH="$TRACEFMT_DIR" "$PYTHON" - "$path" "$label" "$want_prod" "$want_mode" <<'PY'
import sys, re
import tracefmt
path, label, want_prod, want_mode = sys.argv[1:5]
t = tracefmt.read_trace(path)
h = t.hdr
assert h.get("vtrace") == 1, f"{label}: bad vtrace version {h.get('vtrace')}"
assert h.get("producer") == want_prod, f"{label}: producer {h.get('producer')} != {want_prod}"
assert h.get("mode") == want_mode, f"{label}: mode {h.get('mode')} != {want_mode}"
recs = t.records
assert len(recs) >= 1, f"{label}: no records"
ns = [r["n"] for r in recs]
assert ns == sorted(ns) and len(set(ns)) == len(ns), f"{label}: n not strictly increasing: {ns}"
assert ns[0] == 0, f"{label}: first n is {ns[0]} (expected 0)"
if want_mode == "func":
    for r in recs:
        for k in tracefmt.GPR_KEYS + ["eflags", "pc"]:
            assert re.fullmatch(r"0x[0-9a-f]{8}", r[k]), f"{label}: bad 32b field {k}={r.get(k)} @n={r['n']}"
        for k in tracefmt.SEG_KEYS:
            assert re.fullmatch(r"0x[0-9a-f]{4}", r[k]), f"{label}: bad seg {k}={r.get(k)} @n={r['n']}"
    print(f"{label}: well-formed FUNC trace, {len(recs)} records "
          f"(n=0..{ns[-1]}, first pc={recs[0]['pc']}, x87={bool(h.get('x87'))})")
else:  # cycle
    cyc = [r["cyc"] for r in recs]
    assert cyc == sorted(cyc), f"{label}: cyc not non-decreasing"
    for r in recs:
        assert re.fullmatch(r"0x[0-9a-f]{8}", r["pc"]), f"{label}: bad pc {r.get('pc')} @n={r['n']}"
        assert r["pipe"] in ("U", "V", "-"), f"{label}: bad pipe {r.get('pipe')} @n={r['n']}"
        assert isinstance(r["paired"], bool), f"{label}: paired not bool @n={r['n']}"
        assert (r["pipe"] == "V") or (not r["paired"]), f"{label}: paired implies pipe==V @n={r['n']}"
    total = cyc[-1]
    npairs = sum(1 for r in recs if r["paired"])
    cpi = total / len(recs) if recs else 0.0
    print(f"{label}: well-formed CYCLE trace, {len(recs)} records "
          f"(cyc 0..{total}, pairs={npairs}, CPI={cpi:.4f})")
PY
}

# Read a field out of the smoke manifest (pure python, no jq dependency).
manifest_get() {
    "$PYTHON" - "$MANIFEST" "$1" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
print(m[sys.argv[2]])
PY
}

# =============================================================================
say "M0 smoke — sanity check the environment"
[ -x "$QEMU" ]      || die "qemu-i386 not found/executable: $QEMU"
[ -f "$GEN_TRACE" ] || die "gen_trace.py missing: $GEN_TRACE"
[ -f "$COMPARE" ]   || die "compare.py missing: $COMPARE"
[ -f "$MANIFEST" ]  || die "manifest missing: $MANIFEST"
info "repo root : $ROOT"
info "qemu-i386 : $QEMU"
info "build dir : $M0"
mkdir -p "$M0"

# ---- A) smoke test corpus ---------------------------------------------------
say "A) build the smoke test corpus (verif/tests)"
make -C "$TESTS_DIR" || die "smoke corpus build failed"

# Resolve manifest fields (paths are relative to verif/tests).
SMOKE_ELF_REL="$(manifest_get elf)"
SMOKE_FLAT_REL="$(manifest_get image)"
LOAD_ADDR="$(manifest_get load_addr)"
ENTRY="$(manifest_get entry)"
MAX_INSN="$(manifest_get max_insn)"
SMOKE_ELF="$TESTS_DIR/$SMOKE_ELF_REL"
SMOKE_FLAT="$TESTS_DIR/$SMOKE_FLAT_REL"
[ -f "$SMOKE_ELF" ]  || die "smoke ELF not built: $SMOKE_ELF"
[ -f "$SMOKE_FLAT" ] || die "smoke flat image not built: $SMOKE_FLAT"
info "elf       : $SMOKE_ELF"
info "flat      : $SMOKE_FLAT"
info "load/entry: $LOAD_ADDR / $ENTRY"
info "max_insn  : $MAX_INSN"

# ---- B) cycle plugin --------------------------------------------------------
say "B) build the QEMU cycle-trace plugin (verif/qemu-plugins)"
make -C "$ROOT/verif/qemu-plugins" \
    QEMU_SRC="$(realpath "$QEMU_SRC")" \
    CAPSTONE="$(realpath "$CAPSTONE")" \
    || die "p5trace.so build failed"
[ -f "$PLUGIN_SO" ] || die "plugin .so not at expected path: $PLUGIN_SO"
info "plugin    : $PLUGIN_SO"

# ---- C) RTL testbench against the real core ---------------------------------
say "C) build the RTL testbench against rtl/ (verif/tb)"
make -C "$ROOT/verif/tb" || die "RTL testbench build failed"
[ -x "$TB_BIN" ] || die "tb_ventium not built: $TB_BIN"
info "tb_ventium: $TB_BIN"

# ---- D) golden FUNC trace via QEMU gdbstub single-step ----------------------
say "D) generate golden FUNC trace (QEMU gdbstub) -> qemu_func.vtrace"
"$PYTHON" "$GEN_TRACE" \
    --qemu "$QEMU" \
    --elf "$SMOKE_ELF" \
    --out "$QEMU_FUNC" \
    --max-insn "$MAX_INSN" \
    || die "gen_trace.py failed"
validate_vtrace "qemu_func" "$QEMU_FUNC" "qemu-gdbstub" "func" \
    || die "qemu_func.vtrace failed validation"

# ---- E) golden CYCLE trace via the p5trace plugin ---------------------------
say "E) generate golden CYCLE trace (p5trace.so) -> qemu_cycle.vtrace"
# The plugin's out= path is its only required arg; qemu's exit code is the
# guest's _exit() status (the smoke program exits 0), so we don't treat a
# nonzero qemu exit as a plugin failure — we validate the trace instead.
"$QEMU" -cpu pentium \
    -plugin "$PLUGIN_SO,out=$QEMU_CYCLE" \
    "$SMOKE_ELF"
qemu_cyc_rc=$?
info "qemu exit (guest _exit status, informational) = $qemu_cyc_rc"
validate_vtrace "qemu_cycle" "$QEMU_CYCLE" "qemu-plugin" "cycle" \
    || die "qemu_cycle.vtrace failed validation"

# ---- F) RTL FUNC trace ------------------------------------------------------
say "F) run the RTL testbench (M1 integer core) -> rtl_func.vtrace"
# Init ESP: docs/m1-core-spec.md documents 0x40c348d0, but QEMU's linux-user
# initial ESP is environment-dependent (it depends on the argv/env bytes pushed
# onto the guest stack), so the value the golden actually reports varies by
# host. The M1 differential gate compares against THAT golden, so the testbench
# (playing the loader) must establish the SAME ESP. We derive it from the
# golden's first record (n=0) — environment-independent and spec-aligned ("the
# testbench establishes the init state the core latches at reset"). Falls back
# to the documented default if extraction fails.
INIT_ESP="$("$PYTHON" - "$QEMU_FUNC" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        f.readline()                      # header
        print(json.loads(f.readline())["esp"])
except Exception:
    print("0x40c348d0")
PY
)"
info "init ESP (from golden n=0) : $INIT_ESP"
"$TB_BIN" \
    --image "$SMOKE_FLAT" \
    --load "$LOAD_ADDR" \
    --entry "$ENTRY" \
    --init-esp "$INIT_ESP" \
    --out "$RTL_FUNC" \
    --max-insn "$MAX_INSN" \
    || die "tb_ventium run failed"
validate_vtrace "rtl_func" "$RTL_FUNC" "rtl" "func" \
    || die "rtl_func.vtrace failed validation"

# ---- G) compare -------------------------------------------------------------
# Capture the comparator verdict WITHOUT letting its (expected at M0) nonzero
# exit abort the script.
say "G) DIFFERENTIAL COMPARE"

echo "--- FUNC: golden QEMU (A) vs RTL NOP-stub (C) ---"
echo "    \$ python3 verif/diff/compare.py --mode func \\"
echo "        build/m0/qemu_func.vtrace build/m0/rtl_func.vtrace"
set +e
"$PYTHON" "$COMPARE" --mode func "$QEMU_FUNC" "$RTL_FUNC"
FUNC_RC=$?
set -e 2>/dev/null || true
echo "func exit=$FUNC_RC"

echo ""
echo "--- CYCLE: golden plugin trace standalone validation ---"
# At M0 the RTL has NO cycle trace (it only emits func via vtm_retire). A
# cycle-vs-func compare is therefore mode-incompatible (compare.py would exit 2
# on the wrong mode). The cleanest M0 behaviour is: VALIDATE that the golden
# cycle trace is a well-formed cycle .vtrace and report its aggregate (done in
# step E above). We additionally demonstrate compare.py's cycle mode is wired by
# diffing the golden cycle trace against ITSELF (must be EQUIVALENT, exit 0) —
# this proves the cycle path runs end-to-end even though no RTL cycle DUT exists
# yet (the RTL cycle trace lands at M4).
echo "    (RTL has no cycle trace at M0; the cycle comparator path is exercised"
echo "     by self-diffing the golden cycle trace — must be EQUIVALENT.)"
echo "    \$ python3 verif/diff/compare.py --mode cycle \\"
echo "        build/m0/qemu_cycle.vtrace build/m0/qemu_cycle.vtrace"
set +e
"$PYTHON" "$COMPARE" --mode cycle "$QEMU_CYCLE" "$QEMU_CYCLE"
CYCLE_RC=$?
set -e 2>/dev/null || true
echo "cycle exit=$CYCLE_RC"

# ---- verdict ----------------------------------------------------------------
say "M0 RESULT"
info "qemu_func.vtrace  : $QEMU_FUNC"
info "qemu_cycle.vtrace : $QEMU_CYCLE"
info "rtl_func.vtrace   : $RTL_FUNC"
echo ""

# M0 gate logic: all producers well-formed (already asserted by validate_vtrace
# or we'd have die()d). The func comparator MUST run and report a divergence
# (exit 1) against the NOP stub; equivalence (exit 0) would be suspicious at M0
# but is not a hard failure (the stub could coincidentally match a 0-insn case).
# The cycle self-diff must be EQUIVALENT (exit 0).
GATE_OK=1
if [ "$FUNC_RC" -eq 2 ]; then
    echo "M0 GATE: FAIL — func comparator reported MALFORMED (exit 2); traces are"
    echo "         not mode/header-compatible. This is an infrastructure bug."
    GATE_OK=0
elif [ "$FUNC_RC" -eq 1 ]; then
    echo "M0 GATE: PASS — func comparator ran end-to-end and reported a coherent"
    echo "         divergence (exit 1), as EXPECTED against the NOP-stub RTL."
    echo "         (M0 proves the infrastructure, NOT functional correctness."
    echo "          Real functional agreement begins at M1.)"
else  # 0
    echo "M0 GATE: WARN — func comparator reported EQUIVALENT (exit 0). At M0 the"
    echo "         RTL is a NOP stub; a divergence (exit 1) was expected. The"
    echo "         pipeline still ran end-to-end, but inspect the traces."
fi
if [ "$CYCLE_RC" -ne 0 ]; then
    echo "M0 GATE: FAIL — cycle comparator self-diff returned $CYCLE_RC (expected 0)."
    GATE_OK=0
fi

echo ""
if [ "$GATE_OK" -eq 1 ]; then
    echo "M0 SMOKE: OK (infrastructure gate met)."
    exit 0
else
    echo "M0 SMOKE: FAILED (infrastructure gate not met)."
    exit 1
fi
