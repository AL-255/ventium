#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Actual VGA plane/latch device test only; never builds a CPU or opens a disk.
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ $# == 2 && "$1" == --out ]] || { echo 'usage: bash verif/axivgalanes/run-planar-gate.sh --out FRESH_OWNED_OUTPUT'; exit 2; }
out="$(realpath -- "$2")"
[[ -d "$out" && ! -L "$out" && ! -e "$out/inputs.before.sha256" &&
   "$(stat -c %u "$out")" == "$UID" ]] || exit 2
case "$out" in "$repo"/verif/l1/obj_dir_axivgalanes_planar_*) ;; *) exit 2 ;; esac
git -C "$repo" check-ignore -q -- "$out"
available="$(df -B1 --output=avail "$repo" | tail -n 1 | tr -d ' ')"
(( available >= 1073741824 )) || { echo 'less than1GiB leaf scratch headroom'; exit 2; }
bridge="${AXIVGALANES_PLANAR_BRIDGE:-$repo/ao486-sim/ven/ven_axi2avalon.sv}"
bridge="$(realpath -e -- "$bridge")"
[[ -f "$bridge" && ! -L "$bridge" && "$(stat -c %u "$bridge")" == "$UID" ]] || exit 2
if [[ "$bridge" != "$repo/ao486-sim/ven/ven_axi2avalon.sv" ]]; then
  # Only the reviewed retained old source may replace the adapter; all DUT
  # endpoint/primitive/TB sources remain byte-identical between red and green.
  [[ "$bridge" == "$out/red-source/ven_axi2avalon.sv" ]] || exit 2
  [[ "$(sha256sum "$bridge" | cut -d ' ' -f 1)" == a4c3101aaa9ff29f6818a6fedc3f5903485e0db7b38a846d57429f57edf1b62f ]] || exit 2
fi
export TMPDIR="$out/compiler-tmp"
mkdir -m 700 "$TMPDIR"
export VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32
export AXIVGALANES_PLANAR_ASSERT="${AXIVGALANES_PLANAR_ASSERT:-1}"
[[ "$AXIVGALANES_PLANAR_ASSERT" == 0 || "$AXIVGALANES_PLANAR_ASSERT" == 1 ]] || exit 2
cd "$repo"
sha256sum "$bridge" 3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v \
  3rd-party/ao486_MiSTer/rtl/soc/vga.v ao486-sim/stubs/sim_prims.sv \
  verif/axivgalanes/tb_axivgalanes_planar.sv verif/axivgalanes/run-planar-gate.sh \
  verif/axivgalanes/tb_axivgalanes.sv verif/axivgalanes/tb_axivgalanes_hold.sv \
  verif/axivgalanes/run-gate.sh verif/l1/romwrite_ao486_primitive.vlt \
  verif/fetchguard/record_resources.py tools/build_scope.sh > "$out/inputs.before.sha256"
