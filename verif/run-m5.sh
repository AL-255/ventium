#!/usr/bin/env bash
# =============================================================================
# verif/run-m5.sh — Ventium M5 cycle-accuracy gate (docs/m5-cycle-spec.md).
#
# M5 extends the M4 cycle model with the two pieces M4 deferred and that the
# p5model oracle CAN differentially verify:
#   (1) L1 cache-miss cycle timing  (I$/D$ hit/miss SM, imiss=8/dmiss=8, 8KB/
#       2-way/32B — the SAME geometry/penalty p5trace.so uses), and
#   (2) x87/FP cycle accuracy        (real FP latency/throughput pipe, replacing
#       the M4 serialize-stall).
# The pin-level 64-bit bus protocol has NO differential oracle and is DEFERRED
# to M5B (docs/m5-cycle-spec.md "Deferred to M5B") — this gate does not build or
# check it.
#
# The gate asserts, in order:
#
#   (a) FUNCTIONAL REGRESSION (HARD prerequisite): `make m1`, `make m2`,
#       `make m3` must ALL exit 0. Cache + FP timing change ONLY cycle
#       accounting (stalls), never architectural results, so functional
#       equivalence is preserved BY CONSTRUCTION — but we verify it. A
#       functional regression FAILS M5 regardless of any cycle band.
#
#   (b) M4 INTEGER BANDS (HARD prerequisite): re-run the five M4 integer kernels
#       (mb_depadd/indepadd/agi/brloop/brrandom) and require their 55-validate
#       bands STILL met from the now-cache-aware RTL — adding cache/FP timing
#       must not regress the integer cycle model. The bands are computed by
#       m5_metrics.py, which delegates verbatim to m4_metrics.compute() for the
#       integer kernels (no re-derivation).
#
#   (c) NEW M5 BANDS:
#         mb_faddchain : dependent `fadd %st(1),%st` chain -> CPI ~ 3.0 (fadd
#                        latency 3). GATED in M5 (promoted from M4 INFO). Band
#                        2.7-3.3. Emergent from the RTL FP latency pipe.
#         mb_fpindep   : independent FP ops pipeline (tput 1) -> CPI BELOW the
#                        faddchain CPI (latency<->throughput contrast). GATED.
#         mb_dmiss     : strided D-cache-miss kernel -> miss-driven CPI
#                        elevation AND abs-cyc tracks the p5model golden within
#                        the tightened tolerance. GATED.
#         mb_imiss     : I-cache-miss kernel (lines/loop > 8 KB) -> same two
#                        checks. GATED.
#
#   (d) ABS-CYC TIGHTENED REPORT: with cache timing modeled, the integer
#       kernels' total `cyc` is reported vs the p5model golden under the
#       tightened M5_TOL_PCT (target <= ~10%; the achieved figure is printed
#       honestly — the oracle is an ESTIMATE, two estimates need not be
#       identical; structural fidelity is the goal).
#
# Tolerance (HONEST choice, docs/m5-cycle-spec.md item 5): M5_TOL_PCT defaults
# to 10% — TIGHTER than M4's 50% structural pass. Rationale: M4 ran 50% only to
# absorb the un-modeled I-cache cold miss; the measured M4 integer gap vs golden
# was already only ~3% (depadd +3.3%, indepadd +7.0%, agi +3.2%, brloop +0.1%,
# brrandom +4.9%). Once M5 models the SAME caches + FP timing the absolute
# totals converge further, so 10% is a tight-but-honest band that the structure
# must hit while still acknowledging that p5model's miss penalty is an
# *assumption* (not a documented P5 constant) — we do NOT claim bit-exact
# silicon timing. Override with M5_TOL_PCT.
#
# Exit 0 ONLY if functional regression GREEN, AND every M4 integer band met,
# AND every new M5 band met. Anything else exits 1 (with per-kernel tables).
#
# Usage:  bash verif/run-m5.sh    (or: make m5)
# =============================================================================

set -uo pipefail
# No `set -e`: run every kernel, aggregate verdicts, always print the tables.

# ---- locate the repo root (this script lives in <root>/verif) ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- pinned paths (all absolute) --------------------------------------------
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QEMU="$REFS/build/qemu/build/qemu-i386"
ISA_VERIFY="$REFS/tools/isa_verify.py"

COMPARE="$ROOT/verif/diff/compare.py"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"

