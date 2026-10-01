#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Prebuilt/frozen differential only: never build a model or guest implicitly.
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  argv=("$@")
  out=""
  for ((n=0; n<${#argv[@]}; n++)); do
    case "${argv[n]}" in
      --out) [[ $((n+1)) -lt ${#argv[@]} ]] && out="${argv[n+1]}" ;;
      --out=*) out="${argv[n]#--out=}" ;;
    esac
  done
  [[ "$out" == /* && ! -e "$out" && ! -L "$out" \
     && "$(realpath -m "$out")" == "$out" ]] \
    || { echo 'PINTSTACKWRAP-GATE-FAIL: require fresh canonical --out leaf' >&2; exit 1; }
  parent="$(dirname "$out")"
  [[ -d "$parent" && "$(stat -c %u "$parent")" == "$UID" ]] \
    || { echo 'PINTSTACKWRAP-GATE-FAIL: output parent not owned' >&2; exit 1; }
  export TMPDIR="$parent"
  exec "$ROOT/tools/build_scope.sh" -- timeout --kill-after=5s 540s bash "$0" "$@"
fi
exec python3 -B "$ROOT/verif/sys/tests/pintstackwrap/run_gate.py" "$@"
