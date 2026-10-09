#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export TMPDIR="${TMPDIR:-/home/yukidama/external/tmp}"
[[ -d "$TMPDIR" && -w "$TMPDIR" ]] || { echo "TMPDIR unavailable" >&2; exit 2; }
out="$(mktemp -d "$TMPDIR/ventium-bfm-policy-unit.XXXXXXXX")"
echo "Artifacts: $out"
timeout --signal=TERM --kill-after=5s 60s "${CXX:-g++}" -std=c++17 -Wall -Wextra -Werror \
  -I"$root/verif/tb" "$root/verif/tb/test_bfm_store_policy.cpp" -o "$out/test"
"$out/test"
