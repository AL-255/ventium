#!/usr/bin/env python3
"""Private opt-in reuse of words already registered in the instruction staging line.

This never serves from the asynchronous data SRAM. Physical ownership, arrived
word validity, invalidation, memory type and the critical-response owner remain
authoritative. Production selection and whole-core qualification are separate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


FLAG = 'VEN_L1D_CODE_WORD_REUSE'


def transform(text):
    if FLAG in text:
        raise ValueError('code word reuse is already present')
    edits = {
        '  assign fill_forward_hit = fill_forward_data_hit || fill_forward_code_hit;': '''  assign fill_forward_hit = fill_forward_data_hit || fill_forward_code_hit;
`ifdef VEN_L1D_CODE_WORD_REUSE
`ifndef VEN_L1D_CODE_BUFFER
  initial $fatal(1, "code word reuse requires the registered instruction staging line");
`endif
`ifdef VEN_L1D_COMB_ACK
  initial $fatal(1, "code word reuse is not the asynchronous SRAM response profile");
`endif
  // code_line_q is already a bank of registers, not an asynchronous SRAM
  // lookup. Avoid copying an owned, arrived instruction word through another
  // response register. No data window, tag, LRU or fill-owner state changes.
  // The first critical response keeps its exclusive early_armed owner.
  logic code_word_reuse;
  assign code_word_reuse = rst_n && c_req && code_access &&
      !flush_all && !snoop_inv_valid && !early_armed &&
      !mc_lookup_next && !stream_path &&
      ((code_hit && ((st == L1_IDLE) || fill_independent_hit)) ||
       fill_forward_code_hit);
`endif''',
        '                     !rd_match && !window_reuse && !shadow_reuse\n': '''                     !rd_match && !window_reuse && !shadow_reuse
`ifdef VEN_L1D_CODE_WORD_REUSE
                     && !code_word_reuse
`endif
''',
        '                           : early_match ? early_rdata_q\n': '''                           : early_match ? early_rdata_q
`ifdef VEN_L1D_CODE_WORD_REUSE
                           : code_word_reuse ? code_line_q[{c_addr[4:2],5'b00000} +: 32]
`endif
''',
        '      else                 c_ack = window_reuse || shadow_reuse ||\n': '''      else                 c_ack = window_reuse || shadow_reuse ||
`ifdef VEN_L1D_CODE_WORD_REUSE
                                 code_word_reuse ||
`endif
''',
    }
    for old, new in edits.items():
        if text.count(old) != 1:
            raise ValueError('missing/ambiguous code word reuse anchor: ' + old)
        text = text.replace(old, new)
    # Frozen FPGA candidates also carry the earlier payload-selector miter.
    # Preserve its assertion and all old cases; give the new registered source
    # an independent byte-offset expression in its reference mux as well.
    if 'payload_before_cut' in text:
        old = '\n                       : early_match ? early_rdata_q\n'
        if text.count(old) != 1:
            raise ValueError('missing/ambiguous payload miter anchor')
        text = text.replace(old, '''
`ifdef VEN_L1D_CODE_WORD_REUSE
                       : code_word_reuse ? 32'(code_line_q >> {c_addr[4:0],3'b000})
`endif'''
                            + old)
    return text


def pins(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output cannot be nested in source')
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
    (output / 'code-word-reuse-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    prepare(args.source, args.out)
