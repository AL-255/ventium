#!/usr/bin/env bash
# Focused old/new shared-SRT top equivalence gate.  It owns only a fresh
# /var/tmp output leaf and never writes repository or canonical object paths.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OLD_TOP="${OLD_TOP:-}"
OUT="${VENTIUM_FP_SRT_TOP_AB_OUT:-}"
TIMEOUT_SECS="${VENTIUM_FP_SRT_TOP_AB_TIMEOUT_SECS:-600}"
VL_J="${VL_J:-1}"

readonly OLD_REV="4f7f858fd38f7453cdfcc4619cec888d9a638356"
readonly OLD_SHA="19a2b6e4323ce6583567632baf4358b5af62406775ef0c1a8cf8e0754760b70c"
readonly NEW_SHA="e093df1b7b332a226a2ad8a551af2309403610fb15ef3cd791afcdf06c952b5a"
readonly SRT_SHA="62c662f7e1608c100e4853a12b3282aefa729bb49b6dd519cdb9404a94f87b52"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

[[ "$TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]] || die 'timeout must be a positive integer'
(( TIMEOUT_SECS <= 600 )) || die 'timeout must not exceed 600 seconds'
[[ "$VL_J" =~ ^[1-9][0-9]*$ ]] || die 'VL_J must be a positive integer'
(( VL_J <= 32 )) || die 'VL_J must not exceed 32'
if (( VL_J > 1 )) && [[ "${VENTIUM_BUILD_SCOPE_PROFILE:-}" != "ipc_parallel32" ]]; then
  die 'VL_J >1 requires the active ipc_parallel32 build scope'
fi

if [[ -z "$OUT" ]]; then
  OUT="$(mktemp -d /var/tmp/ventium-fp-srt-top-ab.XXXXXX)"
  OUT="$(realpath -e -- "$OUT")" || die 'cannot canonicalize mktemp output leaf'
else
  out_raw="$OUT"
  case "$out_raw" in
    /var/tmp/*) ;;
    *) die 'VENTIUM_FP_SRT_TOP_AB_OUT must begin exactly /var/tmp/' ;;
  esac
  out_rel="${out_raw#/var/tmp/}"
  [[ -n "$out_rel" ]] || die 'output leaf cannot be /var/tmp itself'
  case "/$out_rel/" in
    *'//'*) die 'output leaf may not contain an empty path component' ;;
    */./*|*/../*) die 'output leaf may not contain dot or traversal components' ;;
  esac
  out_parent="${out_raw%/*}"
  while [[ "$out_parent" != "/var/tmp" ]]; do
    [[ "$out_parent" == /var/tmp/* ]] || die 'output parent escapes /var/tmp'
    [[ ! -L "$out_parent" ]] || die "output ancestor is a symlink: $out_parent"
    out_parent="${out_parent%/*}"
  done
  [[ ! -L /var/tmp ]] || die '/var/tmp itself must not be a symlink'
  OUT="$(realpath -m -- "$out_raw")" || die 'cannot canonicalize requested output leaf'
  case "$OUT" in
    /var/tmp/*) ;;
    *) die 'canonical output leaf escapes /var/tmp' ;;
  esac
  [[ ! -e "$OUT" && ! -L "$OUT" ]] || die "output leaf already exists: $OUT"
  mkdir -p "$OUT"
  OUT="$(realpath -e -- "$OUT")" || die 'cannot resolve created output leaf'
fi
case "$OUT" in
  /var/tmp/*) ;;
  *) die 'resolved output leaf escapes /var/tmp' ;;
esac
[[ -d "$OUT" && ! -L "$OUT" ]] || die "output leaf is not a real directory: $OUT"
mkdir -p "$OUT/tmp"

if [[ -z "$OLD_TOP" ]]; then
  [[ "$(git -C "$ROOT" rev-parse --verify "${OLD_REV}^{commit}")" == "$OLD_REV" ]] ||
    die "pinned old revision is unavailable: $OLD_REV"
  git -C "$ROOT" show "$OLD_REV:fp_shared/ven_fp_top.sv" > "$OUT/ven_fp_top.baseline.sv" ||
    die "cannot extract pinned old top from $OLD_REV"
  OLD_TOP="$OUT/ven_fp_top.baseline.sv"
fi

SOURCE_INPUTS=(
  "$OLD_TOP"
  "$ROOT/rtl/core/ventium_decode_pkg.sv"
  "$ROOT/rtl/fpu/fpu_x87_pkg.sv"
  "$ROOT/rtl/core/ventium_x87_pkg.sv"
  "$ROOT/rtl/fpu/fpu_srt_div.sv"
  "$ROOT/rtl/fpu/ven_bcd.sv"
  "$ROOT/rtl/fpu/ven_bcd_to_fp.sv"
  "$ROOT/rtl/fpu/fpu_estdiv.sv"
  "$ROOT/fp_shared/ven_fp_state.sv"
  "$ROOT/fp_shared/ven_fp_alu.sv"
  "$ROOT/fp_shared/ven_fp_misc.sv"
  "$ROOT/fp_shared/ven_fp_widemul.sv"
  "$ROOT/fp_shared/ven_fp_estdiv.sv"
  "$ROOT/fp_shared/ven_fp_trans.sv"
  "$ROOT/rtl/fpu/fpu_fsincos_rom.svh"
  "$ROOT/rtl/fpu/fpu_f2xm1_rom.svh"
  "$ROOT/rtl/fpu/fpu_fpatan_rom.svh"
  "$ROOT/rtl/fpu/fpu_fyl2x_rom.svh"
  "$ROOT/fp_shared/ven_fp_top.sv"
  "$ROOT/fp_shared/tb/tb_ven_fp_srt_top_ab.sv"
  "$ROOT/fp_shared/tb/run_srt_top_ab_gate.sh"
)
for source_file in "${SOURCE_INPUTS[@]}"; do
  [[ -f "$source_file" && ! -L "$source_file" ]] ||
    die "required regular source missing: $source_file"
done
[[ "$(sha256sum "$OLD_TOP" | awk '{print $1}')" == "$OLD_SHA" ]] ||
  die 'old top SHA mismatch'
[[ "$(sha256sum "$ROOT/fp_shared/ven_fp_top.sv" | awk '{print $1}')" == "$NEW_SHA" ]] ||
  die 'new top SHA mismatch'
[[ "$(sha256sum "$ROOT/rtl/fpu/fpu_srt_div.sv" | awk '{print $1}')" == "$SRT_SHA" ]] ||
  die 'production SRT SHA mismatch'

# Only the declaration token changes.  Reverse substitution must reconstruct
# the original byte-for-byte text, ruling out an accidental old-source rewrite.
module_count="$(perl -ne '$n++ if /^module ven_fp_top$/; END { print $n }' "$OLD_TOP")"
[[ "$module_count" == 1 ]] || die 'old source lacks exactly one module declaration'
if rg -q '^module ven_fp_top_old$' "$OLD_TOP"; then
  die 'old source already contains the replacement module name'
fi
perl -0pe 's/^module ven_fp_top$/module ven_fp_top_old/m' "$OLD_TOP" \
  > "$OUT/ven_fp_top_old.sv"
cmp -s "$OLD_TOP" <(perl -0pe 's/^module ven_fp_top_old$/module ven_fp_top/m' \
  "$OUT/ven_fp_top_old.sv") || die 'module-name-only substitution check failed'
[[ "$(sha256sum "$OUT/ven_fp_top_old.sv" | awk '{print $1}')" != "$OLD_SHA" ]] ||
  die 'old module rename did not alter output'
COMPILED_SOURCES=(
  "$ROOT/rtl/core/ventium_decode_pkg.sv"
  "$ROOT/rtl/fpu/fpu_x87_pkg.sv"
  "$ROOT/rtl/core/ventium_x87_pkg.sv"
  "$ROOT/rtl/fpu/fpu_srt_div.sv"
  "$ROOT/rtl/fpu/ven_bcd.sv"
  "$ROOT/rtl/fpu/ven_bcd_to_fp.sv"
  "$ROOT/rtl/fpu/fpu_estdiv.sv"
  "$ROOT/fp_shared/ven_fp_state.sv"
  "$ROOT/fp_shared/ven_fp_alu.sv"
  "$ROOT/fp_shared/ven_fp_misc.sv"
  "$ROOT/fp_shared/ven_fp_widemul.sv"
  "$ROOT/fp_shared/ven_fp_estdiv.sv"
  "$ROOT/fp_shared/ven_fp_trans.sv"
  "$OUT/ven_fp_top_old.sv"
  "$ROOT/fp_shared/ven_fp_top.sv"
  "$ROOT/fp_shared/tb/tb_ven_fp_srt_top_ab.sv"
)
sha256sum "${SOURCE_INPUTS[@]}" "$OUT/ven_fp_top_old.sv" > "$OUT/input.sha256"

run_variant() {
  local variant="$1"
  shift
  local -a variant_defs=("$@")
  mkdir -p "$OUT/$variant"
  timeout --foreground "${TIMEOUT_SECS}s" env TMPDIR="$OUT/tmp" CCACHE_DISABLE=1 \
    "$ROOT/tools/verilator_serial.sh" --binary --timing --assert -j "$VL_J" \
    --output-groups 0 --output-split 20000 --output-split-cfuncs 20000 \
    -sv -Wall -Wno-fatal -Wno-UNUSED \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
    -Werror-LATCH -Werror-UNOPTFLAT --top-module tb_ven_fp_srt_top_ab \
    +define+VEN_FPREM "${variant_defs[@]}" -I"$ROOT/rtl/fpu" --Mdir "$OUT/$variant/obj" \
    "${COMPILED_SOURCES[@]}" > "$OUT/$variant/build.log" 2>&1
  timeout --foreground "${TIMEOUT_SECS}s" "$OUT/$variant/obj/Vtb_ven_fp_srt_top_ab" \
    > "$OUT/$variant/run.log" 2>&1
  rg -qx 'FP-SRT-TOP-AB-OK matrix=12 checks=396' "$OUT/$variant/run.log" ||
    die "gate marker missing: $OUT/$variant/run.log"
}

cd "$ROOT"
run_variant base
run_variant stream +define+VEN_FP_ARITH_STREAM +define+VEN_FP_PERF
run_variant stream_fwd +define+VEN_FP_ARITH_STREAM +define+VEN_FP_ARITH_FWD +define+VEN_FP_PERF
sha256sum --check "$OUT/input.sha256"
printf 'FP-SRT-TOP-AB-GATE-OK variants=base,stream,stream_fwd jobs=%s artifacts=%s\n' "$VL_J" "$OUT"
