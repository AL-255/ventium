#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/lib/verify_worker.sh — per-program worker for the fast unified gate.
#
# verif/verify.sh fans this out with `xargs -P <nproc>` (one invocation per
# program). It performs, for ONE program, the SAME steps the slow gates do —
# just per-program and with a CACHED golden:
#
#   FUNC programs (smoke / t_* / tx_* / and mb_* run as func):
#     1. build ELF (gcc -m32 -march=pentium -nostdlib -static), isa_verify,
#        elf2flat  — exactly run-m2/m3.sh.
#     2. CACHED golden: gdbstub func golden via gen_trace.py (--x87 when the
#        manifest says x87), keyed by sha1(.s)+max_insn+x87. Cache hit -> skip.
#     3. RTL func trace via tb_ventium (--init-esp from golden n=0, --x87 when
#        x87) with --max-insn = manifest max_insn.
#     4. compare.py --mode func  (exit 0 == diff-clean). THE func verdict.
#
#   CYCLE kernels (mb_* with a cycle band — passed mode=cycle):
#     1. build ELF / isa_verify / elf2flat (same).
#     2. CACHED golden: p5trace.so cycle golden, keyed by sha1(.s) (cycle is
#        insensitive to max_insn/esp). Cache hit -> skip.
#     3. RTL cycle trace via tb_ventium --cycle (--x87 for FP kernels),
#        --max-insn = golden record count (align by n over the whole stream),
#        --init-esp reused from any func golden's n=0 if present else default,
#        --max-cycles 80000000.
#     4. compare.py --mode cycle --tol-pct  (control-flow / retire-order check),
#        then m5_metrics.py for the band verdict (INT delegate to m4; FP/CACHE
#        the new M5 bands). faddchain CPI is captured and re-used for fpindep.
#
# These are byte-for-byte the same commands the slow gates run; only the golden
# is reused across runs (a refactor changes the RTL, never the golden, since the
# golden depends ONLY on the .s source + mode/x87/max_insn).
#
# The golden CACHE makes a refactor-time gate fast: warm runs skip every QEMU
# golden (the dominant cost) and only rebuild RTL once + re-trace + re-compare.
#
# Result is written to "$WORKDIR/<name>.result" as a single '|'-separated line:
#   FUNC kernels : FUNC|<name>|<mode:int|x87>|<verdict:PASS|FAIL>|<detail>|<cachehit:0|1>
#   CYCLE kernels: CYCLE|<name>|<class>|<traceok:0|1>|<rtltrace>|<gold>|<cmpverd>|<absline>|<cachehit>
#                  (the BAND verdict is computed serially by verify.sh after all
#                  traces exist, so faddchain's measured CPI can feed fpindep's
#                  relation check — exactly as the slow gate's ordered loop does.
#                  The expensive work — golden + RTL trace + compare — is done
#                  here in parallel; m5_metrics is sub-second and runs serially.)
# plus per-step logs under "$WORKDIR/<name>.*.log". Worker always exits 0 (the
# verdict is in the result file); verify.sh aggregates.
#
# Usage (internal — verify.sh builds the arg line):
#   verify_worker.sh <mode:func|cycle> <name> <src> <load> <entry> <max> <x87> \
#                    <portidx> <faddchain_cpi_or_dash>
# Env (exported once by verify.sh): ROOT QEMU GEN_TRACE COMPARE ELF2FLAT
#   ISA_VERIFY P5TRACE TB_BIN M5_METRICS PYTHON CC CFLAGS_BASE WORKDIR
#   CACHE_DIR PORTBASE M5_TOL_PCT
# TB_EXTRA_FLAGS applies to FUNC jobs only (it may contain --cycle-func).
# TB_CYCLE_EXTRA_FLAGS is the separate whitespace-delimited CYCLE passthrough,
# e.g. --l1-axi --quiesce 200000. Never infer a shared backend from FUNC flags.
# =============================================================================
set -uo pipefail

MODE="$1" NAME="$2" SRC="$3" LOAD="$4" ENTRY="$5" MAX="$6" X87="$7" PORTIDX="$8"
FADDCHAIN_CPI="${9:-}"

W="$WORKDIR"
# NAMESPACE every per-job artifact by MODE: an mb_* kernel has BOTH a func job
# and a cycle job, and they run CONCURRENTLY under xargs -P. If they shared
# output paths the func-mode RTL trace would clobber the cycle-mode one (and
# vice-versa), so the serial m5_metrics step would read a func trace with no
# `cyc` field. Per-mode paths keep the two jobs fully independent.
TAG="${NAME}.${MODE}"
ELF="$W/${TAG}.elf"; FLAT="$W/${TAG}.flat"
RTL="$W/${TAG}_rtl.vtrace"; CMP="$W/${TAG}_cmp.txt"
RES="$W/${NAME}.${MODE}.result"

