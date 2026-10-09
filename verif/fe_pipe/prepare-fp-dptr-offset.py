#!/usr/bin/env python3
"""Private correction of shared-x87 protected-mode data-pointer metadata.

Memory access remains linear/translated; only the saved architectural offset
changes. Preserve existing real/V86 pointer values and all queue state.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

NAME = 'rtl/core/core.sv'
OLD = '    .cmd_fdp(dbase + q_ea), .cmd_fds(arch_seg_sel(dseg)),'
NEW = '''    // Protected-mode x87 environments save segment:offset, not the
    // translated/linear bus address. Preserve real/V86 pointer values here;
    // their environment-image encoding is a separate existing contract.
    .cmd_fdp(seg_real ? (dbase + q_ea) : q_ea), .cmd_fds(arch_seg_sel(dseg)),'''


def transform(text):
    if text.count(OLD) != 1 or NEW in text:
        raise ValueError('shared x87 data-pointer anchor missing, ambiguous or already corrected')
    return text.replace(OLD, NEW)


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('source and output must be disjoint')
    pins = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.rglob('*') if p.is_file()}
    content = transform((source/NAME).read_text())
    shutil.copytree(source, output)
    (output/NAME).write_text(content)
    after = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in output.rglob('*') if p.is_file()}
    assert set(pins) == set(after)
    assert {p for p in pins if pins[p] != after[p]} == {NAME}
    assert all(hashlib.sha256((source/p).read_bytes()).hexdigest() == h for p,h in pins.items())
    return dict(parent=str(source), parent_pins=pins, candidate_pins=after,
                production=False, standard_suite=False, gameplay_ipc=None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source, args.out)
    with (args.out/'fp-dptr-offset-inputs.json').open('x') as f:
        json.dump(result, f, indent=2)
