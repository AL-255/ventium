#!/usr/bin/env bash
# =============================================================================
# verif/run-m4.sh — Ventium M4 cycle-accuracy gate (docs/m4-pipeline-spec.md).
#
# M4 is the FIRST milestone gated on CYCLES. It asserts two things:
#
#   (a) FUNCTIONAL REGRESSION (HARD prerequisite, docs/m4-pipeline-spec.md
#       "Hard safety rule"): `make m1`, `make m2`, `make m3` must ALL exit 0.
#       A dual-issue pipeline that breaks functional equivalence is a regression
#       and FAILS this gate immediately — we never trade architectural
#       correctness for a cycle match.
#
#   (b) CYCLE MICRO-GATE: for each INTEGER microbench (mb_depadd, mb_indepadd,
#       mb_agi, mb_brloop, mb_brrandom — built by the corpus agent under
#       verif/tests/), we generate the p5trace.so GOLDEN cycle trace AND the RTL
#       --cycle trace, run `compare.py --mode cycle --tol-pct T`, AND compute
#       aggregate metrics FROM THE RTL TRACE (CPI, pairing%, AGI-stall rate,
#       mispredict%) and assert the 55-validate-model.sh bands:
#         depadd   : CPI 0.97-1.10 & pairing <2%
#         indepadd : CPI 0.48-0.62 & pairing >40%
#         agi      : AGI 1-cycle stalls fire (a meaningful fraction stall)
#         brloop   : mispredict <2%
#         brrandom : mispredict >20%
#       The emergent-not-faked principle (spec "The core principle"): the bands
#       are computed from the RTL pipeline's OWN emergent cycle trace; only the
#       per-instruction *identity* (is-this-a-branch?) is borrowed from the
#       golden's `bytes` field so the metric knows which records are branches.
#       The CYCLE COSTS are 100% the RTL's. We never reimplement the p5model
#       formula.
#
# faddchain (FP) is run for INFORMATION ONLY (FP cycle accuracy is M5, not
# gated here — docs/m4-pipeline-spec.md "Deferred to M5").
#
# Tolerance T (documented honest choice, spec "Pick a tolerance T that is
# honest"): the RTL pipeline and the p5model analytic estimate need NOT be
# bit-identical cycle-by-cycle. p5model adds an icache cold-miss penalty
# (imiss=8) on the first fetch of each line that the M4 RTL (cache cycle = M5)
# does not model, so absolute cumulative `cyc` totals diverge by a fixed offset;
# what must agree is the STEADY-STATE per-instruction behaviour captured by the
# CPI / pairing / mispredict BANDS. We therefore run compare.py with a generous
# T (default 50%) as a STRUCTURAL SANITY check (pc-alignment, retire-order, no
# wild per-insn blowups) and treat the 55-validate BANDS as the real verdict.
# The bands themselves are tight (e.g. CPI 0.97-1.10) so this is not a loose
# gate — it is the analytically-correct one. Override with M4_TOL_PCT.
#
# Exit 0 ONLY if the functional regression is green AND every integer kernel
# meets its band. Anything else exits 1 (with a per-kernel PASS/FAIL table).
#
# Usage:  bash verif/run-m4.sh    (or: make m4)
# =============================================================================

set -uo pipefail
# No `set -e`: we run every kernel and aggregate verdicts so the per-kernel
# table always prints. Each step's status is captured explicitly.

# ---- locate the repo root (this script lives in <root>/verif) ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- pinned paths (all absolute) --------------------------------------------
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QEMU="$REFS/build/qemu/build/qemu-i386"
ISA_VERIFY="$REFS/tools/isa_verify.py"

COMPARE="$ROOT/verif/diff/compare.py"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"

P5TRACE="$ROOT/build/p5trace.so"          # cycle oracle (QEMU TCG plugin)

TESTS_DIR="$ROOT/verif/tests"
BUILD="$ROOT/build"
M4="$BUILD/m4"
TB_DIR="$ROOT/verif/tb"
TB_BIN="$TB_DIR/obj_dir/tb_ventium"

PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}"

