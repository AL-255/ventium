#!/usr/bin/env python3
"""Private candidate: prime a resident data set during an unrelated data fill."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('missing/ambiguous under-fill source anchor')
    return text.replace(before, after)


def transform(text):
    text = once(text, '''  assign mc_lookup_prime = c_next_req && !c_req && !rd_armed &&
      (st == L1_IDLE) && !early_armed && !stream_path;''', '''  // Query identity is independent of HIT/ACK. The fill retains its backing
  // owner; only a resident line in another physical set can lend its existing
  // array read port. Same-set replacement, code fills and bypass stay blocked.
`ifdef VEN_L1D_PRIME_UNDER_FILL
`ifndef VEN_L1D_HIT_UNDER_FILL
  initial $fatal(1, "resident priming under fill requires ordinary hit-under-fill");
`endif
`endif
  assign mc_lookup_prime = c_next_req && !c_req && !rd_armed &&
      ((st == L1_IDLE)
`ifdef VEN_L1D_PRIME_UNDER_FILL
       || ((st == L1_FILL) && !bypass_q && !fill_poison &&
`ifdef VEN_L1D_CODE_BUFFER
           !code_fill_q &&
`endif
           (c_next_addr[OFFW +: IDXW] != fset))
`endif
      ) && !early_armed && !stream_path;''')
    text = once(text, '''      unique case (st)
        L1_IDLE: begin''', '''`ifdef VEN_L1D_PRIME_UNDER_FILL
      // The query set differs from the fill set, including on its final beat;
      // neither LRU update overwrites the other's entry.
      if ((st == L1_FILL) && mc_capture_next)
        dc_lru[set_c] <= hit_way;
`endif
      unique case (st)
        L1_IDLE: begin''')
    return text


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output may not be nested inside source')
    pins = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.rglob('*') if p.is_file()}
    leaf = 'rtl/mem/ven_l1d.sv'
    changed = transform((source/leaf).read_text())
    shutil.copytree(source, output)
    (output/leaf).write_text(changed)
    actual = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in output.rglob('*') if p.is_file()}
    assert set(pins) == set(actual)
    assert [p for p in pins if pins[p] != actual[p]] == [leaf]
    assert all(hashlib.sha256((source/p).read_bytes()).hexdigest() == h for p,h in pins.items())
    return dict(parent_pins=pins, candidate_pins=actual, gameplay_ipc=None, standard_suite=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source, args.out)
    (args.out/'prime-under-fill-inputs.json').write_text(json.dumps(result, indent=2)+'\n')
