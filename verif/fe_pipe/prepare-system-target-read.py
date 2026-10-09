#!/usr/bin/env python3
"""Backport existing resolved-target I-BRAM steering to checked system clients."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FLAG = 'VEN_P54_CTRL_TARGET_SYSTEM'
OLD = '''  if (cycle_mode && !sys_mode && !soc_en && !cosim_en && !def16 &&
      !paging_on && !smm_active && (fbase == 32'd0) &&
      (q_kind == K_CTRL)) begin'''
NEW = '''`ifdef VEN_P54_CTRL_TARGET_SYSTEM
  // Read addresses only: no request, translation, allocation, LRU touch or
  // instruction admission. The returned set/way/collision and normal fetch
  // permissions still own consumption after the architectural redirect.
  if (cycle_mode && !def16 && !smm_active &&
      ((!sys_mode && !soc_en && !cosim_en && !paging_on && fbase==32'd0) ||
       (sys_mode && sys_fp_ok && !real_mode && !v86 && cs_d &&
        !fp_dbg_active && !dbg_block_issue)) && (q_kind == K_CTRL)) begin
`else
''' + OLD + '\n`endif'


def transform(text):
    if FLAG in text or text.count(OLD) != 1:
        raise ValueError('missing, ambiguous or already modified target context')
    text = text.replace(OLD, NEW)
    ret = '''        p54_ctrl_target_addr = (q_w == 3'd2)
                                ? {16'd0, mem_load_data[15:0]} : mem_load_data;'''
    if text.count(ret) != 1 or text.count('p54_ctrl_target_addr = call_target;') != 2:
        raise ValueError('target resolver drift')
    text = text.replace(ret, '''`ifdef VEN_P54_CTRL_TARGET_SYSTEM
        p54_ctrl_target_addr = fbase + ((q_w == 3'd2)
                                ? {16'd0, mem_load_data[15:0]} : mem_load_data);
`else
''' + ret + '\n`endif')
    text = text.replace('p54_ctrl_target_addr = call_target;',
        '''p54_ctrl_target_addr =
`ifdef VEN_P54_CTRL_TARGET_SYSTEM
                              fbase +
`endif
                              call_target;''')
    return text


def pins(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output cannot be inside source')
    before = pins(source)
    leaf = 'rtl/core/core_ctrl_target_read.svh'
    changed = transform((source / leaf).read_text())
    shutil.copytree(source, output)
    (output / leaf).write_text(changed)
    after = pins(output)
    assert before.keys() == after.keys()
    assert [p for p in before if before[p] != after[p]] == [leaf]
    assert pins(source) == before
    record = dict(parent=str(source), parent_pins=before, candidate_pins=after,
                  gameplay_ipc=None, standard_suite=False, production_selected=False)
    (output / 'system-target-read-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
