#!/usr/bin/env bash
set -euo pipefail
task_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1
test "$(findmnt -T "$TMPDIR" -no FSTYPE)" = ext4
test -w "$TMPDIR"
if ! "$task_repo/tools/build_scope.sh" --is-active; then
  exec env VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
    "$task_repo/tools/build_scope.sh" -- timeout --signal=TERM --kill-after=10s 300s bash "$0" "$@"
fi
exec python3 -B "$task_repo/verif/l1/payload-cut/run-leaves.py" "$@"
