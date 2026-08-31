#!/usr/bin/env bash
# verif/l1/run-l1axi-smram-gate.sh
# REVIEW1_Aug2 H-08: the BUILDABLE (EN_L2=0) path must deny non-SMM access to SMRAM.
#
# SMM's security model is that its RAM is invisible outside SMM -- the handler's code
# and the saved CPU state live at A0000-BFFFF. The EN_L2=1 branch enforces this through
# ven_cachemap, but those sources are on an UNMERGED branch, and the branch that
# actually builds consumed smm_active nowhere. So on the shipping configuration any
# ordinary code could read or rewrite the SMM handler.
#
# WHY THIS GATE CANNOT PASS VACUOUSLY. Two of its four cases are there to stop a
# "deny everything" implementation from looking correct:
#   A  SMM must still reach its OWN SMRAM  -> catches a check that breaks SMM outright
#   D  non-SMM must still reach 0x20000    -> catches a check that denies all memory
# and every case additionally requires an ACK, since a denied access that never
# completes would hang the core (which is how the H-07 bypass attempt failed).
#
# MEASURED both directions by hand when the fix landed: with the deny forced to 0,
# cases B and C both fail (the non-SMM write reaches SMRAM and the non-SMM read returns
# the secret). Note case C is only discriminating because the test RE-SEEDS the secret
# from SMM first -- without that, B's corruption makes C pass for the wrong reason.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

verilator -j "${VL_J:-1}" --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC --top-module tb_l1axi_smram -Mdir "$OBJ" -o tb \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" "$ROOT/verif/l1/axi_slave_bfm.sv" \
    "$ROOT/verif/l1/tb_l1axi_smram.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXISMRAM-GATE-FAIL (build)"; tail -25 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb" 2>&1)"
echo "$OUT" | grep -vE "^- |Verilator:"

if ! grep -q "L1AXISMRAM-GATE-OK" <<<"$OUT"; then
  echo "FATAL: SMRAM is not isolated on the configuration that ships."
  exit 1
fi
