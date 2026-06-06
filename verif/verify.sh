#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/verify.sh — Ventium FAST unified differential gate (make verify).
#
# Reaches the EXACT SAME verdict as the slow `make m5` (which itself supersets
# m1..m4) — just PARALLEL, CACHED, and with NO redundant 3x func re-runs:
#
#   THE VERDICT (identical to the slow gate):
#     (1) FUNCTIONAL (= the m1/m2/m3 superset, run ONCE): every program in the
#         corpus (verif/tests/**/manifest.json: smoke + t_* + tx_* + mb_*) must
#         be func-diff-clean vs the QEMU gdbstub golden (compare.py --mode func
#         exit 0). x87 programs (manifest x87:true) run --x87 on both producers,
#         so st0..st7/fctrl/fstat/ftag are compared. This is the SAME set m3
#         iterates — m1/m2 are strict subsets, so running it ONCE is authoritative
#         (the slow gate ran m1 && m2 && m3 = 3x the same work).
#     (2) M4 INTEGER BANDS (HARD): mb_depadd/indepadd/agi/brloop/brrandom meet
#         their 55-validate bands computed FROM THE RTL --cycle trace (via
#         m5_metrics.py, which delegates to m4_metrics for these).
#     (3) M5 FP/CACHE BANDS (HARD): mb_faddchain CPI ~3.0, mb_fpindep CPI below
#         faddchain CPI, mb_dmiss/mb_imiss miss-driven CPI elevation + abs-cyc
#         within M5_TOL_PCT of the p5model golden.
#     (4) ABS-CYC report under the tightened M5_TOL_PCT for INT + CACHE kernels.
#   Plus the per-cycle-kernel structural compare.py --mode cycle control-flow /
#   retire-order check (a divergence forces FAIL — the band is moot).
#   INFO kernels (mb_agiloop) are reported, never gate (matches m4/m5).
#
#   Exit 0 IFF func GREEN (all programs diff-clean) AND every gated cycle band
#   met. This is byte-for-byte the same set of comparisons the slow gate runs.
#
#   WHY IT'S FAST + STILL AUTHORITATIVE: a program's golden depends ONLY on its
#   .s source (+ mode/x87/max_insn) — NOT on the RTL. So we generate each golden
#   ONCE, in PARALLEL (gen_goldens-style xargs -P, unique gdbstub ports), into
#   build/golden-cache/ keyed by sha1(.s). A refactor changes the RTL but never
#   the .s, so warm runs reuse every golden (the dominant QEMU cost) and only
#   rebuild the RTL once + re-trace + re-compare. The RTL trace is ALWAYS freshly
#   regenerated and compared, so the verdict is fully authoritative.
#
# Usage:   bash verif/verify.sh          (or: make verify)
#   M5_TOL_PCT   tightened abs-cyc tolerance (default 10, same as run-m5.sh)
#   VERIFY_JOBS  parallel workers (default min(nproc-2, #jobs))
#   PORTBASE     gdbstub port base for parallel func goldens (default 26000)
#   FORCE_GOLDEN=1   ignore the cache (cold regen) without dropping it
#
# `make verify-clean` drops build/golden-cache/ (forces a cold regen).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- pinned paths (all absolute) --------------------------------------------
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
export QEMU="$REFS/build/qemu/build/qemu-i386"
export ISA_VERIFY="$REFS/tools/isa_verify.py"
export GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
export COMPARE="$ROOT/verif/diff/compare.py"
export ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
export P5TRACE="$ROOT/build/p5trace.so"
export M5_METRICS="$ROOT/verif/m5_metrics.py"
TESTS_DIR="$ROOT/verif/tests"
TB_DIR="$ROOT/verif/tb"
export TB_BIN="$TB_DIR/obj_dir/tb_ventium"
BUILD="$ROOT/build"
export WORKDIR="$BUILD/verify"
export CACHE_DIR="$BUILD/golden-cache"
WORKER="$ROOT/verif/lib/verify_worker.sh"

