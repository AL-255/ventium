#!/usr/bin/env python3
"""Private multi-page permission shadow; preserve default RTL byte for byte."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FLAG = 'VEN_IFETCH_AUTH_MULTI'
OLD = '''  assign if_auth_ok = !paging_on || (if_auth_valid_q &&
                       (if_auth_page_q == flin[31:12]) &&
                       ((eff_cpl != 2'd3) || if_auth_user_q));'''


def transform(text):
    if FLAG in text or text.count(OLD) != 1:
        raise ValueError('ambiguous, absent or already modified authorization')
    return text.replace(OLD, '''`ifdef VEN_IFETCH_AUTH_MULTI
  `include "core_ifetch_auth_multi.svh"
`else
''' + OLD + '\n`endif')


def pins(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output must not be inside source')
    before = pins(source)
    leaf = 'rtl/core/core.sv'
    changed = transform((source / leaf).read_text())
    shutil.copytree(source, output)
    (output / leaf).write_text(changed)
    include = Path(__file__).with_name('core_ifetch_auth_multi.svh')
    dest = 'rtl/core/' + include.name
    assert dest not in before
    shutil.copyfile(include, output / dest)
    after = pins(output)
    assert after.keys() == before.keys() | {dest}
    assert [p for p in before if before[p] != after[p]] == [leaf]
    assert pins(source) == before
    record = dict(parent=str(source), parent_pins=before, candidate_pins=after,
                  gameplay_ipc=None, standard_suite=False, production_selected=False)
    (output / 'ifetch-auth-multi-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
