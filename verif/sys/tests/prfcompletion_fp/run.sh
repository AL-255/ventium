#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Prepared sources only; root must review before authorizing execution.
set -euo pipefail
RF_SUITE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RF_REPO="$(cd -- "${RF_SUITE}/../../../.." && pwd)"
exec "$RF_REPO/tools/build_scope.sh" -- prlimit --as=4294967296 --core=0 -- \
  timeout --kill-after=5s 520s /usr/bin/python3 "$RF_SUITE/run-prfcompletion-fp.py" --execute "$@"
