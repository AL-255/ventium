#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Explicit, tiny Icarus-only proposal check. Never invokes the whole-core flow.
set -euo pipefail

proposal_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
if [[ "${1:-}" != --under-limit ]]; then
  if [[ $# != 0 ]]; then
    echo "usage: bash $0" >&2
    exit 2
  fi
  exec timeout --foreground 120s bash "$0" --under-limit
fi
if [[ $# != 1 ]]; then exit 2; fi
ulimit -c 0
ulimit -v 524288
repo_root="$(cd -- "$proposal_dir/../../../.." && pwd)"
for required_tool in python3 iverilog vvp; do
  command -v "$required_tool" >/dev/null || {
    echo "missing required tool: $required_tool" >&2
    exit 2
  }
done
proposal_scratch="$(mktemp -d /var/tmp/ventium-ic-residency-miter.XXXXXX)"
echo "Proposal artifacts retained: $proposal_scratch"
python3 "$proposal_dir/extract_reference.py" \
  --core "$repo_root/rtl/core/core.sv" \
  --output "$proposal_scratch/ic_residency_reference.svh"
for variant in bypass no_bypass; do
  variant_args=(-DVEN_IC_BRAM)
  if [[ "$variant" == no_bypass ]]; then
    variant_args+=(-DVEN_IC_NO_FETCH_BYPASS)
  fi
  iverilog -g2012 -gstrict-ca-eval -s tb_ic_residency_span \
    "${variant_args[@]}" -I"$proposal_scratch" -I"$proposal_dir" \
    -o "$proposal_scratch/$variant.vvp" "$proposal_dir/tb_ic_residency_span.sv"
  vvp "$proposal_scratch/$variant.vvp" | tee "$proposal_scratch/$variant.log"
done
echo "IC-RESIDENCY-PROPOSAL-MITER-OK (helper/caller miter only; no production wiring or FPGA claim)"
