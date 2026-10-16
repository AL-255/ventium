"""Independently replay the readiness proof and regrade closed cache/core evidence.

No functional waiver, canonical success, synthesis gain or hardware acceptance
is inferred from these local equivalence checks.
"""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys

import build_next_ready_core as builder
import prepare_next_ready_cofactor as recipe
import run_next_ready_cofactor_leaf as leaf
import run_next_ready_cofactor_cache as cache
from run_next_ready_func import MODEL

ROOT = leaf.ROOT
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import compare
import tracefmt

sha = leaf.sha


def load(path):
    return json.loads(path.read_text())


def owner(unit, invocation):
    keys = ('ActiveState', 'SubState', 'MainPID', 'ExecMainStatus',
            'InvocationID', 'Result', 'ControlGroup',
            'ExecMainStartTimestampMonotonic', 'ExecMainExitTimestampMonotonic')
    result = dict(line.split('=', 1) for line in subprocess.check_output(
        ['systemctl', '--user', 'show', unit, *['-p'+k for k in keys]], text=True).splitlines())
    assert (result['ActiveState'], result['SubState'], result['MainPID'],
            result['ExecMainStatus'], result['Result']) == ('active', 'exited', '0', '0', 'success')
    guarded = {
        'ventium-next-ready-cache-oct16-r3.service':
            ('2345a01799284c5795fa48538c15560d', 'ba16d72904a844328659dd6385095e10',
             'run_next_ready_cofactor_cache.py', 'next-ready-cache-r3'),
        'ventium-next-ready-core-oct16-r1.service':
            ('a6f3af2b47ae4033998cb29af5a37bb9', '0e31935bc0d6422ebdfb1de748eb636d',
             'build_next_ready_core.py', 'next-ready-core-r1'),
    }
    if unit in guarded:
        outer, inner, script, output = guarded[unit]
        assert result['InvocationID'] == outer and invocation == inner
        raw = subprocess.check_output(['journalctl','--user','USER_INVOCATION_ID='+inner,
                                       '--no-pager','-o','json'])
        rows = [json.loads(line) for line in raw.splitlines()]
        assert rows and all(r['USER_UNIT']=='ventium-ipc-parallel32.scope' for r in rows)
        assert any(r.get('JOB_RESULT')=='done' and r.get('JOB_TYPE')=='start'
                   and script in r['MESSAGE'] and output in r['MESSAGE'] for r in rows)
        assert any('CPU_USAGE_NSEC' in r and 'MEMORY_PEAK' in r for r in rows)
        assert all(int(result['ExecMainStartTimestampMonotonic']) <= int(r['__MONOTONIC_TIMESTAMP'])
                   <= int(result['ExecMainExitTimestampMonotonic']) for r in rows)
        result.update(inner_invocation=inner, scope_journal_sha256=hashlib.sha256(raw).hexdigest())
    else:
        assert result['InvocationID'] == invocation
    if result['ControlGroup']:
        assert not (Path('/sys/fs/cgroup')/result['ControlGroup'].lstrip('/')/'cgroup.procs').read_text().strip()
    return result


