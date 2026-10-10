#!/usr/bin/env python3
"""Opt-in protected-client PREFIX66; preserve its real D1 and register subset."""
import argparse
import hashlib
import json
from pathlib import Path

FLAG = 'VEN_P54_PREFIX66_SYSTEM'
TARGET = 'rtl/core/core_prefix66_d1.svh'
OLD = '''assign p54_prefix66_context_ok=!sys_mode && !soc_en && !cosim_en && !def16 &&
    !paging_on && !smm_active && (fbase==32'd0) &&
    !fp_dbg_active && !dbg_step_active;'''
NEW = '''`ifdef VEN_P54_PREFIX66_SYSTEM
`ifndef VEN_SYS_FASTPATH
  initial $fatal(1,"system PREFIX66 requires checked system fast path");
`endif
  // Architectural context only: never feed ACK/translation/issue qualification
  // back into raw decode. Same checked flat/relocated 32-bit clients as the
  // ordinary register fast path; memory, prefixes+0F and debug stay excluded.
  assign p54_prefix66_context_ok=!def16 && !smm_active &&
      !fp_dbg_active && !dbg_step_active &&
      ((!sys_mode && !soc_en && !cosim_en && !paging_on && (fbase==32'd0)) ||
       (sys_mode && sys_fp_ok && !real_mode && !v86));
  // Use the existing linear fetch PC without adding a context register. No
  // architectural context-changing instruction can execute while this paid-D1
  // owner is held in S_PIPE. Leaving that state, flush, event, debug, or snoop
  // cancels the token. Same offset in a relocated CS cannot inherit its credit.
  wire [31:0] p54_prefix66_owner_pc = flin;
`else
''' + OLD + '''
  wire [31:0] p54_prefix66_owner_pc = eip;
`endif'''


def transform(text):
    if FLAG in text or 'p54_prefix66_owner_pc' in text:
        raise ValueError('system PREFIX66 already applied')
    if text.count(OLD) != 1:
        raise ValueError('missing or ambiguous context anchor')
    replacements = {
        OLD: NEW,
        '(p54_prefix66_pc_q==eip)': '(p54_prefix66_pc_q==p54_prefix66_owner_pc)',
        'p54_prefix66_pc_q<=eip;': 'p54_prefix66_pc_q<=p54_prefix66_owner_pc;',
        '(p54_prefix66_pc_q!=eip)': '(p54_prefix66_pc_q!=p54_prefix66_owner_pc)',
    }
    for before, after in replacements.items():
        if text.count(before) != 1:
            raise ValueError('missing or ambiguous owner anchor: '+before)
        text = text.replace(before, after)
    return text


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if source == output:
        raise ValueError('private output must differ')
    original = source.read_bytes()
    changed = transform(original.decode()).encode()
    with output.open('xb') as stream:
        stream.write(changed)
    assert source.read_bytes() == original
    return dict(source=str(source), source_sha256=hashlib.sha256(original).hexdigest(),
                candidate=str(output), candidate_sha256=hashlib.sha256(changed).hexdigest(),
                production_changed=False, gameplay_ipc=None, standard_suite=False)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    print(json.dumps(prepare(args.source, args.out), indent=2))