export PYTHON="${PYTHON:-python3}"
export CC="${CC:-gcc}"
export CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
export M5_TOL_PCT="${M5_TOL_PCT:-10}"
export PORTBASE="${PORTBASE:-26000}"
FORCE_GOLDEN="${FORCE_GOLDEN:-0}"

NCPU="$(nproc 2>/dev/null || echo 4)"; [ "$NCPU" -gt 3 ] && NCPU=$(( NCPU - 2 ))

say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Cycle kernels and their classes (MUST match run-m4/run-m5.sh exactly):
#   INT (M4 bands, HARD), FP (new M5, HARD), CACHE (new M5, HARD), INFO (report).
# faddchain BEFORE fpindep so faddchain's measured CPI feeds fpindep's relation.
M4_INT_KERNELS="mb_depadd mb_indepadd mb_agi mb_brloop mb_brrandom"
M5_FP_KERNELS="mb_faddchain mb_fpindep"
M5_CACHE_KERNELS="mb_dmiss mb_imiss"
M5_DIV_KERNELS="mb_div8 mb_div16 mb_div32 mb_idiv32"
M5_MUL_KERNELS="mb_mul mb_imul2"
M5_PAIR_KERNELS="mb_accimm mb_rmimm mb_sh1 mb_nearbr"
INFO_KERNELS="mb_agiloop"

# =============================================================================
say "verify — environment sanity (fast unified m1-m5 gate)"
[ -x "$QEMU" ]       || die "qemu-i386 not found/executable: $QEMU"
[ -f "$P5TRACE" ]    || die "p5trace.so cycle oracle missing: $P5TRACE"
[ -f "$GEN_TRACE" ]  || die "gen_trace.py missing: $GEN_TRACE"
[ -f "$COMPARE" ]    || die "compare.py missing: $COMPARE"
[ -f "$ELF2FLAT" ]   || die "elf2flat.py missing: $ELF2FLAT"
[ -f "$ISA_VERIFY" ] || die "isa_verify.py missing: $ISA_VERIFY"
[ -f "$M5_METRICS" ] || die "m5_metrics.py missing: $M5_METRICS"
[ -d "$TESTS_DIR" ]  || die "tests dir missing: $TESTS_DIR"
[ -f "$WORKER" ]     || die "verify_worker.sh missing: $WORKER"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"
info "repo root  : $ROOT"
info "qemu-i386  : $QEMU"
info "p5trace.so : $P5TRACE  (imiss=8,dmiss=8,cache=1, 8KB/2-way/32B)"
info "cache dir  : $CACHE_DIR"
info "work dir   : $WORKDIR"
info "tol-pct    : $M5_TOL_PCT (tightened; bands are the real verdict)"
info "workers    : $NCPU (of $(nproc) cores)   portbase: $PORTBASE"
[ "$FORCE_GOLDEN" = "1" ] && info "FORCE_GOLDEN=1 — ignoring cache (cold regen)"
mkdir -p "$WORKDIR" "$CACHE_DIR"
rm -f "$WORKDIR"/*.result 2>/dev/null
[ "$FORCE_GOLDEN" = "1" ] && rm -f "$CACHE_DIR"/*.vtrace 2>/dev/null

# =============================================================================
# BUILD RTL ONCE (one verilator build — not per milestone, not per program).
# =============================================================================
say "build RTL testbench ONCE (verif/tb)"
make -C "$TB_DIR" > "$WORKDIR/tb_build.log" 2>&1 || {
    tail -12 "$WORKDIR/tb_build.log" | sed 's/^/    /'
    die "RTL testbench build failed (see $WORKDIR/tb_build.log)"
}
[ -x "$TB_BIN" ] || die "tb_ventium not built: $TB_BIN"
info "tb_ventium : $TB_BIN"

# =============================================================================
# DISCOVER programs + BUILD the job list.
# =============================================================================
say "discover corpus (verif/tests/**/manifest.json) + build job list"
MANIFESTS=$(find "$TESTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json | sort)
[ -n "$MANIFESTS" ] || die "no manifest.json found under $TESTS_DIR"

# class lookup for a kernel name (default INT-set membership decides class).
class_of() {  # <name>
    case " $M4_INT_KERNELS " in *" $1 "*) echo INT; return;; esac
    case " $M5_FP_KERNELS "  in *" $1 "*) echo FP;  return;; esac
    case " $M5_CACHE_KERNELS " in *" $1 "*) echo CACHE; return;; esac
    case " $M5_DIV_KERNELS " in *" $1 "*) echo DIV; return;; esac
    case " $M5_MUL_KERNELS " in *" $1 "*) echo MUL; return;; esac
    case " $M5_PAIR_KERNELS " in *" $1 "*) echo PAIR; return;; esac
    case " $INFO_KERNELS "   in *" $1 "*) echo INFO; return;; esac
    echo INT
}

