#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# =============================================================================
# run-fpu87-gate.sh — thorough x87 FPU differential gate (random + corner cases).
#
# Pipeline:
#   1. build the SoftFloat oracle + (optional) qref transcendental oracle.
#   2. generate random + denormal/special test programs (gen_fpu87.py).
#   3. build the RTL testbench once.
#   4. per program, in parallel: QEMU golden --x87, RTL --x87, compare.py func
#      (AUTHORITATIVE RTL<->QEMU), and xcheck.py (oracle<->QEMU triangulation).
#   5. aggregate. GATE = every GATED (core, non-transcendental) program is
#      func-equivalent vs QEMU AND its QEMU golden matches the oracle. UNSUP
#      (x87 unsupported-operand) and transcendental programs are INFORMATIONAL.
#
# Usage:  bash verif/fpu87/run-fpu87-gate.sh [profile] [seed]
#   profile : smoke | default | thorough     (default: default)
#   seed    : integer RNG seed                (default: 24309)
# Env:
#   FPU87_JOBS    parallel workers (default 1; explicit overrides remain
#                 contained by the enclosing resource scope)
#   FPU87_OPS     comma list to restrict ops (e.g. add,sub,mul,div)
#   FPU87_PORTBASE  gdbstub port base (default 27000)
#   NO_TRANS=1    skip transcendental programs
# =============================================================================
set -uo pipefail
PROFILE="${1:-default}"
SEED="${2:-24309}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# The randomized gate runs every worker with its own QEMU/Python/RTL process
# tree.  Keep the entire fan-out in the project resource scope, not just the
# one Verilator invocation that builds the TB.
if [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" != "1" ]; then
    exec "$ROOT/tools/build_scope.sh" -- "$0" "$@"
fi
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"

export QEMU="$REFS/build/qemu/build/qemu-i386"
export ISA_VERIFY="$REFS/tools/isa_verify.py"
export GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
export COMPARE="$ROOT/verif/diff/compare.py"
export ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
export TB_BIN="$ROOT/verif/tb/obj_dir/tb_ventium"
export XCHECK="$HERE/xcheck.py"
export PYTHON="${PYTHON:-python3}"
export CC="${CC:-gcc}"
export CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
export LOAD="0x08048000"
export PORTBASE="${FPU87_PORTBASE:-27000}"

ORACLE="$HERE/build/ven_fpu_oracle"
QREF="$ROOT/tools/p5xtrans/qref"
TF_GEN="$HERE/build/testfloat/testfloat_gen"
GENDIR="$HERE/build/gen-$PROFILE"
export GENDIR
export WORKDIR="$HERE/build/work-$PROFILE"
WORKER="$HERE/fpu87_worker.sh"

JOBS="${FPU87_JOBS:-1}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: FPU87_JOBS must be a positive integer" >&2; exit 2; }

say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "fpu87 gate — profile=$PROFILE seed=$SEED"
[ -x "$QEMU" ]      || die "qemu-i386 not found: $QEMU"
[ -f "$GEN_TRACE" ] || die "gen_trace.py missing"
[ -f "$COMPARE" ]   || die "compare.py missing"

# ---- 1) build oracles -------------------------------------------------------
say "build oracles (SoftFloat + qref)"
make -C "$HERE" oracle > "$HERE/build/oracle_build.log" 2>&1 || {
    tail -15 "$HERE/build/oracle_build.log" | sed 's/^/    /'; die "oracle build failed"; }
info "softfloat oracle : $ORACLE"
NO_TRANS="${NO_TRANS:-0}"
QREF_ARG=()
if [ "$NO_TRANS" != 1 ]; then
    if make -C "$HERE" qref > "$HERE/build/qref_build.log" 2>&1 && [ -x "$QREF" ]; then
        QREF_ARG=(--qref "$QREF"); info "qref oracle      : $QREF"
    else
        info "qref build failed -> transcendentals disabled"; NO_TRANS=1
    fi
fi
# Berkeley TestFloat corner-case inputs (optional; NO_TESTFLOAT=1 to skip).
TF_ARG=()
if [ "${NO_TESTFLOAT:-0}" != 1 ]; then
    if make -C "$HERE" testfloat > "$HERE/build/testfloat_build.log" 2>&1 && [ -x "$TF_GEN" ]; then
        TF_ARG=(--testfloat-gen "$TF_GEN" --testfloat-level "${TF_LEVEL:-1}")
        info "testfloat_gen    : $TF_GEN (level ${TF_LEVEL:-1})"
    else
        info "testfloat build failed -> TestFloat inputs disabled"
    fi
fi

