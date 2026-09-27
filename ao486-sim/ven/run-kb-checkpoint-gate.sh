#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_bin="$(mktemp "${TMPDIR:-/tmp}/ven-kb-checkpoint.XXXXXX")"
trap 'rm -f -- "$test_bin"' EXIT
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror \
    -I"$here" "$here/test_kb_checkpoint.cpp" -o "$test_bin"
"$test_bin"
echo 'KB-CHECKPOINT-GATE-OK'
