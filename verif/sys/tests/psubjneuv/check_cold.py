#!/usr/bin/env python3
"""Exact captured operands/layout, plus actual same-clock UV fast-path evidence."""
import argparse
import json
from pathlib import Path
from check_sim import number, rows


def check(trace, obs, exceptions):
    assert trace[0]['mode'] == 'cycle', 'UV cycle mode is mandatory'
    insn = trace[1:]
    assert len(insn) < 16000, 'instruction budget'
    assert all(number(r['n']) == i for i, r in enumerate(insn)), 'retire sequence'
    assert not any(number(r['pc']) in (0x59681, 0x59682) for r in insn), 'interior-byte execution'
    indices = [i for i, r in enumerate(insn) if number(r['pc']) == 0x59680]
    assert len(indices) == 16, 'exact subject count'
    for i in indices:
        u, v, successor = insn[i:i+3]
        assert u['pipe'] == 'U' and u['paired'] is False, 'primary U'
        assert number(v['pc']) == 0x59683 and v['pipe'] == 'V' and v['paired'] is True, 'actual paired JNE'
        assert u['cyc'] == v['cyc'], 'same-clock U/V retirement'
        assert number(successor['pc']) == 0x59685, 'original subject not-taken successor'
    assert obs[0]['type'] == 'begin' and obs[0]['passive'] is True, 'passive observer'
    assert obs[-1]['type'] == 'complete' and obs[-1]['terminal_seen'] == 1, 'closed observer'
    commits = [r for r in obs if r['type'] == 'branch-owner' and r['commit']]
    assert len(commits) == 16, 'exact fast commit count'
    samples = {}
    for r in obs:
        if r['type'] == 'sample':
            assert r['cycle'] not in samples, 'duplicate sample'
            samples[r['cycle']] = r
    for index, r in zip(indices, commits):
        assert (r['owner'], r['pair'], r['abort']) == (0x59680, 1, 0), 'fast memory pair commit'
        assert (r['u_len'], r['v_len']) == (3, 2), 'effective decode lengths'
        assert (r['offset'], r['physical'], r['read_data']) == (0xfaf50, 0x1fff50, 19), 'ordinary relocated load'
        assert (r['taken'], r['target'], r['u_flags']) == (0, 0x59693, 0x3246), 'SUB flags/branch'
        assert number(insn[index]['cyc']) == r['cycle'] + 1, 'registered DPI after sampled edge'
        assert samples[r['cycle']]['gpr'] == [0x7ec, 0xc, 0, 19, 0xfaef0, 0xfaf74, 0x51eb851f, 0x59948], 'captured precommit GPR layout'
    terminal = [r for r in samples.values() if r['terminal']]
    assert len(terminal) == 1 and terminal[0]['gpr'][0] == 0x42, 'self-check AL42'
    assert terminal[0]['segments'][0] == 8, 'CPL0 finish'
    assert exceptions == [{'type': 'complete', 'record_seen': False}], 'unexpected exception'
    return dict(result='PASS_COLD_LAYOUT_UV_FAST16', paired_commits=16,
                retained_commits=sum(r['active'] for r in commits), gameplay_ipc=None,
                processor_fix=False, acceptance=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('stem', type=Path)
    args = parser.parse_args()
    path = lambda suffix: Path(str(args.stem) + suffix)
    assert path('.native-exit.txt').read_text().strip() == '0', 'native exit'
    assert 'stop: quiescent for 200000 clocks' in path('.log').read_text(), 'terminal quiescence'
    print(json.dumps(check(rows(path('.vtrace')), rows(path('.owner.jsonl')),
                           rows(path('.exception.jsonl'))), indent=2))


if __name__ == '__main__':
    main()