# ---- 2) generate ------------------------------------------------------------
say "generate test corpus -> $GENDIR"
rm -rf "$GENDIR"
GEN_ARGS=(--out "$GENDIR" --oracle "$ORACLE" --profile "$PROFILE" --seed "$SEED")
[ -n "${FPU87_OPS:-}" ] && GEN_ARGS+=(--ops "$FPU87_OPS")
[ "$NO_TRANS" = 1 ] && GEN_ARGS+=(--no-transcendental)
"$PYTHON" "$HERE/gen_fpu87.py" "${GEN_ARGS[@]}" "${QREF_ARG[@]}" "${TF_ARG[@]}" 2> "$HERE/build/gen.log"
tail -3 "$HERE/build/gen.log" | sed 's/^/    /'
[ -f "$GENDIR/index.json" ] || die "generation produced no index.json"

# ---- 3) build the RTL testbench once ----------------------------------------
say "build RTL testbench once (verif/tb)"
mkdir -p "$WORKDIR"; rm -f "$WORKDIR"/*.result 2>/dev/null
make -C "$ROOT/verif/tb" > "$WORKDIR/tb_build.log" 2>&1 || {
    tail -12 "$WORKDIR/tb_build.log" | sed 's/^/    /'; die "tb build failed"; }
[ -x "$TB_BIN" ] || die "tb_ventium not built"
info "tb_ventium : $TB_BIN"

# ---- 4) parallel per-program execution --------------------------------------
JOBFILE="$WORKDIR/jobs.txt"
"$PYTHON" - "$GENDIR/index.json" > "$JOBFILE" <<'PY'
import sys, json
idx = json.load(open(sys.argv[1]))
for i, p in enumerate(idx["programs"]):
    print("\t".join(str(x) for x in (
        p["name"], p["dir"], 1 if p["gating"] else 0,
        1 if p.get("trans") else 0, p["max_insn"], i)))
PY
NPROG="$(wc -l < "$JOBFILE")"
say "run $NPROG programs across $JOBS workers"
RUN_START=$(date +%s)
# shellcheck disable=SC2016
< "$JOBFILE" xargs -P "$JOBS" -I{} -d '\n' bash -c '
    IFS=$'"'"'\t'"'"' read -r name dir gating trans max idx <<< "{}"
    bash "$0" "$name" "$dir" "$gating" "$trans" "$max" "$idx"
' "$WORKER"
RUN_SECS=$(( $(date +%s) - RUN_START ))
info "parallel phase: ${RUN_SECS}s"

# ---- 5) aggregate -----------------------------------------------------------
say "RESULTS"
"$PYTHON" - "$WORKDIR" "$GENDIR/index.json" <<'PY'
import sys, json, os, glob
W, idxpath = sys.argv[1], sys.argv[2]
progs = {p["name"]: p for p in json.load(open(idxpath))["programs"]}

rows = []
for name in progs:
    rf = os.path.join(W, name + ".result")
    if not os.path.isfile(rf):
        rows.append((name, "1" if progs[name]["gating"] else "0",
                     "0", "MISSING", "-", "no result file")); continue
    parts = open(rf).read().strip().split("|")
    # FPU|name|gating|trans|rtlverd|xjson|detail
    rows.append((parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]))

def xstat(xjson):
    if not xjson or xjson == "-":
        return (0, 0, 0)
    try:
        o = json.loads(xjson)
        return (o.get("checked", 0), o.get("matched", 0), o.get("mismatched", 0))
    except Exception:
        return (0, 0, 0)

gate_fail = 0
gated = ungated = 0
tot_chk = tot_match = tot_mis = 0
print("    %-26s %-5s %-9s %-22s %s" % ("PROGRAM", "GATE", "RTLvsQEMU", "ORACLEvsQEMU", "DETAIL"))
print("    %-26s %-5s %-9s %-22s %s" % ("-------", "----", "---------", "------------", "------"))
for (name, gating, trans, rtl, xjson, detail) in sorted(rows):
    chk, match, mis = xstat(xjson)
    tot_chk += chk; tot_match += match; tot_mis += mis
    orc = "%d/%d ok" % (match, chk) + (" %d MISMATCH" % mis if mis else "")
    g = (gating == "1")
    if g: gated += 1
    else: ungated += 1
    bad = g and (rtl != "PASS" or mis > 0)
    if bad: gate_fail += 1
    tag = "GATE" if g else "info"
    mark = "FAIL" if bad else ("ok" if (rtl in ("PASS","RTLSKIP") and mis == 0) else "  ")
    print("    %-26s %-5s %-9s %-22s %s" % (name, tag, rtl, orc, detail))

print()
print("    gated programs   : %d   informational : %d" % (gated, ungated))
print("    oracle xcheck    : %d/%d st0 results match QEMU (mismatch %d)"
      % (tot_match, tot_chk, tot_mis))
print()
if gate_fail:
    print("FPU87 GATE: FAIL — %d gated program(s) diverged (RTL!=QEMU or QEMU!=oracle)." % gate_fail)
    sys.exit(1)
print("FPU87 GATE: PASS — every gated program is func-equivalent vs QEMU and the")
print("            QEMU golden matches the independent SoftFloat oracle on st0.")
sys.exit(0)
PY
