#!/usr/bin/env python3
"""Private data-read priming during a separate instruction-buffer fill."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FLAG = 'VEN_L1D_PRIME_UNDER_IFILL'
ANCHOR = '''`ifdef VEN_L1D_CODE_BUFFER
           !code_fill_q &&
`endif
           (c_next_addr[OFFW +: IDXW] != fset))'''
REPLACEMENT = '''`ifdef VEN_L1D_PRIME_UNDER_IFILL
           // The I fill owns code_line_q, not any D-array bank/tag/LRU.
           // A committed resident D hint may use the same set; the old
           // D-fill path still excludes its replacement set. Reject an
           // instruction-shaped live port: its payload selector is not D.
           (code_fill_q ? !code_access :
            (c_next_addr[OFFW +: IDXW] != fset)))
`else
''' + ANCHOR + '\n`endif'


def transform(text):
    if FLAG in text or text.count(ANCHOR) != 1:
        raise ValueError('missing, ambiguous or already modified prime-I-fill anchor')
    if 'VEN_L1D_DATA_UNDER_IFILL' not in text:
        raise ValueError('requires the independently tested ordinary D/I overlap source')
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
    (output / 'prime-under-ifill-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