# Emit one xargs job line per program. FUNC: every program (the m3 superset).
# CYCLE: only the cycle kernels (mb_* with a band) — additional to their func run.
JOBS="$WORKDIR/jobs.txt"
: > "$JOBS"
IDX=0
FUNC_TOTAL=0
declare -A SRC_OF MAX_OF X87_OF
ALL_NAMES=()
for MF in $MANIFESTS; do
    read -r NAME SRC_REL LOAD ENTRY MAX X87 < <("$PYTHON" - "$MF" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
def g(k, d=""):
    v = m.get(k, d); return d if v is None else v
x87 = m.get("x87", False)
if isinstance(x87, str): x87 = x87.strip().lower() in ("1","true","yes","on")
print(g("name"), g("src"), g("load_addr"), g("entry"), g("max_insn"),
      "1" if x87 else "0")
PY
)
    SRC="$TESTS_DIR/$SRC_REL"
    if [ -z "$NAME" ] || [ -z "$SRC_REL" ] || [ -z "$LOAD" ] || [ -z "$ENTRY" ] \
       || [ -z "$MAX" ] || [ ! -f "$SRC" ]; then
        info "WARN: $MF incomplete or src missing — will be reported FAIL"
    fi
    ALL_NAMES+=("$NAME")
    SRC_OF["$NAME"]="$SRC"; MAX_OF["$NAME"]="$MAX"; X87_OF["$NAME"]="$X87"

    # FUNC job (every program). last field = faddchain CPI placeholder (-).
    printf 'func\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t-\tINT\n' \
        "$NAME" "$SRC" "$LOAD" "$ENTRY" "$MAX" "$X87" "$IDX" >> "$JOBS"
    IDX=$(( IDX + 1 )); FUNC_TOTAL=$(( FUNC_TOTAL + 1 ))
done

# CYCLE jobs for the cycle kernels (in addition to their func job).
CYCLE_TOTAL=0
for k in $M4_INT_KERNELS $M5_FP_KERNELS $M5_CACHE_KERNELS $M5_DIV_KERNELS $M5_MUL_KERNELS $M5_PAIR_KERNELS $INFO_KERNELS; do
    SRC="${SRC_OF[$k]:-}"; MAX="${MAX_OF[$k]:-}"; X87="${X87_OF[$k]:-0}"
    CLS="$(class_of "$k")"
    if [ -z "$SRC" ]; then
        info "WARN: cycle kernel $k has no manifest — will be reported FAIL"
        # still emit a job so it shows as FAIL (worker handles missing src/elf)
        printf 'cycle\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t-\t%s\n' \
            "$k" "$TESTS_DIR/__missing__/$k.s" "0x08048000" "0x08048000" "4000" \
            "$X87" "$IDX" "$CLS" >> "$JOBS"
    else
        # entry/load: cycle kernels all use 0x08048000 per their manifests; read
        # them precisely from the manifest to stay generic.
        read -r LOAD ENTRY < <("$PYTHON" - "$TESTS_DIR" "$k" <<'PY'
import sys, json, glob, os
tests, name = sys.argv[1], sys.argv[2]
for mf in sorted(glob.glob(os.path.join(tests, "*", "manifest.json"))):
    try:
        m = json.load(open(mf))
        if m.get("name") == name:
            print(m.get("load_addr","0x08048000"), m.get("entry","0x08048000")); break
    except Exception: pass
PY
)
        printf 'cycle\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t-\t%s\n' \
            "$k" "$SRC" "${LOAD:-0x08048000}" "${ENTRY:-0x08048000}" "$MAX" \
            "$X87" "$IDX" "$CLS" >> "$JOBS"
    fi
    IDX=$(( IDX + 1 )); CYCLE_TOTAL=$(( CYCLE_TOTAL + 1 ))
