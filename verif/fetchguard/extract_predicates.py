#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Source-link the small fetch guards into a standalone predicate test.

The generated SV contains the production RHS verbatim (apart from comments),
not another implementation of the DUT. Unknown dependencies fail compilation;
an absent/ambiguous named production assignment fails extraction.
"""

import argparse
import hashlib
import json
import re
from pathlib import Path


NAMES = (
    "pipe_fetch_checked_handoff",
    "fetch_fault_linear",
    "fetch_fault_page",
    "fetch_overlength_probe",
    "cs_fetch_fault",
    "cs_extent_fault",
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def uncomment(text):
    # Neither strings nor escaped identifiers occur in these pure predicates.
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def extract(text, name):
    if name.startswith("cs_"):
        marker = "`ifdef VEN_SEG_ENFORCE\n    cs_fetch_fault ="
        if text.count(marker) != 1:
            raise ValueError("missing/ambiguous enforcement predicate block")
        text = text.split(marker, 1)[1]
        text = "    cs_fetch_fault =" + text.split("`else", 1)[0]
    clean = uncomment(text)
    pattern = rf"(?m)^\s*(?:assign\s+)?{re.escape(name)}\s*=\s*([^;]+);"
    matches = re.findall(pattern, clean)
    if len(matches) != 1:
        raise ValueError(f"{name}: expected one production assignment, got {len(matches)}")
    rhs = matches[0].strip()
    if "`" in rhs:
        raise ValueError(f"{name}: conditional RHS requires explicit extraction review")
    return rhs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--core", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if not args.out.is_dir():
        raise ValueError("--out must be an existing, caller-owned output directory")
    raw = args.core.read_bytes()
    text = raw.decode("utf-8")
    fragments = {name: extract(text, name) for name in NAMES}
    rendered = "// Exact production predicate RHS: see source-link.json.\n"
    rendered += "\n".join(f"assign {name} = {rhs};" for name, rhs in fragments.items()) + "\n"
    encoded = rendered.encode("utf-8")
    (args.out / "production_predicates.svh").write_bytes(encoded)
    receipt = {
        "source": str(args.core.resolve()),
        "source_sha256": digest(raw),
        "generated_sha256": digest(encoded),
        "predicates": {
            name: {"rhs_sha256": digest(rhs.encode()), "rhs": rhs}
            for name, rhs in fragments.items()
        },
        "coverage": "Combinational predicate leaf only; not a core/guest architectural pass.",
    }
    (args.out / "source-link.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
