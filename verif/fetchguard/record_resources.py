#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Retain the actual leaf-build cgroup limits/events; never declare a pass."""

import argparse
import json
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--phase", choices=("before", "after"), required=True)
    args = parser.parse_args()
    rows = Path("/proc/self/cgroup").read_text().splitlines()
    groups = [row.split(":", 2)[2] for row in rows if row.startswith("0::")]
    if len(groups) != 1:
        raise ValueError("expected one cgroup-v2 membership")
    relative = groups[0]
    if "/ventium-ipc-parallel32.scope" not in relative:
        raise ValueError("not in the requested guarded 32-job scope")
    group = Path("/sys/fs/cgroup") / relative.lstrip("/")
    keys = (
        "memory.max", "memory.swap.max", "memory.current", "memory.peak",
        "memory.events", "pids.max", "pids.current", "cgroup.events",
    )
    values = {key: (group / key).read_text().strip() for key in keys}
    if int(values["memory.max"]) > 16 * 1024**3 or int(values["pids.max"]) > 128:
        raise ValueError("actual cgroup exceeds the reviewed leaf-build envelope")
    receipt = {
        "phase": args.phase,
        "pid": os.getpid(),
        "cgroup": relative,
        "values": values,
        "scope_verification": "The runner separately checked build_scope.sh --is-active.",
        "meaning": "Resource evidence only; not a verification result.",
    }
    args.out.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
