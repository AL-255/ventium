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

# ---- cache key: sha1(.s) (+ mode/x87/max for func) --------------------------
SRC_SHA="$(sha1sum "$SRC" | cut -d' ' -f1)"

# =============================================================================
# FUNC PATH
# =============================================================================
if [ "$MODE" = "func" ]; then
    KEY="${SRC_SHA}.func.x87${X87}.max${MAX}"
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

    if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp "$INIT_ESP" --out "$RTL" --max-insn "$MAX" $X87_FLAG \
            > "$W/${TAG}_rtl.log" 2>&1; then
        emit_func FAIL "tb_ventium run failed" "$CACHEHIT"
        exit 0
    fi

    "$PYTHON" "$COMPARE" --mode func "$GOLD" "$RTL" > "$CMP" 2>&1
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
KEY="${SRC_SHA}.cycle"
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
FUNC_GOLD="$CACHE_DIR/${SRC_SHA}.func.x87${X87}.max${MAX}.vtrace"
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

if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
        --init-esp "$INIT_ESP" --cycle $TB_X87FLAG --out "$RTL" \
        --max-insn "$GN" --max-cycles 80000000 \
        > "$W/${TAG}_rtl.log" 2>&1; then
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
