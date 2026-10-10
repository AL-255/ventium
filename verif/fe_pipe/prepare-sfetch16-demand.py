#!/usr/bin/env python3
"""Private 16-bit interior fetch proposal; reuse the checked reference decoder."""
import argparse
import hashlib
import json
from pathlib import Path

FLAG = 'VEN_SFETCH16_DEMAND'
DECLARATION = '''`ifdef VEN_SFETCH16_DEMAND
  logic sfetch_interior16;
`endif
'''
SELECT = '''`ifdef VEN_SFETCH16_DEMAND
    // Only S_FETCH changes policy. S_PIPE and every architectural execution,
    // permission and event owner are unchanged, including legal U/V pairing.
    // Save the ORIGINAL boundary result before selecting demand mode: only a
    // window already proven entirely within this page/CS/IP extent may round
    // requests to four bytes. True boundaries retain exact demanded strobes.
    sfetch_interior16 = (state == S_FETCH) && def16 && !sfetch_boundary;
    sfetch_boundary = sfetch_boundary || sfetch_interior16;
`endif
'''
SIZE = '''`ifdef VEN_SFETCH16_DEMAND
      // Starting at valid=0, interior beats advance by four and never exceed
      // the old 16-byte window. Decoder metadata, not opcode guesses or a
      // saved instruction, decides whether another beat is necessary.
      if (sfetch_interior16) sfetch_demand_size = 3'd4;
`endif
'''


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('missing/ambiguous 16-bit demand anchor: ' + old)
    return text.replace(old, new)


def transform(text):
    if FLAG in text:
        raise ValueError('16-bit demand fetch already present')
    anchor = '  logic sfetch_boundary, sfetch_demand_req;\n'
    text = once(text, anchor, anchor + DECLARATION)
    anchor = '    refdecode_valid = ((state == S_FETCH) && sfetch_boundary)\n'
    text = once(text, anchor, SELECT + anchor)
    anchor = "                        ? 3'd4 : 3'(d_fetch_need - sfetch_valid_q);\n"
    text = once(text, anchor, anchor + SIZE)
    # Refuse a source lacking the existing bounded request/ownership contract.
    for required in [
        '(sfetch_valid_q < d_fetch_need)',
        "sfetch_valid_q <= sfetch_valid_q + {2'd0,sfetch_demand_size};",
        "((state == S_WALK) && (walk_ret_state == S_FETCH))",
        "(def16 && (eip[15:0] > 16'hfff0))",
        "({1'b0,eip} + 33'd15 > {1'b0,seg_limit[SG_CS]}))",
    ]:
        if required not in text:
            raise ValueError('missing original fetch invariant: ' + required)
    return text


def prepare(source, output):
    source = source.resolve(strict=True)
    output = output.resolve()
    if source == output:
        raise ValueError('private output must differ from source')
    before = source.read_bytes()
    after = transform(before.decode()).encode()
    with output.open('xb') as f:
        f.write(after)
    assert source.read_bytes() == before
    return dict(source=str(source), source_sha256=hashlib.sha256(before).hexdigest(),
                candidate=str(output), candidate_sha256=hashlib.sha256(after).hexdigest(),
                production_changed=False, gameplay_ipc=None, standard_suite=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.out), indent=2))