def main():
    assert __debug__
    core, parent = ROOT/'next-ready-core-r1', ROOT/'sfetch-boundary-core-r1'
    proof, miter, faults = [ROOT/n for n in
        ('next-ready-leaf-r2', 'next-ready-cache-r3', 'next-ready-boundaries-r1')]
    target = core/'local-equivalence-audit.json'
    assert not target.exists()
    pins, artifacts, owners = {}, {}, {}

    def retain(path):
        artifacts[str(path)] = sha(path)

    def receipt(root, unit, prefix=''):
        start, done = [load(root/(prefix+n+'.json')) for n in ('started', 'closed')]
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert done['gameplay_ipc'] is None and not done['standard_suite']
        assert not done['hardware_acceptance']
        if 'memory_events' in done:
            assert not any(int(done['memory_events'][k]) for k in ('oom', 'oom_kill', 'oom_group_kill'))
        for table in (start.get('pins', {}), done.get('pins', {})):
            assert all(sha(p) == h for p, h in table.items())
            pins.update(table)
        owners[unit] = owner(unit, start['invocation'])
        for n in ('started', 'closed'):
            retain(root/(prefix+n+'.json'))
        return start, done

    ps, pd = receipt(proof, 'ventium-next-ready-leaf-oct16-r2.service')
    original = (parent/'candidate'/recipe.FILE).read_text()
    changed = recipe.transform(original)
    assert changed == (proof/'ven_l1d.sv').read_text() == (core/'candidate'/recipe.FILE).read_text()
    assert sha(proof/'ven_l1d.sv') == pd['derivative_sha256']
    assert ps['jobs'] == [[p, 'positive'] for p in leaf.PROFILES] + [['full', m] for m in leaf.MUTANTS]
    assert len(pd['rows']) == 8 and pd['proof_passed']
    for job, row in zip(ps['jobs'], pd['rows']):
        profile, mode = job
        assert [row['profile'], row['mode']] == job
        assert row['passed'] and row['waited'] and row['compile_exit'] == 0
        assert row['affinity'] == [12, 13]
        assert row['native_exit'] == int(mode != 'positive')
        folder = proof/(profile+'-'+mode)
        assert (folder/'tb.sv').read_text() == leaf.fixture(original, mode)
        normalized = [str(Path(s).resolve()) if s.startswith('/') else s for s in row['command']]
        assert normalized == ['/usr/bin/iverilog', '-g2012', '-Wall', '-s', 'tb', '-o',
            str(folder/'test.vvp'), *['-D'+d for d in leaf.PROFILES[profile]], str(folder/'tb.sv')]
        log = (folder/'native.log').read_text()
        if mode == 'positive':
            assert 'NEXT-READY-LEAF-OK samples=196608 ' in log and 'FATAL' not in log
        else:
            assert 'FATAL:' in log and 'NEXT-READY-MISMATCH' in log
        assert all(sha(p) == h for p, h in row['artifacts'].items())
        artifacts.update(row['artifacts'])
    problem, expected = leaf.symbolic()
    assert (proof/'proof.smt2').read_text() == problem
    replay = subprocess.run(['/usr/bin/z3', '-smt2', str(proof/'proof.smt2')],
                            capture_output=True, text=True, timeout=30, check=True)
    assert replay.stdout.splitlines() == expected and not replay.stderr
    assert replay.stdout == (proof/'proof.stdout').read_text() and not (proof/'proof.stderr').read_text()
    for n in ('proof.smt2', 'proof.stdout', 'proof.stderr', 'ven_l1d.sv'):
        retain(proof/n)

    ms, md = receipt(miter, 'ventium-next-ready-cache-oct16-r3.service')
    assert [(r['label'], r['build_exit'], r['native_exit']) for r in md['rows']] == [
        ('positive-lut1', 0, 0), ('positive-lut0', 0, 0), ('mutant-lut1', 0, 1)]
    samples = 0
    for row in md['rows']:
        label = row['label']; folder = miter/label
        flat, mutant = label.endswith('lut1'), label.startswith('mutant')
        defs = [d for d in ms['definitions'] if flat or d != 'VEN_L1D_TAG_LUTRAM']
        assert row['definitions'] == defs
        assert (folder/'ven_l1d.sv').read_text() == (
            changed.replace('(mc_old_slot && cacheable)', 'mc_old_slot', 1) if mutant else changed)
        pp = (miter/(label+'-preprocess.log')).read_text()
        assert (folder/'tb_l1d_mem_chain.sv').read_text() == cache.fixture(cache.previous.original.ports(pp), flat)
        cmd = load(miter/(label+'-build.command.json'))
        assert '--assert' in cmd and cmd[cmd.index('-j')+1] == '32'
        assert [s.removeprefix('+define+') for s in cmd if s.startswith('+define+')] == defs
        for warning in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT'):
            assert '-Werror-'+warning in cmd
        binary = folder/'obj/Vtb_l1d_mem_chain'
        assert sha(binary) == row['binary_sha256']
        cmd = load(miter/(label+'-native.command.json'))
        assert cmd[:3] == ['taskset','-c','12'] and len(cmd) == 4 and Path(cmd[3]).resolve() == binary
        log = (miter/(label+'-native.log')).read_text()
        if mutant:
            assert 'CUT_EQUIV c_next_ready' in log or 'NEXT-READY-OLD-NC accepted' in log
        else:
            assert not re.search(r'%Error|%Fatal|MISMATCH|FAIL', log)
            for marker in ('L1D-MEM-CHAIN-OK accepted=150', 'checks=538 fresh=448 same_bank=64 held=1536',
                'CODE-WORD-REUSE-LEAF-OK checks=51', 'DATA-UNDER-IFILL-OK checks=659 held_completions=640',
                'PRIME-UNDER-IFILL-OK checks=661 completions=0', 'NEXT-READY-DFILL-OK checks=320'):
                assert marker in log
            observed = re.findall(r'NEXT-READY-CACHE-OK samples=(\d+)', log)
            assert observed == ['295042']; samples += int(observed[0])
        retain(binary)
    for p in miter.iterdir():
        if p.is_file(): retain(p)

    cs, cd = receipt(core, 'ventium-next-ready-core-oct16-r1.service', 'build-')
    before = load(parent/'build-started.json')
    assert cs['parent_model'] == builder.MODEL and cd['binary_sha256'] == MODEL
    assert cs['definitions'] == before['definitions'] == ms['definitions'] and len(cs['definitions']) == 153
    assert cs['changes'] == [recipe.FILE]
    names = [str(p.relative_to(parent/'candidate')) for p in builder.native.common.candidate_files(parent/'candidate')]
    assert len(names) == 195
    assert names == [str(p.relative_to(core/'candidate')) for p in builder.native.common.candidate_files(core/'candidate')]
    assert [n for n in names if sha(parent/'candidate'/n) != sha(core/'candidate'/n)] == [recipe.FILE]
    assert sha(core/'obj/tb_ventium') == MODEL
    host = Path(cs['host']); obj = core/'obj'/(host.stem+'.o'); dep = core/'obj'/(host.stem+'.d')
    assert host.stem.startswith('tb_next_ready_') and obj.is_file()
    assert 'Vventium_top___024root.h' in dep.read_text()
    for token in dep.read_text().replace('\\\n', ' ').split()[1:]:
        if Path(token).name.startswith('Vventium_top'):
            p = Path(token)
            assert (p if p.is_absolute() else core/'obj'/p).resolve().is_relative_to(core/'obj')
    for p in (host, obj, dep, core/'obj/tb_ventium'): retain(p)

    fs, fd = receipt(faults, 'ventium-next-ready-boundaries-oct16-r1.service')
    assert fs['cycle_mode'] == 1 and fs['workers'] == 22
    assert fs['profiles']['parent'] == fs['profiles']['candidate'] == sorted(cs['definitions'])
    records = paired = witnesses = 0
    assert len(fd['rows']) == 88
    for case in range(1, 23):
        folder = faults/f'case{case}'; golden = folder/'golden.vtrace'
        for latency in (0, 7):
            for mode in ('cycle-func', 'cycle'):
                label = f'candidate-lat{latency}-{mode}'
                a = tracefmt.read_trace(str(folder/f'parent-lat{latency}-{mode}.vtrace'))
                b = tracefmt.read_trace(str(folder/(label+'.vtrace')))
                assert a.records == b.records and len(b.records) > 0
                if mode == 'cycle-func':
                    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                        assert compare.main(['--mode','func','--all',str(golden),str(folder/(label+'.vtrace'))]) == 0
                else:
                    records += len(b.records)
                    paired += sum(r.get('pipe') == 'V' and r.get('paired') for r in b.records)
                witnesses += (folder/(label+'.stdout')).read_text().count('[FETCH-PROBE-PAYLOAD]')
        for p in folder.glob('*.exit.json'):
            closed = load(p)
            assert closed['actual_wait'] and closed['group_closed']
            assert closed['actual_return_code'] == (0 if p.name == 'golden.exit.json' else 133)
    assert (records, paired, witnesses) == (21832, 4968, 44)
    for p in faults.rglob('*'):
        if p.is_file(): retain(p)
    for p in (Path(__file__), Path(compare.__file__), Path(tracefmt.__file__)):
        pins[str(p)] = sha(p)
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(passed=True, owners=owners, pins=pins, artifacts=artifacts,
        model=MODEL, parent_model=builder.MODEL, input_pins=len(pins),
        source_changes=[recipe.FILE], symbolic_results=expected,
        leaf_samples=983040, cache_samples=samples, data_under_fill_cases=640,
        boundary_records=records, boundary_v_retirements=paired, boundary_probe_witnesses=witnesses,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
        gameplay_ipc=None, fmax_mhz=None)
    with target.open('x') as stream: json.dump(result, stream, indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','artifacts','owners')}, indent=2))


if __name__ == '__main__': main()
