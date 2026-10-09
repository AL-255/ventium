#!/usr/bin/env python3
"""Private default-off tag RAM inference; retain every validity/owner rule."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

FLAG = 'VEN_L1D_TAG_LUTRAM'
DECL = '  logic [TAGW-1:0] dc_tag [L1_SETS][2];  // addr[31 -: TAGW]'
RESET = "        dc_tag[s][0]<=20'd0; dc_tag[s][1]<=20'd0;"
FEATURE_DECL = '''`ifdef VEN_L1D_TAG_LUTRAM
  // Validity resets independently and gates every tag comparator. Retaining
  // invalid tag bits avoids bulk reset on the distributed RAM payload; this
  // does not add a port, change lookup latency or validate an unfinished fill.
  // One unpacked address dimension is required for Vivado RAM inference.
  // Concatenate the original set and way: storage remains 128 * 2 * TAGW.
  (* ram_style = "distributed" *) logic [TAGW-1:0] dc_tag [L1_SETS*2];
`else
''' + DECL + '\n`endif'
ACCESS = re.compile(r'dc_tag\[(store_pair_set|pair_set\[lane\]|set_c|set_n|snp_set|fset)\]\[(0|1|fway)\]')


def select_feature(text, enabled):
    """Remove only our standalone guards; leave all original guards intact."""
    result, take = [], None
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped in ('`ifdef ' + FLAG, '`ifndef ' + FLAG):
            if take is not None:
                raise ValueError('nested tag feature guard')
            take = enabled if stripped.startswith('`ifdef ') else not enabled
        elif take is not None and stripped == '`else':
            take = not take
        elif take is not None and stripped == '`endif':
            take = None
        elif take is None or take:
            result.append(line)
    if take is not None:
        raise ValueError('unclosed tag feature guard')
    return ''.join(result)


def transform(text):
    if FLAG in text:
        raise ValueError('tag LUTRAM feature already present')
    for anchor in (DECL, RESET):
        if text.count(anchor) != 1:
            raise ValueError('missing/ambiguous tag RAM anchor: ' + anchor)
    changed, count = [], 0
    for line in text.splitlines(keepends=True):
        if ACCESS.search(line):
            def flatten(match):
                nonlocal count
                count += 1
                way = "1'b" + match[2] if match[2] in ('0', '1') else match[2]
                return 'dc_tag[{' + match[1] + ',' + way + '}]'
            flat = ACCESS.sub(flatten, line)
            changed.append('`ifdef ' + FLAG + '\n' + flat + '`else\n' + line + '`endif\n')
        else:
            changed.append(line)
    if count != 11:
        raise ValueError(f'expected ten lookup ports and one write, found {count}')
    result = ''.join(changed).replace(DECL, FEATURE_DECL).replace(
        RESET, '`ifndef ' + FLAG + '\n' + RESET + '\n`endif')
    assert select_feature(result, False) == text
    return result


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
    result = dict(parent=str(source), parent_pins=before, candidate_pins=after,
                  gameplay_ipc=None, standard_suite=False, production_selected=False)
    (output / 'tag-lutram-inputs.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