P5TRACE="$ROOT/build/p5trace.so"          # cycle oracle (QEMU TCG plugin)

TESTS_DIR="$ROOT/verif/tests"
BUILD="$ROOT/build"
M5="$BUILD/m5"
TB_DIR="$ROOT/verif/tb"
TB_BIN="$TB_DIR/obj_dir/tb_ventium"

M5_METRICS="$ROOT/verif/m5_metrics.py"

PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}"

# Tightened M5 tolerance (see header). Used BOTH for the structural compare.py
# pass AND, via m5_metrics --abs-tol-pct, for the abs-cyc band on the miss
# kernels and the integer abs-cyc report.
M5_TOL_PCT="${M5_TOL_PCT:-10}"

# Toolchain flags (match run-m2/m3/m4; -Ttext appended per program).
CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"

# Integer kernels (M4 bands, HARD prereq), and the new M5 kernels (GATED).
M4_INT_KERNELS="mb_depadd mb_indepadd mb_agi mb_brloop mb_brrandom"
# Order matters: faddchain BEFORE fpindep so we can pass faddchain's measured
# CPI to the fpindep relation check (M5_FADDCHAIN_CPI env).
M5_FP_KERNELS="mb_faddchain mb_fpindep"
M5_CACHE_KERNELS="mb_dmiss mb_imiss"
M5_DIV_KERNELS="mb_div8 mb_div16 mb_div32 mb_idiv32"
M5_MUL_KERNELS="mb_mul mb_imul2"
M5_PAIR_KERNELS="mb_accimm mb_rmimm mb_sh1"
# INFO kernels: reported, never gate.
INFO_KERNELS="mb_agiloop"

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
say "M5 gate — environment sanity"
[ -x "$QEMU" ]       || die "qemu-i386 not found/executable: $QEMU"
[ -f "$P5TRACE" ]    || die "p5trace.so cycle oracle missing: $P5TRACE"
[ -f "$COMPARE" ]    || die "compare.py missing: $COMPARE"
[ -f "$ELF2FLAT" ]   || die "elf2flat.py missing: $ELF2FLAT"
[ -f "$ISA_VERIFY" ] || die "isa_verify.py missing: $ISA_VERIFY"
[ -f "$M5_METRICS" ] || die "m5_metrics.py missing: $M5_METRICS"
[ -d "$TESTS_DIR" ]  || die "tests dir missing: $TESTS_DIR"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"
info "repo root : $ROOT"
info "qemu-i386 : $QEMU"
info "p5trace.so: $P5TRACE  (imiss=8,dmiss=8,cache=1, 8KB/2-way/32B)"
info "build dir : $M5"
info "tol-pct   : $M5_TOL_PCT (tightened vs M4 50%; bands are the real verdict)"
mkdir -p "$M5"

# =============================================================================
# (a) FUNCTIONAL REGRESSION — hard prerequisite. ALL of m1/m2/m3 must exit 0.
#     Cache/FP timing must NEVER regress architectural correctness.
# =============================================================================
say "(a) FUNCTIONAL REGRESSION — make m1 && make m2 && make m3 (must all exit 0)"
FUNC_OK=1
declare -a FUNC_NAMES FUNC_RC
for fg in m1 m2 m3; do
    info "running make $fg ..."
    ( cd "$ROOT" && make "$fg" ) > "$M5/func_${fg}.log" 2>&1
    rc=$?
    FUNC_NAMES+=("$fg"); FUNC_RC+=("$rc")
    if [ "$rc" -eq 0 ]; then
        info "make $fg: exit 0 (PASS) — log: $M5/func_${fg}.log"
    else
        FUNC_OK=0
        info "make $fg: exit $rc (FAIL) — log tail:"
        tail -6 "$M5/func_${fg}.log" | sed 's/^/        /'
    fi
done

# =============================================================================
# CYCLE MICRO-GATE — build TB, then per-kernel golden + RTL cycle traces.
# =============================================================================
say "CYCLE MICRO-GATE — build TB + per-kernel cycle traces"
make -C "$TB_DIR" > "$M5/tb_build.log" 2>&1 || {
    tail -8 "$M5/tb_build.log" | sed 's/^/    /'
    die "RTL testbench build failed (see $M5/tb_build.log)"
}
[ -x "$TB_BIN" ] || die "tb_ventium not built: $TB_BIN"
info "tb_ventium: $TB_BIN"

