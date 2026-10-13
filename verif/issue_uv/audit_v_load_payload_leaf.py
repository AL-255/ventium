"""Read-only qualification of the observed selector leaf, not a core pass."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import prepare_v_load_payload as recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', required=True, type=Path)
    root = ap.parse_args().out.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    started = json.loads((root/'started.json').read_text())
    closed = json.loads((root/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['error'] is None
    assert len(closed['rows']) == 12
    assert all(sha(path) == digest for path, digest in started['pins'].items())
    unit = started['unit']
    owner = dict(row.split('=', 1) for row in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-pSubState', '-pMainPID',
        '-pExecMainStatus', '-pInvocationID', '-pMemoryPeak'], text=True).splitlines())
    assert owner['SubState'] == 'exited' and owner['MainPID'] == owner['ExecMainStatus'] == '0'
    assert owner['InvocationID'] == started['invocation']
    assert int(owner['MemoryPeak']) <= started['memory_limit_bytes'] == 512*1024**2
    assert started['swap_limit_bytes'] == 0
    assert all(closed['memory_events'][n] == '0' for n in ('oom', 'oom_kill', 'oom_group_kill'))
    counts = [8192, 8704, 2048, 2560, 8192, 8704, 8192, 8704]
    macros = ('VEN_P54_DUAL_BYTE_LOAD_PAIR', 'VEN_RAW_V_READ_PRIME', 'VEN_P54_DUAL_LOAD_PRIME')
    for i, row in enumerate(closed['rows'][:8]):
        assert row['name'] == f'profile-{i}' and not row['expected_failure'] and row['native_exit'] == 0
        assert row['defines'] == [m for bit, m in enumerate(macros) if i & (1 << bit)]
        assert int(re.search(r'checks=(\d+)', row['output'])[1]) == counts[i]
        assert row['output'] == (root/(row['name']+'.log')).read_text().strip()
    assert [r['name'] for r in closed['rows'][8:]] == [
        'mutant-held-only', 'mutant-immediate-only', 'mutant-inverted', 'mutant-broad-profile']
    for row in closed['rows'][8:]:
        assert row['expected_failure'] and row['native_exit'] == 1
        assert 'V-LOAD-PAYLOAD-MISMATCH' in row['output']
    for row in closed['rows']:
        assert all(sha(p) == h for p, h in row['artifacts'].items())
    assert (root/'abstract-contract.log').read_text().splitlines() == ['unsat', 'unsat', 'sat', 'sat', 'sat', 'sat']
    observations = sorted(root.glob('*.native.json'))
    assert len(observations) == 26
    actual = []
    for path in observations:
        record = json.loads(path.read_text())
        command = json.loads(path.with_name(path.name.replace('.native.json', '.command.json')).read_text())
        assert command[:4] == ['/usr/bin/timeout', '--signal=TERM', '--kill-after=2s', '20s']
        assert record['error'] is None and record['launcher_reaped']
        expected_exit = 1 if path.name.startswith('mutant-') and '-build.' not in path.name else 0
        assert record['native_exit'] == expected_exit
        # The Python recipe observation can include its Python controller.
        # Only the exact native argv counts; that controller alone cannot pass.
        matches = [r for r in record['native'] if r['argv'] == command[4:]]
        assert matches, ('missing actual native command/affinity', path)
        for row in matches:
            assert row['affinity'] == [18] and row['cgroup'].strip().endswith('/'+unit)
            proc = Path('/proc')/str(row['pid'])
            if proc.exists():
                assert (proc/'stat').read_text().rsplit(')', 1)[1].split()[19] != row['starttime']
            actual.append(row)
    parent = Path(started['parent'])
    proposed = recipe.transform({p: (parent/p).read_text() for p in recipe.PARENTS})
    assert all((root/'proposal'/p).read_text() == text for p, text in proposed.items())
    assert closed['proposal_sha256'] == {p: hashlib.sha256(t.encode()).hexdigest() for p, t in proposed.items()}
    artifacts = {str(p): sha(p) for p in root.iterdir() if p.is_file()}
    artifacts[str(Path(__file__).resolve())] = sha(__file__)
    result = dict(passed=True, owner=owner, pins_checked=len(started['pins']),
        profiles=8, comparisons=sum(counts), negative_variants=4, actual_native_commands=len(actual),
        artifacts=artifacts, seconds=closed['seconds'], source_transformation_exact=True,
        sequential_core=False, standard_suite=False, physical_board=False, gameplay_ipc=None, timing_mhz=None)
    with (root/'audit.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k != 'artifacts'}))


if __name__ == '__main__':
    main()