# Tolerance for the structural compare.py --mode cycle pass (see header). The
# REAL verdict is the 55-validate bands, computed from the RTL trace.
M4_TOL_PCT="${M4_TOL_PCT:-50}"

# Toolchain flags (match run-m2/run-m3; -Ttext appended per program).
CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"

# The integer cycle kernels the gate enforces, and the FP kernel run for info.
# Names match the corpus agent's verif/tests/<name>/ microbench programs.
GATED_KERNELS="mb_depadd mb_indepadd mb_agi mb_brloop mb_brrandom"
# INFO kernels are reported but never gate. mb_agiloop is the looped-AGI
# regression for the M4 review fix (the per-PC AGI suppressor was removed so a
# static AGI site inside a loop stalls EVERY iteration); mb_faddchain is FP (M5).
INFO_KERNELS="mb_agiloop mb_faddchain"

# ---- helpers ----------------------------------------------------------------
say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

manifest_get() {  # <manifest> <key>
    "$PYTHON" - "$1" "$2" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
v = m.get(sys.argv[2])
if v is None:
    sys.exit(1)
print(v)
PY
}

# Find the manifest for a kernel name under verif/tests/**/manifest.json whose
# "name" field equals the kernel (the corpus agent owns these). Prints the path.
find_manifest() {  # <kernel-name>
    "$PYTHON" - "$TESTS_DIR" "$1" <<'PY'
import sys, json, glob, os
tests, name = sys.argv[1], sys.argv[2]
for mf in sorted(glob.glob(os.path.join(tests, "*", "manifest.json"))):
    try:
        if json.load(open(mf)).get("name") == name:
            print(mf); break
    except Exception:
        pass
PY
}

# =============================================================================
say "M4 gate — environment sanity"
[ -x "$QEMU" ]       || die "qemu-i386 not found/executable: $QEMU"
[ -f "$P5TRACE" ]    || die "p5trace.so cycle oracle missing: $P5TRACE"
[ -f "$COMPARE" ]    || die "compare.py missing: $COMPARE"
[ -f "$ELF2FLAT" ]   || die "elf2flat.py missing: $ELF2FLAT"
[ -f "$ISA_VERIFY" ] || die "isa_verify.py missing: $ISA_VERIFY"
[ -d "$TESTS_DIR" ]  || die "tests dir missing: $TESTS_DIR"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"
info "repo root : $ROOT"
info "qemu-i386 : $QEMU"
info "p5trace.so: $P5TRACE"
info "build dir : $M4"
info "tol-pct   : $M4_TOL_PCT (structural; bands are the real verdict)"
mkdir -p "$M4"

# =============================================================================
# (a) FUNCTIONAL REGRESSION — hard prerequisite. ALL of m1/m2/m3 must exit 0.
#     We must NOT proceed to (or pass) the cycle gate on a functional
#     regression (docs/m4-pipeline-spec.md "Hard safety rule").
# =============================================================================
say "(a) FUNCTIONAL REGRESSION — make m1 && make m2 && make m3 (must all exit 0)"
FUNC_OK=1
declare -a FUNC_NAMES FUNC_RC
for fg in m1 m2 m3; do
    info "running make $fg ..."
    ( cd "$ROOT" && make "$fg" ) > "$M4/func_${fg}.log" 2>&1
    rc=$?
    FUNC_NAMES+=("$fg"); FUNC_RC+=("$rc")
    if [ "$rc" -eq 0 ]; then
        info "make $fg: exit 0 (PASS) — log: $M4/func_${fg}.log"
    else
        FUNC_OK=0
        info "make $fg: exit $rc (FAIL) — log tail:"
        tail -6 "$M4/func_${fg}.log" | sed 's/^/        /'
    fi
done

# =============================================================================
# (b) CYCLE MICRO-GATE — per integer kernel: golden + RTL cycle traces, compare,
#     and assert the 55-validate bands computed from the RTL trace.
# =============================================================================
say "(b) CYCLE MICRO-GATE — build TB + per-kernel cycle traces"
make -C "$TB_DIR" > "$M4/tb_build.log" 2>&1 || {
    tail -8 "$M4/tb_build.log" | sed 's/^/    /'
    die "RTL testbench build failed (see $M4/tb_build.log)"
}
[ -x "$TB_BIN" ] || die "tb_ventium not built: $TB_BIN"
info "tb_ventium: $TB_BIN"