done

TOTAL_JOBS=$IDX
info "func programs : $FUNC_TOTAL  (smoke + t_* + tx_* + mb_*, the m3 superset)"
info "cycle kernels : $CYCLE_TOTAL (INT $M4_INT_KERNELS / FP $M5_FP_KERNELS / CACHE $M5_CACHE_KERNELS / INFO $INFO_KERNELS)"
info "total jobs    : $TOTAL_JOBS  -> $NCPU parallel workers"

# count cache state before the run (for the cold/warm report).
PRE_GOLDENS="$(ls "$CACHE_DIR"/*.vtrace 2>/dev/null | wc -l)"
info "cached goldens before run : $PRE_GOLDENS"

# =============================================================================
# PARALLEL PER-PROGRAM EXECUTION (xargs -P). Each worker builds ELF, generates
# (or reuses) its cached golden, traces the RTL, and compares. For cycle kernels
# the worker stops after the structural compare; the band verdict is computed
# serially below (so faddchain CPI feeds fpindep).
# =============================================================================
say "run $TOTAL_JOBS jobs across $NCPU workers (cached parallel goldens)"
RUN_START=$(date +%s.%N)
# Feed each job line to the worker. Fields are tab-separated:
#   mode name src load entry max x87 portidx faddchain_cpi class
# class is exported per-job as KCLASS so the worker (cycle path) sees it.
# shellcheck disable=SC2016
< "$JOBS" xargs -P "$NCPU" -I{} -d '\n' bash -c '
    IFS=$'"'"'\t'"'"' read -r mode name src load entry max x87 idx fcpi cls <<< "{}"
    KCLASS="$cls" bash "$0" "$mode" "$name" "$src" "$load" "$entry" "$max" "$x87" "$idx" "$fcpi"
' "$WORKER"
RUN_END=$(date +%s.%N)
RUN_SECS="$("$PYTHON" -c "print(f'{$RUN_END-$RUN_START:.1f}')")"
info "parallel phase wall-time: ${RUN_SECS}s"

POST_GOLDENS="$(ls "$CACHE_DIR"/*.vtrace 2>/dev/null | wc -l)"
NEW_GOLDENS=$(( POST_GOLDENS - PRE_GOLDENS ))

# =============================================================================
# AGGREGATE — FUNC verdicts.
# =============================================================================
declare -a F_NAME F_MODE F_VERD F_DETAIL
FUNC_OK=1; F_PASS=0; F_FAIL=0; CACHE_HITS=0; CACHE_MISS=0
for NAME in "${ALL_NAMES[@]}"; do
    R="$WORKDIR/${NAME}.func.result"
    if [ ! -f "$R" ]; then
        F_NAME+=("$NAME"); F_MODE+=("?"); F_VERD+=("FAIL")
        F_DETAIL+=("no result file (worker did not run / crashed)")
        FUNC_OK=0; F_FAIL=$(( F_FAIL + 1 )); continue
    fi
    IFS='|' read -r _tag _n _mode _verd _detail _ch < "$R"
    F_NAME+=("$_n"); F_MODE+=("$_mode"); F_VERD+=("$_verd"); F_DETAIL+=("$_detail")
    if [ "$_verd" = "PASS" ]; then F_PASS=$(( F_PASS + 1 )); else FUNC_OK=0; F_FAIL=$(( F_FAIL + 1 )); fi
    if [ "$_ch" = "1" ]; then CACHE_HITS=$(( CACHE_HITS + 1 )); else CACHE_MISS=$(( CACHE_MISS + 1 )); fi
