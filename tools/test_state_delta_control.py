#!/usr/bin/env python3
"""Tiny synthetic phase/partition regression for state_delta_analyze.

Usage: python3 tools/test_state_delta_control.py /path/to/state_delta_analyze
No simulator, guest image, private references, or full trace is required.
"""
import csv
import gzip
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

CORE = "system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__"
L1 = "system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__"
source = Path(__file__).with_name("state_delta_analyze.cpp").read_text()
# Include every mandatory field, independent of its position in the schema.
names = sorted({{"core+": CORE, "l1+": L1, "": ""}[prefix] + name
                for prefix, name in re.findall(r'field\((core\+|l1\+)?"([^"]+)"\)', source)})
sizes = {CORE + "pp_bail": 112, CORE + "snap": 48, CORE + "gpr_o": 32,
         L1 + "u_l1d__DOT__dc_val": 256, L1 + "u_l1d__DOT__dc_tag": 1024}
layout = {}
offset = 0
header = bytearray()
for name in names:
    size = sizes.get(name, 8)
    layout[name] = (offset, size)
    offset += size
    for text in (name, "fixture"):
        encoded = text.encode()
        header += struct.pack("<I", len(encoded)) + encoded
    header += struct.pack("<I", size)
state = bytearray(offset)


def set_value(name, value, absolute=False):
    off, size = layout[name if absolute else CORE + name]
    state[off:off + size] = value.to_bytes(size, "little")


set_value("state", 28)
set_value("pipe_frontend_ready", 1)
set_value("fsm_case_enabled", 1)
set_value("btb_resolve_valid", 1)
set_value("btb_resolve_pc", 0x1234)
set_value("btb_resolve_taken", 1)
initial = bytes(state)
cases = [
    ({"registered": 1}, "registered_retire_awaiting_report"),
    ({}, None),  # the preceding retirement is reported NOW, not at capture
    ({"pipe_int_commit": 1}, "integer_commit_ready_next_edge"),
    ({"fp_issue_block": 1}, "issue_block"),
    ({"fsm_case_enabled": 0}, "fsm_fault_or_diversion"),
    ({"stall_cnt": 3}, "stall_countdown"),
    ({"pending_mem_pen": 2}, "pending_memory_penalty"),
    ({"fp_sys_bail": 1}, "slow_integer_dispatch"),
    ({"mispred_bubbles": 2}, "branch_recovery"),
    ({"pipe_agi": 1}, "agi_interlock"),
    ({}, "other"),
    ({"pipe_mem_wait": 1}, "fresh_memory_admission_wait"),
    ({"fp_async_hold": 1}, None),
    ({"pipe_mem_active_q": 1}, None),
    ({"pipe_frontend_ready": 0}, None),
    ({"state": 3}, None),
]
rv = "system__DOT__u_cpu__DOT__u_core__DOT__core_retire_valid"
resets = {key for updates, _ in cases for key in updates if key != "registered"}
records = bytearray()
retired = 0
for index, (updates, _) in enumerate(cases):
    previous = bytes(state)
    retired += int.from_bytes(previous[layout[rv][0]:layout[rv][0]+8], "little")
    for key in resets:
        set_value(key, 0)
    set_value("state", 28)
    set_value("pipe_frontend_ready", 1)
    set_value("fsm_case_enabled", 1)
    set_value(rv, updates.get("registered", 0), absolute=True)
    set_value("harness.retired", retired, absolute=True)
    set_value("btb_resolve_valid", 0)
    for key, value in updates.items():
        if key != "registered":
            set_value(key, value)
    # At each edge one diagnostic counter increments, selected deliberately
    # independently of the post-settled category to catch an aggregate join.
    off, _ = layout[CORE + "pp_bail"]
    bucket = index % 14
    value = struct.unpack_from("<Q", state, off + 8*bucket)[0] + 1
    struct.pack_into("<Q", state, off + 8*bucket, value)
    changed = []
    for pos in range(0, len(state), 16):
        bits = [i for i in range(min(16, len(state)-pos)) if state[pos+i] != previous[pos+i]]
        if bits:
            mask = sum(1 << i for i in bits)
            changed.append(struct.pack("<IH", pos, mask) + bytes(state[pos+i] for i in bits))
    records += struct.pack("<QI", 101 + index, len(changed)) + b"".join(changed)
raw = (b"VENDLT01" + struct.pack("<IQQI", len(names), 100, len(cases), len(state))
       + header + initial + records + b"ENDDLT01" + struct.pack("<Q", len(cases)) + state)
with tempfile.TemporaryDirectory(prefix="ventium-control-fixture.") as tmp:
    path = Path(tmp)
    trace = path / "fixture.gz"
    trace.write_bytes(gzip.compress(raw))
    subprocess.run([sys.argv[1], str(trace), str(path / "analysis")], check=True)
    with (path / "analysis.summary.tsv").open() as stream:
        summary = dict(csv.reader(stream, delimiter="\t"))
    expected = sum(reason is not None for _, reason in cases)
    assert int(summary["ready_control_residual_total"]) == expected
    for _, reason in cases:
        if reason:
            assert summary["ready_control_residual_" + reason] == "1", reason
    with (path / "analysis.ready_control.tsv").open() as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    assert sum(int(row["cycles"]) for row in rows) == expected
    registered = next(row for row in rows if row["registered_retire"] == "1")
    assert registered["edge_bail_bucket"] == "0"
    assert registered["previous_state"] == "28"
    assert summary["edge_retired"] == summary["retired"] == "1"
    assert summary["initial_registered_retire"] == summary["final_registered_retire"] == "0"
    assert int(summary["no_edge_retire_total"]) == len(cases)-1
    with (path / "analysis.edge_joint.tsv").open() as stream:
        edges = list(csv.DictReader(stream, delimiter="\t"))
    assert sum(int(row["cycles"]) for row in edges) == len(cases)
    assert sum(int(row["cycles"])*int(row["edge_retired"]) for row in edges) == 1
    # A post-edge hold belongs to the FOLLOWING decision edge. Likewise a
    # just-ended interlock remains the cause even though settled controls clear.
    assert summary["no_edge_retire_ready_control_agi_interlock"] == "1"
    assert summary["no_edge_retire_memory_wait_including_admission"] == "1"
    with (path / "analysis.branches.tsv").open() as stream:
        assert list(csv.DictReader(stream, delimiter="\t")) == [
            {"cycle": "101", "pc": "1234", "taken": "1"}]
    assert (path / "analysis.initial.bin").read_bytes() == initial
    assert (path / "analysis.final.bin").read_bytes() == state
    # The minimal fixture has no I-cache tag/BRAM layout. The new byte
    # producer must fail closed, not manufacture an instruction from q_pc.
    with (path / "analysis.fast_issue_bytes.tsv").open() as stream:
        assert list(csv.DictReader(stream, delimiter="\t")) == []
    with (path / "analysis.slow_candidate_bytes.tsv").open() as stream:
        assert list(csv.DictReader(stream, delimiter="\t")) == []
print("STATE-DELTA-CONTROL-TEST-OK (phase, disjoint partition, counter join, exact bookends)")