# Per-kernel run. Builds the ELF (from the corpus manifest), generates the
# golden cycle vtrace via p5trace.so, the RTL cycle vtrace via tb --cycle, runs
# compare.py --mode cycle, then computes RTL-trace metrics + checks the band.
declare -a K_NAME K_VERD K_CPI K_PAIR K_EXTRA K_BAND K_CMP

# run_kernel <name> <gated:1|0>
run_kernel() {
    local NAME="$1" GATED="$2"
    local MF SRC_REL LOAD ENTRY MAX SRC ELF FLAT GOLD RTL CMP MET INIT_ESP

    MF="$(find_manifest "$NAME")"
    if [ -z "$MF" ]; then
        K_NAME+=("$NAME"); K_VERD+=("MISSING"); K_CPI+=("-"); K_PAIR+=("-")
        K_EXTRA+=("-"); K_BAND+=("no verif/tests/*/manifest.json name=$NAME"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi
    SRC_REL="$(manifest_get "$MF" src)"     || SRC_REL=""
    LOAD="$(manifest_get "$MF" load_addr)"  || LOAD=""
    ENTRY="$(manifest_get "$MF" entry)"     || ENTRY=""
    MAX="$(manifest_get "$MF" max_insn)"    || MAX=""
    SRC="$TESTS_DIR/$SRC_REL"

    ELF="$M4/${NAME}.elf"; FLAT="$M4/${NAME}.flat"
    GOLD="$M4/${NAME}_gold.vtrace"; RTL="$M4/${NAME}_rtl.vtrace"
    CMP="$M4/${NAME}_cmp.txt";      MET="$M4/${NAME}_metrics.txt"

    say "KERNEL: $NAME$([ "$GATED" = "1" ] || echo '  (INFO only — FP, M5)')"
    if [ -z "$SRC_REL" ] || [ -z "$LOAD" ] || [ -z "$ENTRY" ] || [ -z "$MAX" ] || [ ! -f "$SRC" ]; then
        info "manifest incomplete or src missing ($SRC_REL)"
        K_NAME+=("$NAME"); K_VERD+=("FAIL"); K_CPI+=("-"); K_PAIR+=("-")
        K_EXTRA+=("-"); K_BAND+=("manifest/src incomplete"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi
    info "src=$SRC  load/entry=$LOAD/$ENTRY  max_insn=$MAX"

    # 1) build ELF, ISA-check (pure P5), flatten.
    if ! "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$M4/${NAME}_build.log"; then
        info "gcc build failed:"; sed 's/^/      /' "$M4/${NAME}_build.log" | head -6
        K_NAME+=("$NAME"); K_VERD+=("FAIL"); K_CPI+=("-"); K_PAIR+=("-")
        K_EXTRA+=("-"); K_BAND+=("ELF build failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi
    "$PYTHON" "$ISA_VERIFY" "$ELF" > "$M4/${NAME}_isa.log" 2>&1 || {
        info "isa_verify rejected ELF (non-P5 ISA):"; sed 's/^/      /' "$M4/${NAME}_isa.log" | head -6
        K_NAME+=("$NAME"); K_VERD+=("FAIL"); K_CPI+=("-"); K_PAIR+=("-")
        K_EXTRA+=("-"); K_BAND+=("isa_verify failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    }
    "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" > "$M4/${NAME}_flat.log" 2>&1 || {
        info "elf2flat failed:"; sed 's/^/      /' "$M4/${NAME}_flat.log" | head -6
        K_NAME+=("$NAME"); K_VERD+=("FAIL"); K_CPI+=("-"); K_PAIR+=("-")
        K_EXTRA+=("-"); K_BAND+=("elf2flat failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    }

    # 2) GOLDEN cycle vtrace via the p5trace.so plugin (the cycle oracle). FAST
    #    (no gdbstub). --max-insn caps the stream so RTL & golden see the same N.
    if ! "$QEMU" -cpu pentium -plugin "$P5TRACE,out=$GOLD" "$ELF" \
            > "$M4/${NAME}_gold.log" 2>&1; then
        info "p5trace golden generation failed:"; sed 's/^/      /' "$M4/${NAME}_gold.log" | head -6
        K_NAME+=("$NAME"); K_VERD+=("FAIL"); K_CPI+=("-"); K_PAIR+=("-")
        K_EXTRA+=("-"); K_BAND+=("p5trace golden failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi

    # init ESP = the loader-established value the func golden reports at n=0, so
    # the RTL stack-relative behaviour matches. Reuse the FUNCTIONAL gdbstub
    # golden the func gates already produced under build/m2 if present; else fall
    # back to the spec default (cycle behaviour is insensitive to the exact ESP).
    INIT_ESP="0x40c34910"
    for cand in "$BUILD/m2/${NAME}_qemu.vtrace" "$BUILD/m3/${NAME}_qemu.vtrace"; do
        if [ -f "$cand" ]; then
            v="$("$PYTHON" - "$cand" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        f.readline(); print(json.loads(f.readline())["esp"])
except Exception:
    pass
PY
)"
            [ -n "$v" ] && INIT_ESP="$v" && break
        fi
    done
    info "init ESP : $INIT_ESP"

    # 3) RTL cycle vtrace via tb_ventium --cycle. --max-insn matches the golden's
    #    record count so compare.py aligns by n over the whole stream.
    GN="$("$PYTHON" - "$GOLD" <<'PY'
import sys
try:
    with open(sys.argv[1]) as f:
        print(max(0, sum(1 for _ in f) - 1))   # records = lines - header
except Exception:
    print(0)
PY
)"
    info "golden records : $GN"
    if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp "$INIT_ESP" --cycle --out "$RTL" \
            --max-insn "$GN" --max-cycles 80000000 \
            > "$M4/${NAME}_rtl.log" 2>&1; then
        info "tb_ventium --cycle run failed:"; sed 's/^/      /' "$M4/${NAME}_rtl.log" | head -6
        K_NAME+=("$NAME"); K_VERD+=("FAIL"); K_CPI+=("-"); K_PAIR+=("-")
        K_EXTRA+=("-"); K_BAND+=("tb --cycle run failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi

    # 4) STRUCTURAL compare (pc-alignment / retire-order / per-insn sanity).
    #    compare.py --mode cycle returns 1 for EITHER a control-flow/retire-order
    #    mismatch (the RTL executed a DIFFERENT instruction stream — a HARD fail
    #    that no cycle band can excuse) OR merely cyc out-of-tolerance (EXPECTED:
    #    p5model adds an icache cold-miss the M4 RTL does not model, so absolute
    #    cumulative cyc differs by a fixed offset). We must distinguish the two:
    #    a control-flow divergence fails the kernel regardless of the band; an
    #    out-of-tolerance-only result is non-fatal and the band is the verdict.
    "$PYTHON" "$COMPARE" --mode cycle --tol-pct "$M4_TOL_PCT" "$GOLD" "$RTL" > "$CMP" 2>&1
    local CRC=$?
    local CMPVERD="exit=$CRC"
    local CTRL_DIVERGE=0
    if grep -q "control-flow / retire-order mismatch" "$CMP" 2>/dev/null; then
        CTRL_DIVERGE=1
        CMPVERD="exit=$CRC (CONTROL-FLOW DIVERGENCE)"
    fi

    # 5) BAND metrics — computed from the RTL trace (CPI, pairing%) plus the
    #    branch/AGI identity borrowed from the golden's bytes (emergent costs are
    #    100% RTL). Prints "VERDICT|CPI|PAIR|EXTRA|DETAIL" for this kernel/band.
    local LINE
    LINE="$("$PYTHON" "$ROOT/verif/m4_metrics.py" \
                --kernel "$NAME" --rtl "$RTL" --golden "$GOLD" 2> "$MET")"
    if [ -z "$LINE" ]; then
        info "metrics computation failed (see $MET):"; sed 's/^/      /' "$MET" | head -6
        K_NAME+=("$NAME"); K_VERD+=("FAIL"); K_CPI+=("-"); K_PAIR+=("-")
        K_EXTRA+=("-"); K_BAND+=("metrics failed"); K_CMP+=("$CMPVERD")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi

    local VERD CPI PAIR EXTRA DETAIL
    IFS='|' read -r VERD CPI PAIR EXTRA DETAIL <<< "$LINE"
    info "CPI=$CPI  pairing%=$PAIR  $EXTRA"
    info "band: $DETAIL"
    info "compare --mode cycle: $CMPVERD (structural, tol=$M4_TOL_PCT%)"

    # A control-flow / retire-order divergence means the RTL executed a DIFFERENT
    # stream than the golden: the cycle band is meaningless, so force FAIL.
    if [ "$CTRL_DIVERGE" = "1" ] && [ "$VERD" = "PASS" ]; then
        VERD="FAIL"
        DETAIL="control-flow divergence vs golden (RTL ran a different stream); $DETAIL"
    fi

    K_NAME+=("$NAME"); K_CPI+=("$CPI"); K_PAIR+=("$PAIR"); K_EXTRA+=("$EXTRA")
    K_BAND+=("$DETAIL"); K_CMP+=("$CMPVERD")
    if [ "$GATED" = "1" ]; then
        K_VERD+=("$VERD")
        [ "$VERD" = "PASS" ] || CYCLE_OK=0
    else
        K_VERD+=("INFO")   # faddchain: reported, never gates
    fi
}

CYCLE_OK=1
for k in $GATED_KERNELS; do run_kernel "$k" 1; done
for k in $INFO_KERNELS;  do run_kernel "$k" 0; done

# =============================================================================
# RESULT TABLES
# =============================================================================
say "M4 RESULT — functional regression (HARD prerequisite)"
printf '    %-6s %s\n' "GATE" "RESULT"
printf '    %-6s %s\n' "----" "------"
for ((i=0; i<${#FUNC_NAMES[@]}; i++)); do
    if [ "${FUNC_RC[$i]}" -eq 0 ]; then r="PASS (exit 0)"; else r="FAIL (exit ${FUNC_RC[$i]})"; fi
    printf '    %-6s %s\n' "${FUNC_NAMES[$i]}" "$r"
done

say "M4 RESULT — integer cycle micro-gate (per kernel vs 55-validate bands)"
printf '    %-13s %-7s %-8s %-9s %-22s %s\n' \
    "KERNEL" "RESULT" "CPI" "PAIR%" "EXTRA" "BAND"
printf '    %-13s %-7s %-8s %-9s %-22s %s\n' \
    "------" "------" "---" "-----" "-----" "----"
for ((i=0; i<${#K_NAME[@]}; i++)); do
    printf '    %-13s %-7s %-8s %-9s %-22s %s\n' \
        "${K_NAME[$i]}" "${K_VERD[$i]}" "${K_CPI[$i]}" "${K_PAIR[$i]}" \
        "${K_EXTRA[$i]}" "${K_BAND[$i]}"
done
echo ""

# =============================================================================
# VERDICT — exit 0 ONLY if functional regression green AND every gated kernel
# meets its band.
# =============================================================================
if [ "$FUNC_OK" -ne 1 ]; then
    echo "M4 GATE: FAIL — FUNCTIONAL REGRESSION (m1/m2/m3 not all green)."
    echo "         Cycle results above are informational; a functional"
    echo "         regression FAILS M4 regardless of cycle bands (hard safety)."
    exit 1
fi
if [ "$CYCLE_OK" -ne 1 ]; then
    echo "M4 GATE: FAIL — functional regression GREEN, but at least one integer"
    echo "         cycle kernel missed its 55-validate band (see table above)."
    echo "         (If the pipeline core is not yet driving vtm_retire_cycle this"
    echo "          is EXPECTED — the cycle infra is in place; the bands turn"
    echo "          green once the real U/V pipeline lands.)"
    exit 1
fi
echo "M4 GATE: PASS — functional regression GREEN and every integer cycle"
echo "         kernel meets its 55-validate band (emergent from the RTL pipeline)."
echo "         (faddchain FP cycle is INFO-only, deferred to M5.)"
exit 0