done

# =============================================================================
# AGGREGATE — CYCLE bands (SERIAL m5_metrics, ordered: faddchain before fpindep
# so its measured CPI feeds fpindep's relation check — same as the slow gate).
# =============================================================================
declare -a K_NAME K_CLASS K_VERD K_CPI K_PAIR K_EXTRA K_BAND K_CMP K_ABS
CYCLE_OK=1
FADDCHAIN_CPI=""
for k in $M4_INT_KERNELS $M5_FP_KERNELS $M5_CACHE_KERNELS $M5_DIV_KERNELS $M5_MUL_KERNELS $M5_PAIR_KERNELS $INFO_KERNELS; do
    CLS="$(class_of "$k")"
    GATED=1; [ "$CLS" = "INFO" ] && GATED=0
    R="$WORKDIR/${k}.cycle.result"
    if [ ! -f "$R" ]; then
        K_NAME+=("$k"); K_CLASS+=("$CLS"); K_VERD+=("MISSING")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_BAND+=("no result file")
        K_CMP+=("-"); K_ABS+=("-")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        continue
    fi
    IFS='|' read -r _tag _n _cls _traceok _rtl _gold _cmp _abs _ch < "$R"
    if [ "$_traceok" != "1" ]; then
        # worker reported a build/trace/golden failure; _cmp holds the reason.
        K_NAME+=("$k"); K_CLASS+=("$CLS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_BAND+=("$_cmp")
        K_CMP+=("-"); K_ABS+=("${_abs:-}")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        continue
    fi
    # compute the band verdict now (sub-second), faddchain CPI in scope.
    LINE="$(M5_FADDCHAIN_CPI="$FADDCHAIN_CPI" "$PYTHON" "$M5_METRICS" \
                --kernel "$k" --rtl "$_rtl" --golden "$_gold" \
                --abs-tol-pct "$M5_TOL_PCT" 2> "$WORKDIR/${k}_metrics.txt")"
    if [ -z "$LINE" ]; then
        K_NAME+=("$k"); K_CLASS+=("$CLS"); K_VERD+=("FAIL")
        K_CPI+=("-"); K_PAIR+=("-"); K_EXTRA+=("-"); K_BAND+=("metrics failed (see ${k}_metrics.txt)")
        K_CMP+=("$_cmp"); K_ABS+=("$_abs")
        [ "$GATED" = "1" ] && CYCLE_OK=0
        continue
    fi
    IFS='|' read -r VERD CPI PAIR EXTRA DETAIL <<< "$LINE"

    # control-flow divergence in the structural compare forces FAIL (band moot).
    if [[ "$_cmp" == *"CONTROL-FLOW DIVERGENCE"* ]] && [ "$VERD" = "PASS" ]; then
        VERD="FAIL"
        DETAIL="control-flow divergence vs golden (RTL ran a different stream); $DETAIL"
    fi

    # capture faddchain CPI for the fpindep relation check.
    if [ "$k" = "mb_faddchain" ] && [ "$CPI" != "-" ]; then
        FADDCHAIN_CPI="$CPI"
    fi

    K_NAME+=("$k"); K_CLASS+=("$CLS"); K_CPI+=("$CPI"); K_PAIR+=("$PAIR")
    K_EXTRA+=("$EXTRA"); K_BAND+=("$DETAIL"); K_CMP+=("$_cmp"); K_ABS+=("$_abs")
    if [ "$GATED" = "1" ]; then
        K_VERD+=("$VERD")
        [ "$VERD" = "PASS" ] || CYCLE_OK=0
    else
        K_VERD+=("INFO")
    fi
done

# =============================================================================
# RESULT TABLES
# =============================================================================
say "RESULT — FUNCTIONAL (m1/m2/m3 superset; every program diff-clean vs QEMU)"
printf '    %-16s %-5s %-6s %s\n' "PROGRAM" "MODE" "RESULT" "DETAIL"
printf '    %-16s %-5s %-6s %s\n' "-------" "----" "------" "------"
for ((i=0; i<${#F_NAME[@]}; i++)); do
    printf '    %-16s %-5s %-6s %s\n' \
        "${F_NAME[$i]}" "${F_MODE[$i]}" "${F_VERD[$i]}" "${F_DETAIL[$i]}"
done
echo ""
info "func totals: $F_PASS PASS / $F_FAIL FAIL / $FUNC_TOTAL total"

say "RESULT — per-kernel cycle gate (INT=M4 bands, FP/CACHE=new M5 bands)"
printf '    %-14s %-6s %-7s %-8s %-9s %-14s %s\n' \
    "KERNEL" "CLASS" "RESULT" "CPI" "PAIR%" "EXTRA" "BAND"
printf '    %-14s %-6s %-7s %-8s %-9s %-14s %s\n' \
    "------" "-----" "------" "---" "-----" "-----" "----"
for ((i=0; i<${#K_NAME[@]}; i++)); do
    printf '    %-14s %-6s %-7s %-8s %-9s %-14s %s\n' \
        "${K_NAME[$i]}" "${K_CLASS[$i]}" "${K_VERD[$i]}" "${K_CPI[$i]}" \
        "${K_PAIR[$i]}" "${K_EXTRA[$i]}" "${K_BAND[$i]}"
done

say "RESULT — integer/cache abs-cyc vs p5model golden (tightened tol = $M5_TOL_PCT%)"
printf '    %-14s %s\n' "KERNEL" "COMPARE SUMMARY"
printf '    %-14s %s\n' "------" "---------------"
for ((i=0; i<${#K_NAME[@]}; i++)); do
    if [ "${K_CLASS[$i]}" = "INT" ] || [ "${K_CLASS[$i]}" = "CACHE" ]; then
        printf '    %-14s %s\n' "${K_NAME[$i]}" "${K_ABS[$i]:-(n/a)}"
    fi
done
echo ""

# =============================================================================
# CACHE / TIMING SUMMARY
# =============================================================================
say "CACHE + TIMING"
info "func golden cache hits : $CACHE_HITS / $FUNC_TOTAL  (misses regenerated: $CACHE_MISS)"
info "goldens in cache       : $POST_GOLDENS (new this run: $NEW_GOLDENS)"
info "parallel phase         : ${RUN_SECS}s on $NCPU workers"
echo ""

# =============================================================================
# VERDICT
# =============================================================================
if [ "$FUNC_OK" -ne 1 ]; then
    echo "VERIFY GATE: FAIL — FUNCTIONAL REGRESSION (a program diverged vs QEMU)."
    echo "             A functional regression FAILS the gate regardless of any"
    echo "             cycle band (same hard safety as the slow m1/m2/m3->m4/m5)."
    exit 1
fi
if [ "$CYCLE_OK" -ne 1 ]; then
    echo "VERIFY GATE: FAIL — functional GREEN, but at least one gated cycle band"
    echo "             missed (M4 integer / M5 FP / M5 cache; see tables above)."
    exit 1
fi
echo "VERIFY GATE: PASS — functional GREEN (every program diff-clean vs QEMU,"
echo "             incl. x87), every M4 integer band met from the cache-aware"
echo "             RTL, AND every M5 FP/cache band met (faddchain CPI ~3, fpindep"
echo "             < faddchain, dmiss/imiss miss-driven elevation + abs-cyc"
echo "             within $M5_TOL_PCT% of the p5model golden). Same verdict as"
echo "             the slow make m5 — parallel + cached + no redundant 3x."
exit 0