printf '%s\n' "$AXIVGALANES_PLANAR_ASSERT" > "$out/bridge-assert.enabled"
printf '%s\n' "$bridge" > "$out/bridge-source.path"
set +e
timeout --signal=TERM --kill-after=10s 540s tools/build_scope.sh -- bash -c '
  set -euo pipefail; repo="$1"; out="$2"; bridge="$3"; ulimit -c 0; export CCACHE_DISABLE=1;
  "$repo/tools/build_scope.sh" --is-active;
  python3 "$repo/verif/fetchguard/record_resources.py" --phase before --out "$out/resources.before.json";
  trap '\''python3 "$repo/verif/fetchguard/record_resources.py" --phase after --out "$out/resources.after.json"'\'' EXIT;
  archive_pch() {
    local pch="$1" expected identity rawbytes rawallocated partial expanded archive_identity archive_sha tag;
    [[ "$pch" == "$out/$profile/obj/Vtb_axivgalanes_planar__pch.h.fast.gch" ||
       "$pch" == "$out/$profile/obj/Vtb_axivgalanes_planar__pch.h.slow.gch" ]] || exit 2;
    [[ -f "$pch" && ! -L "$pch" && "$(realpath -e -- "$pch")" == "$pch" ]] || exit 2;
    [[ "$(stat -c "%u:%h" -- "$pch")" == "$UID:1" ]] || exit 2;
    git -C "$repo" check-ignore -q -- "$pch";
    [[ ! -e "$pch.recovery.gz" && ! -L "$pch.recovery.gz" ]] || exit 2;
    expected="$(sha256sum -- "$pch" | cut -d " " -f 1)";
    identity="$(stat -c "%d:%i:%s:%y:%z:%u:%h:%a" -- "$pch")";
    rawbytes="$(stat -c %s -- "$pch")";
    rawallocated="$(( $(stat -c %b -- "$pch") * $(stat -c %B -- "$pch") ))";
    tag="$out/$profile/$(basename "$pch")";
    if fuser "$pch" > "$tag.prepack.fuser.out" 2> "$tag.prepack.fuser.err"; then
      echo "active PCH reference: $pch" >&2; exit 2;
    else
      [[ "$?" == 1 && ! -s "$tag.prepack.fuser.out" && ! -s "$tag.prepack.fuser.err" ]] || exit 2;
    fi;
    printf "%s\t%s\t%s\t%s\n" "$pch" "$rawbytes" "$expected" "$identity" >> "$out/$profile/pch-recovery-inputs.tsv";
    partial="$(mktemp "$out/$profile/obj/.pch-recovery.XXXXXXXX")";
    gzip -n -1 -c -- "$pch" > "$partial";
    gzip -t -- "$partial";
    expanded="$(gzip -cd -- "$partial" | sha256sum)";
    [[ "${expanded%% *}" == "$expected" ]] || exit 2;
    [[ "$(stat -c "%d:%i:%s:%y:%z:%u:%h:%a" -- "$pch")" == "$identity" &&
       "$(sha256sum -- "$pch" | cut -d " " -f 1)" == "$expected" ]] || exit 2;
    [[ ! -e "$pch.recovery.gz" && ! -L "$pch.recovery.gz" ]] || exit 2;
    mv -n -- "$partial" "$pch.recovery.gz";
    [[ ! -e "$partial" && -f "$pch.recovery.gz" && ! -L "$pch.recovery.gz" &&
       "$(realpath -e -- "$pch.recovery.gz")" == "$pch.recovery.gz" &&
       "$(stat -c "%u:%h" -- "$pch.recovery.gz")" == "$UID:1" ]] || exit 2;
    archive_identity="$(stat -c "%d:%i:%s:%y:%z:%u:%h:%a" -- "$pch.recovery.gz")";
    gzip -t -- "$pch.recovery.gz";
    expanded="$(gzip -cd -- "$pch.recovery.gz" | sha256sum)";
    [[ "${expanded%% *}" == "$expected" ]] || exit 2;
    archive_sha="$(sha256sum -- "$pch.recovery.gz" | cut -d " " -f 1)";
    if fuser "$pch" > "$tag.preunlink.fuser.out" 2> "$tag.preunlink.fuser.err"; then
      echo "active PCH reference before unlink: $pch" >&2; exit 2;
    else
      [[ "$?" == 1 && ! -s "$tag.preunlink.fuser.out" && ! -s "$tag.preunlink.fuser.err" ]] || exit 2;
    fi;
    [[ "$(stat -c "%d:%i:%s:%y:%z:%u:%h:%a" -- "$pch")" == "$identity" &&
       "$(sha256sum -- "$pch" | cut -d " " -f 1)" == "$expected" &&
       "$(stat -c "%d:%i:%s:%y:%z:%u:%h:%a" -- "$pch.recovery.gz")" == "$archive_identity" ]] || exit 2;
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$pch" "$rawbytes" "$expected" \
      "$(stat -c %s -- "$pch.recovery.gz")" "$archive_sha" "$rawallocated" \
      "$(( $(stat -c %b -- "$pch.recovery.gz") * $(stat -c %B -- "$pch.recovery.gz") ))" "$identity" \
      >> "$out/$profile/pch-recovery.tsv";
    rm -- "$pch";
    [[ ! -e "$pch" && ! -L "$pch" ]] || exit 2;
    printf "RECOVERABLE-LEAF-PCH-REMOVED %s\n" "$pch";
  };
  any_red=0;
  for profile in baseline production; do
    defs=(); if [[ "$profile" == production ]]; then
      defs=(-DVEN_CORE -DVEN_AXI2AVL_BPIPE -DVEN_AXI2AVL_WRITE_THROUGH -DVEN_VGA_FULL_STORE_SETUP -DVEN_VGA_WIDE_STORE);
    fi;
    if [[ "$AXIVGALANES_PLANAR_ASSERT" == 1 ]]; then defs+=(-DVEN_AXI2AVL_ASSERT); fi;
    mkdir "$out/$profile";
    printf "%s\\n" "${defs[@]}" > "$out/$profile/defines.txt";
    verilator --binary --timing --assert -sv -j 32 -Wall -Wno-UNUSED -Wno-fatal \
      -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
      -Werror-LATCH -Werror-UNOPTFLAT "${defs[@]}" \
      --top-module tb_axivgalanes_planar -Mdir "$out/$profile/obj" -o tb_axivgalanes_planar \
      "$repo/verif/l1/romwrite_ao486_primitive.vlt" \
      "$repo/verif/axivgalanes/tb_axivgalanes_planar.sv" "$bridge" \
      "$repo/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v" \
      "$repo/3rd-party/ao486_MiSTer/rtl/soc/vga.v" "$repo/ao486-sim/stubs/sim_prims.sv" \
      > "$out/$profile/build.log" 2>&1;
    # Compilation has closed before either exact generated PCH is archived.
    # They are compiler-only artifacts, not runtime model inputs. On failure,
    # retain both the raw file and any partial archive; never remove a model.
    printf "original\traw_bytes\traw_sha256\tarchive_bytes\tarchive_sha256\traw_allocated_bytes\tarchive_allocated_bytes\traw_identity_nanosecond\n" > "$out/$profile/pch-recovery.tsv";
    printf "original\traw_bytes\traw_sha256\traw_identity_nanosecond\n" > "$out/$profile/pch-recovery-inputs.tsv";
    archive_pch "$out/$profile/obj/Vtb_axivgalanes_planar__pch.h.fast.gch";
    archive_pch "$out/$profile/obj/Vtb_axivgalanes_planar__pch.h.slow.gch";
    [[ "$(wc -l < "$out/$profile/pch-recovery.tsv")" == 3 ]] || exit 2;
    bytes="$(du -sb "$out" | cut -f 1)";
    (( bytes <= 314572800 )) || { echo "leaf output exceeds300MiB: $bytes"; exit 2; };
    set +e; "$out/$profile/obj/tb_axivgalanes_planar" > "$out/$profile/run.log" 2>&1; native="$?"; set -e;
    printf "%s\\n" "$native" > "$out/$profile/native.exit";
    [[ "$native" == 0 ]] || any_red=1;
  done;
  exit "$any_red"' bash "$repo" "$out" "$bridge"
status="$?"
set -e
printf '%s\n' "$status" > "$out/gate.exit"
sha256sum --check "$out/inputs.before.sha256" > "$out/input-check.after.log"
for profile in baseline production; do
  if [[ -e "$out/$profile/run.log" ]]; then rg 'AXIVGALANES-PLANAR-(SUMMARY|GATE)' "$out/$profile/run.log" || true; fi
done
du -sb "$out" > "$out/output-size.txt"
echo "AXIVGALANES-PLANAR runner exit=$status artifacts=$out"
exit "$status"