emit_func() {  # <verdict> <detail> <cachehit>
    printf 'FUNC|%s|%s|%s|%s|%s\n' \
        "$NAME" "$([ "$X87" = "1" ] && echo x87 || echo int)" "$1" "$2" "$3" > "$RES"
}
emit_cycle() {  # <class> <traceok> <rtltrace> <gold> <cmpverd> <absline> <cachehit>
    printf 'CYCLE|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$NAME" "$1" "$2" "$3" "$4" "$5" "$6" "$7" > "$RES"
}

# ---- 1) build ELF / ISA-verify / flatten (identical to run-m2/m3/m4/m5) -----
CLASS="${KCLASS:-INT}"   # cycle-kernel class (INT|FP|CACHE|INFO); func ignores it
if ! "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$W/${TAG}_build.log"; then
    [ "$MODE" = "func" ] && emit_func FAIL "ELF build failed (gcc)" 0 \
        || emit_cycle "$CLASS" 0 - - "ELF build failed" - 0
    exit 0
fi
if ! "$PYTHON" "$ISA_VERIFY" "$ELF" > "$W/${TAG}_isa.log" 2>&1; then
    [ "$MODE" = "func" ] && emit_func FAIL "isa_verify failed (non-P5 ISA)" 0 \
        || emit_cycle "$CLASS" 0 - - "isa_verify failed" - 0
    exit 0
fi
if ! "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" > "$W/${TAG}_flat.log" 2>&1; then
    [ "$MODE" = "func" ] && emit_func FAIL "elf2flat failed" 0 \
        || emit_cycle "$CLASS" 0 - - "elf2flat failed" - 0
    exit 0
fi

# ---- cache key --------------------------------------------------------------
# REVIEW_Jul29 M-02: the key used to be sha1(.s) (+ mode/x87/max for func; nothing
# extra for cycle). That omits nearly everything that actually DEFINES a golden —
# the produced ELF/flat bytes, the compiler/binutils, the link/load/entry settings,
# the CPU model, the QEMU binary, and the trace plugin. A toolchain, plugin, load
# address or oracle change would therefore silently REUSE a stale golden and yield
# a convincing but invalid comparison. Key on the real produced image plus a
# versioned signature of every oracle input.
SRC_SHA="$(sha1sum "$SRC" | cut -d' ' -f1)"

# GOLDEN_FMT: bump whenever the trace format or comparator semantics change, so
# every cached golden is invalidated on purpose rather than by accident.
GOLDEN_FMT="v2"
_sha_of() { [ -e "$1" ] && sha1sum "$1" 2>/dev/null | cut -d' ' -f1 || echo "absent"; }
ELF_SHA="$(_sha_of "$ELF")"
ORACLE_SIG="$(printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$GOLDEN_FMT" \
    "cpu=pentium" \
    "qemu=$(_sha_of "$QEMU")" \
    "p5trace=$(_sha_of "$P5TRACE")" \
    "cc=$("$CC" --version 2>/dev/null | head -1)" \
    "cflags=$CFLAGS_BASE" \
    "load=$LOAD,entry=$ENTRY" \
    | sha1sum | cut -d' ' -f1)"

# =============================================================================
# FUNC PATH
# =============================================================================
if [ "$MODE" = "func" ]; then
    # M-02: image bytes + oracle signature now participate in the key.
    # The opt-in QEMU observer changes the actual terminal record without
    # changing the binary. Match its literal-1 activation rule; all other
    # values are disabled. Never share enabled/disabled functional goldens.
    PREEXIT_MODE=0
    [ "${VTM_QEMU_GDB_PREEXIT:-}" = "1" ] && PREEXIT_MODE=1
    KEY="${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.func.preexit${PREEXIT_MODE}.x87${X87}.max${MAX}"
    GOLD="$CACHE_DIR/${KEY}.vtrace"
    CACHEHIT=0
    X87_FLAG=""; [ "$X87" = "1" ] && X87_FLAG="--x87"

    if [ -s "$GOLD" ] && [ "$(wc -l < "$GOLD")" -ge 2 ]; then
        CACHEHIT=1
    else
        # generate golden into a unique tmp then atomically publish (so a
        # crashed/partial golden never poisons the cache for the next run).
        TMP="$CACHE_DIR/.${KEY}.$$.tmp"
        PORT=$(( PORTBASE + PORTIDX ))
        OK=0
        for attempt in 1 2 3; do
            if "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" \
                    --out "$TMP" --max-insn "$MAX" --port "$PORT" $X87_FLAG \
                    > "$W/${TAG}_qemu.log" 2>&1 \
                    && [ -s "$TMP" ] && [ "$(wc -l < "$TMP")" -ge 2 ]; then
                OK=1; break
            fi
            PORT=$(( PORT + 1 ))   # bump port on retry (collision safety)
        done
        if [ "$OK" -ne 1 ]; then
            rm -f "$TMP"
            emit_func FAIL "gen_trace.py failed (golden)" 0
            exit 0
        fi
        mv -f "$TMP" "$GOLD"
    fi

    # init ESP = the loader-established value the golden reports at n=0.
    INIT_ESP="$("$PYTHON" - "$GOLD" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        f.readline(); print(json.loads(f.readline())["esp"])