# Result arrays (one row per kernel). CLASS = INT / FP / CACHE / INFO.
declare -a K_NAME K_CLASS K_VERD K_CPI K_PAIR K_EXTRA K_BAND K_CMP K_ABS

# Captured faddchain CPI for the fpindep relation check.
FADDCHAIN_CPI=""

# run_kernel <name> <class:INT|FP|CACHE|INFO> <gated:1|0>
run_kernel() {
    local NAME="$1" CLASS="$2" GATED="$3"
    local MF SRC_REL LOAD ENTRY MAX X87 SRC ELF FLAT GOLD RTL CMP MET INIT_ESP

    MF="$(find_manifest "$NAME")"
    if [ -z "$MF" ]; then
        K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_VERD+=("MISSING")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_ABS+=("-")
        K_BAND+=("no verif/tests/*/manifest.json name=$NAME (corpus agent owns it)")
        K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        say "KERNEL: $NAME  ($CLASS) — MISSING manifest (corpus agent not landed yet)"
        return
    fi
    SRC_REL="$(manifest_get "$MF" src)"     || SRC_REL=""
    LOAD="$(manifest_get "$MF" load_addr)"  || LOAD=""
    ENTRY="$(manifest_get "$MF" entry)"     || ENTRY=""
    MAX="$(manifest_get "$MF" max_insn)"    || MAX=""
    X87="$(manifest_get "$MF" x87)"         || X87="false"
    SRC="$TESTS_DIR/$SRC_REL"

    ELF="$M5/${NAME}.elf"; FLAT="$M5/${NAME}.flat"
    GOLD="$M5/${NAME}_gold.vtrace"; RTL="$M5/${NAME}_rtl.vtrace"
    CMP="$M5/${NAME}_cmp.txt";      MET="$M5/${NAME}_metrics.txt"

    say "KERNEL: $NAME  ($CLASS$([ "$GATED" = "1" ] && echo ', GATED' || echo ', INFO'))"
    if [ -z "$SRC_REL" ] || [ -z "$LOAD" ] || [ -z "$ENTRY" ] || [ -z "$MAX" ] || [ ! -f "$SRC" ]; then
        info "manifest incomplete or src missing ($SRC_REL)"
        K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_ABS+=("-")
        K_BAND+=("manifest/src incomplete"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi
    info "src=$SRC  load/entry=$LOAD/$ENTRY  max_insn=$MAX  x87=$X87"

    # FP kernels need the --x87 flag on BOTH producers so x87 state is tracked.
    local QEMU_X87FLAG="" TB_X87FLAG=""
    if [ "$X87" = "True" ] || [ "$X87" = "true" ] || [ "$CLASS" = "FP" ]; then
        TB_X87FLAG="--x87"
        # p5trace.so emits x87-aware cycle records when the plugin sees FP; no
        # extra QEMU arg is needed for the plugin, but harmless to note.
    fi

    # 1) build ELF, ISA-check (pure P5), flatten.
    if ! "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$M5/${NAME}_build.log"; then
        info "gcc build failed:"; sed 's/^/      /' "$M5/${NAME}_build.log" | head -6
        K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_ABS+=("-")
        K_BAND+=("ELF build failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi
    "$PYTHON" "$ISA_VERIFY" "$ELF" > "$M5/${NAME}_isa.log" 2>&1 || {
        info "isa_verify rejected ELF (non-P5 ISA):"; sed 's/^/      /' "$M5/${NAME}_isa.log" | head -6
        K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_ABS+=("-")
        K_BAND+=("isa_verify failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    }
    "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" > "$M5/${NAME}_flat.log" 2>&1 || {
        info "elf2flat failed:"; sed 's/^/      /' "$M5/${NAME}_flat.log" | head -6
        K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_ABS+=("-")
        K_BAND+=("elf2flat failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    }

    # 2) GOLDEN cycle vtrace via p5trace.so (the cycle oracle). FAST (no gdbstub).
    if ! "$QEMU" -cpu pentium -plugin "$P5TRACE,out=$GOLD" "$ELF" \
            > "$M5/${NAME}_gold.log" 2>&1; then
        info "p5trace golden generation failed:"; sed 's/^/      /' "$M5/${NAME}_gold.log" | head -6
        K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_ABS+=("-")
        K_BAND+=("p5trace golden failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi

    # init ESP — reuse the functional gdbstub golden's n=0 esp if present, else
    # the spec default (cycle behaviour is insensitive to the exact ESP).
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

    # 3) RTL cycle vtrace via tb_ventium --cycle. --max-insn matches golden's
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
            --init-esp "$INIT_ESP" --cycle $TB_X87FLAG --out "$RTL" \
            --max-insn "$GN" --max-cycles 80000000 \
            > "$M5/${NAME}_rtl.log" 2>&1; then
        info "tb_ventium --cycle run failed:"; sed 's/^/      /' "$M5/${NAME}_rtl.log" | head -6
        K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_ABS+=("-")
        K_BAND+=("tb --cycle run failed"); K_CMP+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi

    # 4) STRUCTURAL compare (pc-alignment / retire-order / per-insn sanity), now
    #    at the TIGHTENED tolerance. A control-flow / retire-order mismatch means
    #    the RTL ran a DIFFERENT stream — a HARD fail no cycle band can excuse.
    "$PYTHON" "$COMPARE" --mode cycle --tol-pct "$M5_TOL_PCT" "$GOLD" "$RTL" > "$CMP" 2>&1
    local CRC=$?
    local CMPVERD="exit=$CRC"
    local CTRL_DIVERGE=0
    if grep -q "control-flow / retire-order mismatch" "$CMP" 2>/dev/null; then
        CTRL_DIVERGE=1
        CMPVERD="exit=$CRC (CONTROL-FLOW DIVERGENCE)"
    fi
    # Pull the abs-cyc diff line from the compare summary for the table.
    local ABSLINE
    ABSLINE="$(grep -m1 "total cycles:" "$CMP" 2>/dev/null | sed 's/^[[:space:]]*//')"

    # 5) M5 BAND metrics — computed from the RTL trace by m5_metrics.py
    #    (integer kernels delegate to m4_metrics; FP/cache use M5 bands). The
    #    faddchain CPI is exported so fpindep's relation check can use it.
    local LINE
    LINE="$(M5_FADDCHAIN_CPI="$FADDCHAIN_CPI" "$PYTHON" "$M5_METRICS" \
                --kernel "$NAME" --rtl "$RTL" --golden "$GOLD" \
                --abs-tol-pct "$M5_TOL_PCT" 2> "$MET")"
    if [ -z "$LINE" ]; then
        info "metrics computation failed (see $MET):"; sed 's/^/      /' "$MET" | head -6
        K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_ABS+=("$ABSLINE")
        K_BAND+=("metrics failed"); K_CMP+=("$CMPVERD")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        return
    fi

    local VERD CPI PAIR EXTRA DETAIL
    IFS='|' read -r VERD CPI PAIR EXTRA DETAIL <<< "$LINE"
    info "CPI=$CPI  pairing%=$PAIR  $EXTRA"
    info "band: $DETAIL"
    info "compare --mode cycle: $CMPVERD (tol=$M5_TOL_PCT%)  [$ABSLINE]"

    # Capture faddchain CPI for the subsequent fpindep relation check.
    if [ "$NAME" = "mb_faddchain" ] && [ "$CPI" != "-" ]; then
        FADDCHAIN_CPI="$CPI"
        info "captured faddchain CPI=$FADDCHAIN_CPI for fpindep relation check"
    fi

    # A control-flow / retire-order divergence forces FAIL: the band is moot.
    if [ "$CTRL_DIVERGE" = "1" ] && [ "$VERD" = "PASS" ]; then
        VERD="FAIL"
        DETAIL="control-flow divergence vs golden (RTL ran a different stream); $DETAIL"
    fi

    K_NAME+=("$NAME"); K_CLASS+=("$CLASS"); K_CPI+=("$CPI"); K_PAIR+=("$PAIR")
    K_EXTRA+=("$EXTRA"); K_BAND+=("$DETAIL"); K_CMP+=("$CMPVERD"); K_ABS+=("$ABSLINE")
    if [ "$GATED" = "1" ]; then
        K_VERD+=("$VERD")
        [ "$VERD" = "PASS" ] || CYCLE_OK=0
    else
        K_VERD+=("INFO")
    fi
}

CYCLE_OK=1
# (b) M4 integer bands (hard prereq).
for k in $M4_INT_KERNELS; do run_kernel "$k" INT 1; done
# (c) New M5 FP + cache bands. faddchain BEFORE fpindep (relation check).
for k in $M5_FP_KERNELS;    do run_kernel "$k" FP    1; done
for k in $M5_CACHE_KERNELS; do run_kernel "$k" CACHE 1; done
# (d) New M5 integer-DIVIDE occupancy bands (review-response, m5-div-spec.md).
for k in $M5_DIV_KERNELS;   do run_kernel "$k" DIV   1; done
for k in $M5_MUL_KERNELS;   do run_kernel "$k" MUL   1; done
for k in $M5_PAIR_KERNELS;  do run_kernel "$k" PAIR  1; done
# INFO kernels.
for k in $INFO_KERNELS;     do run_kernel "$k" INFO  0; done

# =============================================================================
# RESULT TABLES
# =============================================================================
say "M5 RESULT — functional regression (HARD prerequisite)"
printf '    %-6s %s\n' "GATE" "RESULT"
printf '    %-6s %s\n' "----" "------"
for ((i=0; i<${#FUNC_NAMES[@]}; i++)); do
    if [ "${FUNC_RC[$i]}" -eq 0 ]; then r="PASS (exit 0)"; else r="FAIL (exit ${FUNC_RC[$i]})"; fi
    printf '    %-6s %s\n' "${FUNC_NAMES[$i]}" "$r"
done

say "M5 RESULT — per-kernel cycle gate (INT=M4 bands, FP/CACHE=new M5 bands)"
printf '    %-14s %-6s %-7s %-8s %-9s %-14s %s\n' \
    "KERNEL" "CLASS" "RESULT" "CPI" "PAIR%" "EXTRA" "BAND"
printf '    %-14s %-6s %-7s %-8s %-9s %-14s %s\n' \
    "------" "-----" "------" "---" "-----" "-----" "----"
for ((i=0; i<${#K_NAME[@]}; i++)); do
    printf '    %-14s %-6s %-7s %-8s %-9s %-14s %s\n' \
        "${K_NAME[$i]}" "${K_CLASS[$i]}" "${K_VERD[$i]}" "${K_CPI[$i]}" \
        "${K_PAIR[$i]}" "${K_EXTRA[$i]}" "${K_BAND[$i]}"
done

say "M5 RESULT — integer abs-cyc vs p5model golden (tightened tol = $M5_TOL_PCT%)"
printf '    %-14s %s\n' "KERNEL" "COMPARE SUMMARY"
printf '    %-14s %s\n' "------" "---------------"
for ((i=0; i<${#K_NAME[@]}; i++)); do
    if [ "${K_CLASS[$i]}" = "INT" ] || [ "${K_CLASS[$i]}" = "CACHE" ]; then
        printf '    %-14s %s\n' "${K_NAME[$i]}" "${K_ABS[$i]:-(n/a)}"
    fi
done
echo ""

# =============================================================================
# VERDICT — exit 0 ONLY if functional regression green AND every gated kernel
# (M4 integer bands + new M5 FP/cache bands) meets its band.
# =============================================================================
if [ "$FUNC_OK" -ne 1 ]; then
    echo "M5 GATE: FAIL — FUNCTIONAL REGRESSION (m1/m2/m3 not all green)."
    echo "         Cache/FP timing changes ONLY cycle accounting, never"
    echo "         architectural results — a functional regression FAILS M5"
    echo "         regardless of cycle bands (hard safety)."
    exit 1
fi
if [ "$CYCLE_OK" -ne 1 ]; then
    echo "M5 GATE: FAIL — functional regression GREEN, but at least one cycle"
    echo "         band missed (see tables above)."
    echo "         (If the RTL does not yet model L1 cache timing + the x87/FP"
    echo "          latency pipe this is EXPECTED: faddchain CPI is wrong while"
    echo "          FP serializes, and dmiss/imiss abs-cyc diverges without"
    echo "          cache timing. The M5 plumbing + tables are in place; the"
    echo "          bands turn green once the cache/FP-timing RTL lands.)"
    exit 1
fi
echo "M5 GATE: PASS — functional regression GREEN, every M4 integer band still"
echo "         met from the cache-aware RTL, AND every new M5 FP/cache band met"
echo "         (faddchain CPI ~3, fpindep < faddchain, dmiss/imiss miss-driven"
echo "          elevation + abs-cyc within $M5_TOL_PCT% of the p5model golden)."
exit 0
