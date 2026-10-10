#!/usr/bin/env python3
"""Factor legacy read capture away from the next-read commit mux, exactly.

Only prepare fresh private sources. This is not a timing waiver, new acceptance
policy, or proof of hardware timing. The original capture mux remains intact.
"""
import argparse
import hashlib
import json
from pathlib import Path

PARENT_SHA = '2c6821f396d081bf30916a7ad48505512aa3477f649cec2ce25f3e621d0a133b'
HEAD = '''  assign do_rd_cap =
                     mc_lookup_next ? (mc_capture_next && !mc_prime_window_reuse) :
`ifdef VEN_L1D_HIT_STREAM
                     stream_path ? (c_req && c_req_ready) :
`endif
'''
TAIL = '''                     && !(BYPASS_RD_EN && !cacheable);   // H-18: CD/KEN# read bypass'''
PAIR_START = '  assign pair_legacy_capture ='
PAIR_END = '  assign pair_bank_conflict ='


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT_SHA:
        raise ValueError('not the source-qualified prefix-regonly parent L1')
    if text.count(HEAD) != 1 or text.count(TAIL) != 1:
        raise ValueError('ambiguous read-capture mux')
    start, end = text.index(PAIR_START), text.index(PAIR_END)
    pair = text[start:end]
    if pair.count('&& do_rd_cap') != 2 or '!mc_lookup_next && !early_armed && !stream_path' not in pair:
        raise ValueError('legacy capture no longer excludes next/stream selection')
    pair = pair.replace('&& do_rd_cap', '&& do_rd_cap_legacy')
    text = text[:start] + pair + text[end:]
    text = text.replace('  logic            do_rd_cap;',
                        '  logic            do_rd_cap, do_rd_cap_legacy;')
    text = text.replace(HEAD, '''  // The fresh-U pair predicate already excludes both next lookup and
  // stream mode. Feed it this exact legacy cofactor instead of routing a
  // late predecessor COMMIT through a mux whose other arms cannot apply.
  // This does not grant a speculative V or change the actual capture mux.
  assign do_rd_cap_legacy =
''')
    text = text.replace(TAIL, TAIL + '''

''' + HEAD + '''                     do_rd_cap_legacy;''')
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    source, out = args.source.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    if not out.is_relative_to(scratch) or out == source:
        raise ValueError('output must be a fresh external scratch file')
    before = source.read_text()
    after = transform(before)
    with out.open('x') as stream:
        stream.write(after)
    if source.read_text() != before:
        raise ValueError('parent changed during preparation')
    print(json.dumps(dict(source=str(source), output=str(out), parent_sha256=PARENT_SHA,
        candidate_sha256=hashlib.sha256(after.encode()).hexdigest(), qualification='UNQUALIFIED')))


if __name__ == '__main__':
    main()
