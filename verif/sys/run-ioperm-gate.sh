#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 C-07 + M-02: the TSS I/O permission bitmap must actually be consulted.
#
# CPL3 with IOPL=0, so every I/O access consults the bitmap. Ports 0x100-0x107 have
# bitmap byte 0xAA -- odd ports DENIED, even PERMITTED -- plus two WORD accesses whose
# first port is permitted and whose second is denied.
#
#   correct                      ecx = 6   PASS
#   C-07(c) only the 1st port    ecx = 4   the two word accesses stop faulting
#   C-07(b) bad bit index        a different set of ports faults -> some other count
#   C-07(a) map base = 0         reads land in unrelated TSS bytes -> some other count
#
# REQUIRES --soc-en: without it the core's I/O divert is dead and every IN/OUT halts
# as out-of-scope (see task #73). That is why this finding had no gate until now.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB="$REPO/verif/tb/${OBJDIR:-obj_dir}/tb_ventium"
IMG="$REPO/verif/sys/tests/pioperm/pioperm.bin"

echo "== REVIEW2_aug2 C-07/M-02: TSS I/O permission bitmap =="
[[ -x "$TB"  ]] || { echo "  SKIP: $TB missing"; exit 0; }
[[ -f "$IMG" ]] || { echo "  SKIP: pioperm.bin missing"; exit 0; }

TR="$(mktemp)"; trap 'rm -f "$TR"' EXIT
"$TB" --image "$IMG" --system --soc-en --out "$TR" --max-insn 8000 --quiesce 600 >/dev/null 2>&1 || true
ECX="$(tail -1 "$TR" 2>/dev/null | grep -o '"ecx":"[^"]*"' | cut -d'"' -f4 || true)"
echo "  #GP count witness ecx = ${ECX:-<none>}   (want 0x00000006)"

case "$ECX" in
  0x00000006)
    echo "  ok   every denied port faulted, including the SECOND port of each word access"
    echo "IOPERM-GATE-OK"; exit 0 ;;
  0x00000004)
    echo "  FAIL only 4 -- the word accesses did not fault on their second port, so the"
    echo "       bitmap check covers only the FIRST port of a multi-port access. C-07(c)."
    echo "IOPERM-GATE-FAIL"; exit 1 ;;
  *)
    echo "  FAIL unexpected count. A wrong bit index (C-07b) or a zero map base (C-07a)"
    echo "       both land here; an absent witness means the run never reached its exit."
    echo "IOPERM-GATE-FAIL"; exit 1 ;;
esac
