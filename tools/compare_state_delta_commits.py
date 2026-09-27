#!/usr/bin/env python3
"""Compare reconstructed PC streams and common integer commit boundaries.

Consumes the phase-validated 76-byte observations from state_delta_analyze.cpp.
Paired U records carry the pair's final snapshot: compare snapshots ONLY where
both streams end a commit group. No EFLAGS masking, resync, or state substitution.
This diagnostic does not compare deferred x87 state or all physical memory.
"""
import argparse
import json
import struct
from pathlib import Path

RECORD = struct.Struct('<QQIII48s')


def events(path):
    last = None
    with path.open('rb') as f:
        while data := f.read(RECORD.size):
            if len(data) != RECORD.size:
                raise ValueError('truncated commit observation')
            end, cycle, pc, pc2, count, snap = RECORD.unpack(data)
            if count not in (1,2) or (last is not None and end != last+count):
                raise ValueError('nonconsecutive retirement ordinals')
            last = end
            for slot in range(count):
                yield end-count+slot+1, cycle, pc if slot==0 else pc2, snap if slot==count-1 else None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('baseline', type=Path)
    p.add_argument('candidate', type=Path)
    p.add_argument('--start-cycle', type=int, required=True)
    a = p.parse_args()
    candidate = iter(events(a.candidate))
    result = dict(matched_pcs=0, matched_common_integer_boundaries=0, status='PASS')
    for old in events(a.baseline):
        new = next(candidate, None)
        if new is None or old[0] != new[0] or old[2] != new[2]:
            result.update(status='DIVERGED_PC', old=old[:3], new=new[:3] if new else None)
            break
        result['matched_pcs'] += 1
        if old[3] is not None and new[3] is not None:
            if old[3] != new[3]:
                result.update(status='DIVERGED_INTEGER_STATE', ordinal=old[0], pc=hex(old[2]),
                              baseline_words=struct.unpack('<12I',old[3]), candidate_words=struct.unpack('<12I',new[3]))
                break
            result['matched_common_integer_boundaries'] += 1
        result.update(last_ordinal=old[0], baseline_cycle=old[1], candidate_cycle=new[1])
    if result['matched_pcs'] == 0:
        raise ValueError('no comparable observations')
    if result['status']=='PASS':
        old_cycles=result['baseline_cycle']-a.start_cycle
        new_cycles=result['candidate_cycle']-a.start_cycle
        result.update(baseline_work_cycles=old_cycles, candidate_work_cycles=new_cycles,
                      same_pc_prefix_speedup=old_cycles/new_cycles)
    print(json.dumps(result,indent=2))
    return 0 if result['status']=='PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
