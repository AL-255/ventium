#!/usr/bin/env python3
"""Private registered D-hit overlap with a physically separate instruction fill."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FLAG = 'VEN_L1D_DATA_UNDER_IFILL'
ANCHOR = '''                               !code_fill_q &&
                               (code_access || (set_c != fset));'''
REPLACEMENT = '''`ifdef VEN_L1D_DATA_UNDER_IFILL
                               // An I fill writes only code_line_q: neither the
                               // D banks, D tags nor D LRU installation use its
                               // set. A resident D read may use the SAME set.
                               // Its ordinary registered capture/owner, current
                               // tag validity and snoop/flush rules still apply.
                               // D fills retain their different-set restriction.
                               (code_fill_q ? !code_access :
                                (code_access || (set_c != fset)));
`else
''' + ANCHOR + '\n`endif'


def transform(text):
    if FLAG in text or text.count(ANCHOR) != 1:
        raise ValueError('missing, ambiguous or already modified I-fill overlap anchor')
    return text.replace(ANCHOR, REPLACEMENT)


def pins(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output cannot be inside source')
    before = pins(source)
    leaf = 'rtl/mem/ven_l1d.sv'
    changed = transform((source / leaf).read_text())
    shutil.copytree(source, output)
    (output / leaf).write_text(changed)
    after = pins(output)
    assert before.keys() == after.keys()
    assert [p for p in before if before[p] != after[p]] == [leaf]
    assert pins(source) == before
    record = dict(parent=str(source), parent_pins=before, candidate_pins=after,
                  gameplay_ipc=None, standard_suite=False, production_selected=False)
    (output / 'data-under-ifill-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