except Exception:
    print("0x40c34910")
PY
)"

    # TB_EXTRA_FLAGS: optional passthrough (e.g. "--l1-axi --quiesce 100000" for the
    # P1-1 mode-2 func gate, which runs a different TB_BIN against the SAME golden).
    if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp "$INIT_ESP" --out "$RTL" --max-insn "$MAX" $X87_FLAG \
            ${TB_EXTRA_FLAGS:-} \
            > "$W/${TAG}_rtl.log" 2>&1; then
        emit_func FAIL "tb_ventium run failed" "$CACHEHIT"
        exit 0
    fi

    # A program whose manifest sets "x87_stkflt_arch" deliberately drives the
    # x87 stack past its ends, where the ARCHITECTURAL response (IE|SF in
    # fstat; the QNaN-indefinite substitution in st*) has no QEMU counterpart
    # (QEMU's fpush/fpop never consult the tags). Compare with exactly those
    # two oracle gaps masked -- nothing else.
    # The masks are RECORD- and FIELD-EXACT when the manifest carries
    # "x87_stkflt_fstat_ranges" / "x87_stkflt_fpr_ranges" ([lo, hi|null]
    # record-index ranges, hi inclusive; an fpr entry may add a third element,
    # a comma-separated "st0,st3" field list that scopes the mask to those
    # registers only). The ranges are the measured divergence set of an
    # unmasked compare vs the pinned-QEMU golden -- every record/field outside
    # them compares at full strength, so an unrelated x87 regression cannot
    # hide under a program-wide mask.
    STKMSK=""
    # ($ROOT is NOT exported to the worker -- derive the manifest from $SRC,
    # which is $TESTS_DIR/<name>/<name>.s by construction.)
    STKMF="$(dirname "$SRC")/manifest.json"
    if [ -f "$STKMF" ]; then
      STKMSK="$("$PYTHON" - "$STKMF" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
fr, pr = m.get("x87_stkflt_fstat_ranges"), m.get("x87_stkflt_fpr_ranges")
# FPREM1 quotient-CC oracle gap: the pinned QEMU never fills C0/C3/C1 for
# FPREM1 (its SoftFloat call drops the quotient out-pointer), the RTL reports
# the architectural round-nearest Q2/Q1/Q0. Mask 0x4300 (C0|C1|C3) on exactly
# the manifest's measured record ranges; C2 and the exception bits still
# compare at full strength. (One fstat mask value per program: a manifest
# carries either the stkflt ranges or these, not both.)
cc = m.get("x87_fprem1_cc_ranges")
def fmt(r):
    s = f"{r[0]}:{'' if len(r) < 2 or r[1] is None else r[1]}"
    if len(r) >= 3 and r[2]:
        s += f"={r[2]}"
    return s
args = []
if cc:
    args.append("--mask-fstat-exc 0x4300")
    args += [f"--mask-fstat-range {fmt(r)}" for r in cc]
if fr:
    args.append("--mask-fstat-exc 0x4741")
    args += [f"--mask-fstat-range {fmt(r)}" for r in fr]
if pr:
    args += [f"--mask-fpr-range {fmt(r)}" for r in pr]
if not args and m.get("x87_stkflt_arch"):
    args = ["--mask-fstat-exc 0x4741 --mask-x87-fpr"]
print(" ".join(args))
PY
)"
    fi

    "$PYTHON" "$COMPARE" --mode func $STKMSK "$GOLD" "$RTL" > "$CMP" 2>&1
    RC=$?
    if [ "$RC" -eq 0 ]; then
        emit_func PASS "func-equivalent ($MAX insns max)" "$CACHEHIT"
    else
        DIV="$("$PYTHON" - "$CMP" <<'PY'
import sys
try:
    for line in open(sys.argv[1]):
        s = line.strip()
        if s.startswith("n=") or "LENGTH MISMATCH" in s:
            print(s); break
except Exception:
    pass
