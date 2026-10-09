#!/usr/bin/env python3
"""Fix registered-V ownership at an already-acknowledged primed U boundary.

Private source copy, one leaf change. Immediate same-line U/V still pairs;
a different-line V cannot register behind a U that retires on this edge.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def prepare(source,output):
    source,output=source.resolve(strict=True),output.resolve()
    assert not output.is_relative_to(source)
    def pins(root):
        return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob('*') if p.is_file()}
    before=pins(source)
    shutil.copytree(source,output)
    path=output/'rtl/mem/ven_l1d.sv'
    text=path.read_text()
    old='  assign pair_legacy_overlap = c_req && !c_we && rd_match && c_ack && cacheable;'
    assert text.count(old)==1
    text=text.replace(old,'''  assign pair_legacy_overlap = c_req && !c_we && rd_match && c_ack && cacheable
`ifdef VEN_P54_DUAL_LOAD_PAIR
      // Lane-1-only core requests describe a fresh V behind this live U.
      // A primed U may already ACK on its admission edge, so no registered
      // U owner will be created to hold a later V response. Do not enqueue
      // that orphan. The independent same-line pair_now path still returns
      // both values on this edge; otherwise V retries as the next ordinary U.
      // Standalone two-lane requests and fresh-U capture remain unchanged.
      && (pair_req_valid != 2'b10)
`endif
      ;''')
    path.write_text(text)
    after=pins(output)
    assert set(after)==set(before)
    assert [k for k in before if before[k]!=after[k]]==['rtl/mem/ven_l1d.sv']
    assert pins(source)==before
    (output/'prime-pair-owner-inputs.json').write_text(json.dumps(dict(
        parent=str(source),parent_pins=before,candidate_pins=after,
        gameplay_ipc=None,standard_suite=False),indent=2)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args();prepare(args.source,args.out)
