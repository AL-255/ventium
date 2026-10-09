#!/usr/bin/env python3
"""Private opt-in admission of fast popping arithmetic on the last FP response.

The response is registered, and the older command has already committed. Keep
the existing leaf ready/hazard check, ordered owner accounting and precise-event
gates. No simultaneous push/pop, speculative stack map or new arithmetic port.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def transform(text):
    if 'VEN_FP_POP_DRAIN' in text:
        raise ValueError('pop drain admission already present')
    old = '''      ((((u_d.fp_kind == FK_ARITH) || (u_d.fp_kind == FK_ARITH_STI)) &&
      ((u_d.fp_aluop == 0) || (u_d.fp_aluop == 1) ||'''
    new = '''      ((((u_d.fp_kind == FK_ARITH) || (u_d.fp_kind == FK_ARITH_STI)
`ifdef VEN_FP_POP_DRAIN
       // Only the last registered response may release a popping operation.
       // Its older state mutation is already complete. The unchanged checked
       // direct arm and leaf ready still decide actual command acceptance;
       // this does not stream a pop over an unfinished ALU/stack owner.
       || ((u_d.fp_kind == FK_ARITH_STI_POP) &&
           (fp_async_count == 3'd1) && fp_shared_rsp_valid)
`endif
       ) &&
      ((u_d.fp_aluop == 0) || (u_d.fp_aluop == 1) ||'''
    if text.count(old) != 1:
        raise ValueError('expected unique stream-shape anchor')
    return text.replace(old, new)


def pins(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output may not be nested in source')
    before = pins(source)
    target = 'rtl/core/core_fp_async.svh'
    payload = transform((source / target).read_text())
    shutil.copytree(source, output)
    (output / target).write_text(payload)
    after = pins(output)
    assert set(before) == set(after)
    assert [p for p in before if before[p] != after[p]] == [target]
    assert pins(source) == before
    record = dict(parent=str(source), parent_pins=before, candidate_pins=after,
                  gameplay_ipc=None, standard_suite=False)
    (output / 'fp-pop-drain-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
