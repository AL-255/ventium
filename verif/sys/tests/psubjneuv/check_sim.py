#!/usr/bin/env python3
"""Fail-closed architectural AND actual UV/fast memory-branch coverage checks."""
import argparse
import json
from pathlib import Path

def number(x):
    return int(x, 0) if isinstance(x, str) else int(x)

def rows(p):
    with p.open() as f:
        return [json.loads(line) for line in f if line.strip()]

def main():
    p = argparse.ArgumentParser()
    p.add_argument('stem', type=Path)
    a = p.parse_args()
    path = lambda suffix: Path(str(a.stem) + suffix)
    assert path('.native-exit.txt').read_text().strip() == '0', 'native exit'
    assert 'stop: quiescent for 200000 clocks' in path('.log').read_text(), 'terminal quiescence'
    trace = rows(path('.vtrace'))
    assert trace[0]['mode'] == 'cycle', 'UV cycle mode is mandatory'
    insn = trace[1:]
    assert all(number(r['n']) == i for i, r in enumerate(insn)), 'retire sequence'
    assert len(insn) < 64000, 'instruction budget'
    assert not any(number(r['pc']) == 0x59682 for r in insn), 'interior-byte execution'
    u = [i for i, r in enumerate(insn) if number(r['pc']) == 0x59680]
    assert len(u) == 64, f'exact subject count: {len(u)}'
    for case, i in enumerate(u):
        r, v, successor = insn[i:i+3]
        # Frozen DPI marks the second member V/true; U is U/false even
        # in a pair. Both records and equal clocks are required below.
        assert r['pipe'] == 'U' and r['paired'] is False, 'subject primary U'
        assert number(v['pc']) == 0x59683 and v['pipe'] == 'V' and v['paired'] is True, 'actual paired JNE'
        assert r['cyc'] == v['cyc'], 'same-clock U/V retirement'
        assert number(successor['pc']) == (0x59685 if case % 4 < 2 else 0x59693), 'branch successor'
    assert sum(number(r['pc']) == 0x59697 for r in insn) == 32, 'taken path count'
    assert sum(number(r['pc']) == 0x596c8 for r in insn) == 32, 'equal path count'
    obs = rows(path('.owner.jsonl'))
    assert obs[0]['type'] == 'begin' and obs[0]['passive'] is True, 'passive observer'
    assert obs[-1]['type'] == 'complete' and obs[-1]['terminal_seen'] == 1, 'closed observer'
    terminal = [r for r in obs if r['type'] == 'sample' and r['terminal']]
    assert len(terminal) == 1 and terminal[0]['gpr'][0] == 0x42, 'self-check AL42'
    assert terminal[0]['segments'][0] == 8, 'CPL0 finish'
    commits = [r for r in obs if r['type'] == 'branch-owner' and r['commit']]
    assert len(commits) == 64, f'exact subject commit count: {len(commits)}'
    for case, r in enumerate(commits):
        assert r['owner'] == 0x59680 and r['pair'] == 1 and r['abort'] == 0, 'fast memory pair commit'
        assert r['u_len'] == 3 and r['v_len'] == 2, 'retained decode lengths'
        assert r['offset'] == 0xe0edc and r['physical'] == 0x1e5edc, 'ordinary relocated stack load'
        assert r['read_data'] == (0x80000000 if case % 4 == 3 else 1), 'loaded operand'
        assert r['taken'] == int(case % 4 >= 2), 'forwarded SUB/JNE truth'
        assert r['target'] == 0x59693, 'V branch target'
        # Defined arithmetic flags: OF,SF,ZF,AF,PF,CF. No wildcard on those bits.
        expected = (0x44, 0x44, 0x814, 0x885)[case % 4]
        assert r['u_flags'] & 0x8d5 == expected, 'SUB arithmetic flags'
        assert number(insn[u[case]]['cyc']) == r['cycle'] + 1, 'registered DPI one edge after commit'
    exceptions = rows(path('.exception.jsonl'))
    assert exceptions == [{'type':'complete', 'record_seen':False}], 'unexpected exception'
    print(json.dumps({'result':'PASS_UV_FAST_SUBJNE', 'subject_count':64, 'taken':32,
        'not_taken':32, 'retained_commits':sum(r['active'] for r in commits),
        'predicted_taken_actual_not':sum(r['predicted'] and not r['taken'] for r in commits),
        'retired_instructions':len(insn), 'gameplay_measurement':False}, indent=2))

if __name__ == '__main__':
    main()