PY
)"
        if [ "$RC" -eq 2 ]; then
            emit_func FAIL "compare exit 2 (malformed/length); ${DIV:-see cmp}" "$CACHEHIT"
        else
            emit_func FAIL "compare exit 1; ${DIV:-divergence}" "$CACHEHIT"
        fi
    fi
    exit 0
fi

# =============================================================================
# CYCLE PATH — expensive parts only (golden + RTL trace + compare). The band
# verdict is computed serially by verify.sh (so faddchain CPI can feed fpindep).
# =============================================================================
# M-02: image bytes + oracle signature now participate in the key.
KEY="${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.cycle"
GOLD="$CACHE_DIR/${KEY}.vtrace"
CACHEHIT=0
TB_X87FLAG=""; { [ "$X87" = "1" ] || [ "$CLASS" = "FP" ]; } && TB_X87FLAG="--x87"

if [ -s "$GOLD" ] && [ "$(wc -l < "$GOLD")" -ge 2 ]; then
    CACHEHIT=1
else
    TMP="$CACHE_DIR/.${KEY}.$$.tmp"
    if "$QEMU" -cpu pentium -plugin "$P5TRACE,out=$TMP" "$ELF" \
            > "$W/${TAG}_gold.log" 2>&1 \
            && [ -s "$TMP" ] && [ "$(wc -l < "$TMP")" -ge 2 ]; then
        mv -f "$TMP" "$GOLD"
    else
        rm -f "$TMP"
        emit_cycle "$CLASS" 0 - - "p5trace golden failed" - 0
        exit 0
    fi
fi

# golden record count (records = lines - header) for --max-insn alignment.
GN="$("$PYTHON" - "$GOLD" <<'PY'
import sys
try:
    with open(sys.argv[1]) as f:
        print(max(0, sum(1 for _ in f) - 1))
except Exception:
    print(0)
PY
)"

# init ESP: reuse a func golden's n=0 esp if cached, else spec default.
INIT_ESP="0x40c34910"
# Match the functional producer's complete key, including observer mode.
# A source-only legacy lookup cannot identify the actual image/oracle trace.
PREEXIT_MODE=0
[ "${VTM_QEMU_GDB_PREEXIT:-}" = "1" ] && PREEXIT_MODE=1
FUNC_GOLD="$CACHE_DIR/${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.func.preexit${PREEXIT_MODE}.x87${X87}.max${MAX}.vtrace"
if [ -f "$FUNC_GOLD" ]; then
    v="$("$PYTHON" - "$FUNC_GOLD" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        f.readline(); print(json.loads(f.readline())["esp"])
except Exception:
    pass
PY
)"
    [ -n "$v" ] && INIT_ESP="$v"
fi

cycle_extra=()
read -r -a cycle_extra <<< "${TB_CYCLE_EXTRA_FLAGS:-}"
for flag in "${cycle_extra[@]}"; do
    case "$flag" in
        --cycle-func|--no-trace|--dbg-step|--dbg-bp)
            emit_cycle "$CLASS" 0 - - "invalid CYCLE trace/mode flag: $flag" - 0
            exit 0 ;;
    esac
done
cycle_cmd=("$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY"
           --init-esp "$INIT_ESP" --cycle)
[[ -z "$TB_X87FLAG" ]] || cycle_cmd+=("$TB_X87FLAG")
cycle_cmd+=(--out "$RTL" --max-insn "$GN" --max-cycles 80000000 "${cycle_extra[@]}")
# NUL-separated argv is exact and unambiguous. Keep the old native log too;
# neither compile-time defines nor a FUNC command proves this run used AXI.
printf '%s\0' "${cycle_cmd[@]}" > "$W/${TAG}_rtl.argv"
if ! "${cycle_cmd[@]}" > "$W/${TAG}_rtl.log" 2>&1; then
    emit_cycle "$CLASS" 0 - - "tb --cycle run failed" - "$CACHEHIT"
    exit 0
fi

# structural compare at the tightened tolerance (control-flow / retire-order).
"$PYTHON" "$COMPARE" --mode cycle --tol-pct "$M5_TOL_PCT" "$GOLD" "$RTL" > "$CMP" 2>&1
CRC=$?
CMPVERD="exit=$CRC"
if grep -q "control-flow / retire-order mismatch" "$CMP" 2>/dev/null; then
    CMPVERD="exit=$CRC (CONTROL-FLOW DIVERGENCE)"
fi
ABSLINE="$(grep -m1 "total cycles:" "$CMP" 2>/dev/null | sed 's/^[[:space:]]*//')"

# Expensive work done. Hand the trace paths + compare verdict to verify.sh,
# which runs m5_metrics serially (sub-second) with faddchain CPI in scope.
emit_cycle "$CLASS" 1 "$RTL" "$GOLD" "$CMPVERD" "$ABSLINE" "$CACHEHIT"
exit 0
