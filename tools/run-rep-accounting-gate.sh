#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_bin="$(mktemp "${TMPDIR:-/tmp}/ven-rep-accounting.XXXXXX")"
trap 'rm -f -- "$test_bin"' EXIT
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror \
    "$here/test_rep_accounting.cpp" -o "$test_bin"
"$test_bin"
echo 'REP-ACCOUNTING-GATE-OK'
