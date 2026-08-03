#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 H-08 + C-06: the SILENTLY-UNIMPLEMENTED sequences must stay unreachable.
#
# Two architectural sequences this core does not implement fail SILENTLY rather than
# loudly, which is why each got an instrument during this review:
#
#   VEN-NTRET    IRET with EFLAGS.NT=1 -- an NT task-return should switch through the
#                current TSS backlink. IRET never examines NT, so such an IRET is
#                treated as an ordinary return and the machine keeps running in the
#                wrong task.                                            (H-08)
#   VEN-RETFOUT  protected RETF whose popped CS.RPL > CPL -- a return to an OUTER
#                privilege level should pop and validate SS:ESP and discard the inner
#                frame. This core reuses far-JMP semantics, so CPL takes the popped RPL
#                while SS:ESP stay the INNER ones.                       (C-06)
#
# Neither was made a fault: both are LEGAL operations the core does not implement, and
# the workloads that would say whether real guests use them (m7 Quake / Win95) are
# excluded from verify-all. So they were instrumented and measured instead.
#
# THIS GATE EXISTS BECAUSE AN INSTRUMENT NOBODY READS IS NOT AN INSTRUMENT. PROGRESS2
# section 3.5 records exactly that failure: the PAGING/C-03 assertion printed into a log
# for a whole cycle with nothing grepping it. A nonzero count here is NOT a regression in
# the usual sense -- it means one of these paths became REACHABLE, and the honest
# response is to implement the sequence (or halt), not to silence the counter.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB="$REPO/verif/tb/${OBJDIR:-obj_dir}/tb_ventium"

echo "== REVIEW2_aug2 H-08/C-06: unimplemented sequences must stay unreachable =="
[[ -x "$TB" ]] || { echo "  SKIP: $TB missing"; exit 0; }

n=0; nt=0; rf=0; hit=""
for d in "$REPO"/verif/sys/tests/*/; do
  t="$(basename "$d")"; img="$d$t.bin"
  [[ -f "$img" ]] || continue
  n=$((n+1))
  out="$("$TB" --image "$img" --system --out /dev/null --max-insn 4000 --quiesce 400 2>&1 || true)"
  a="$(printf '%s\n' "$out" | grep -c 'VEN-NTRET'   || true)"
  b="$(printf '%s\n' "$out" | grep -c 'VEN-RETFOUT' || true)"
  nt=$((nt+a)); rf=$((rf+b))
  [[ "$a" != "0" || "$b" != "0" ]] && hit="$hit $t(NT=$a,RETF=$b)"
done

echo "  images swept: $n"
echo "  NT task-returns (H-08)      : $nt   (want 0)"
echo "  outer-level RETFs (C-06)    : $rf   (want 0)"

if [[ "$nt" == "0" && "$rf" == "0" ]]; then
  echo "  ok   neither unimplemented sequence is reached by this corpus"
  echo "  NOTE this is CORPUS COVERAGE, not proof of unreachability -- the same"
  echo "       distinction the review draws about C-04's \"0 in 68 images\"."
  echo "UNIMPL-GATE-OK"; exit 0
fi
echo "  REACHED:$hit"
echo "  FAIL a path this core does not implement is now being EXERCISED, and today it"
echo "       fails silently -- wrong task (NT) or outer code on the inner stack (RETF)."
echo "       The fix is to implement the sequence or halt loudly, NOT to silence this."
echo "UNIMPL-GATE-FAIL"; exit 1
