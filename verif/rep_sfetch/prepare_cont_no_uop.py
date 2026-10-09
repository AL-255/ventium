#!/usr/bin/env python3
"""Opt-in private REP retained-command profile without a decoded-uop cache.

Only the profile admission changes. Existing decode, retirement, fault,
interrupt, invalidation and cancellable next-element owners are untouched.
Not production selection or acceptance of this candidate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FLAG = 'VEN_REP_CONT_NO_UOP'
OLD = '''`ifdef VEN_UOP_SFETCH
  assign rep_stos_cont_profile = cycle_mode;
`else
  assign rep_stos_cont_profile = 1'b0;
`endif'''
NEW = '''`ifdef VEN_UOP_SFETCH
  assign rep_stos_cont_profile = cycle_mode;
`elsif VEN_REP_CONT_NO_UOP
  // q_* is the ordinary decoder's retained command, not a uop-cache entry.
  // An exact REP shape can use the same checked next-element owner without
  // enabling uop fetch/cache. Every existing event, poison, debt, translation,
  // debug and rollback guard below remains authoritative.
  assign rep_stos_cont_profile = cycle_mode;
`else
  assign rep_stos_cont_profile = 1'b0;
`endif'''


def transform(text):
    if FLAG in text or text.count(OLD) != 1:
        raise ValueError('REP profile already changed or missing/ambiguous anchor')
    return text.replace(OLD, NEW)


def pins(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output cannot be inside source')
    before = pins(source)
    leaf = 'rtl/core/core.sv'
    changed = transform((source / leaf).read_text())
    shutil.copytree(source, output)
    (output / leaf).write_text(changed)
    after = pins(output)
    assert before.keys() == after.keys()
    assert [p for p in before if before[p] != after[p]] == [leaf]
    assert pins(source) == before
    record = dict(parent=str(source), parent_pins=before, candidate_pins=after,
                  gameplay_ipc=None, standard_suite=False, production_selected=False)
    (output / 'rep-cont-no-uop-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
