"""Run the eight original finite-CS fixtures that fail before RTL in QEMU.

Cold, unchanged BIOS images; parent/candidate full-record equality plus the
guest's fault-frame/no-partial-commit self-check. This is NOT a QEMU differential
pass and does not change the failed boundary gate or its expected results.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys'), str(REPO/'verif/l1')]
import tracefmt
import check_faultlog
import prepare_response_kind_mux as recipe

spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
CASES = [(2, r, o) for r in (0, 1) for o in (4080, 4093, 4094, 4095)]
MODEL_HASHES = {
    'control': 'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6',
    'candidate': 'da6744ec11615ca7900a6ed132bc9e64471dd567e363d33985864e50719be6dd',
}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def grade(trace, stdout, stderr, code, mode, hot, pair_v):
    """No field masks or trimmed records; validate the original guest outcome."""
    assert code == 133, ('native exit', code)
    assert trace.hdr['producer'] == 'rtl' and not trace.x87
    assert trace.mode == ('func' if mode == 'cycle-func' else 'cycle')
    assert 100 < len(trace.records) < 2000
    assert [r['n'] for r in trace.records] == list(range(len(trace.records)))
    assert not native.FATAL.search(stdout+stderr)
    check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()), {(13, 0): 1})
    faults = re.findall(r'^\[FAULT\] vec=13 err=00000000 pc=([0-9a-f]{8}) ', stdout, re.M)
    assert faults == [f'{hot:08x}'], faults
    assert all(int(r['pc'], 16) != hot for r in trace.records), 'faulting ADD retired'
    footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) after (\d+) retired in (\d+) clocks$', stderr, re.M)
    assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
    backing = re.findall(r'\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)', stdout)
    assert len(backing) == 1 and int(backing[0]) > 0, 'AXI backend not exercised'
    paired = []
    if mode == 'cycle-func':
        native.grade_native(trace, stdout, stderr, code, 133, 2000)
        assert int(trace.records[-1]['eax'], 16) & 255 == 0x42
    else:
        paired = [r for r in trace.records if r.get('paired') and r.get('pipe') == 'V']
        assert any(int(r['pc'], 16) == pair_v for r in paired), 'ordinary witness did not pair'
    return dict(records=len(trace.records), clocks=int(footer[0][1]),
                paired_v=len(paired), backing_acks=int(backing[0]), precise_gp=True)


def execute(command, cpu, env, folder, stem):
    """Observe the actual model after exec; hold its PID through group cleanup."""
    argv = ['taskset', '-c', str(cpu), 'prlimit', '--core=0', '--fsize=16777216', '--', *map(str, command)]
    save(folder/(stem+'.argv.json'), argv)
    result = dict(argv=argv, native_exit=None, actual_wait=False, timed_out=False,
                  observed_affinity={}, cleanup_signals=[], cleanup_errors=[], leaked=[])
    start = time.monotonic()
    with (folder/(stem+'.stdout')).open('x') as out, (folder/(stem+'.stderr')).open('x') as err:
        child = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                                 stdout=out, stderr=err, start_new_session=True)
        try:
            while os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                proc = Path('/proc')/str(child.pid)
                try:
                    if (proc/'exe').resolve(strict=True) == Path(command[0]):
                        affinity = sorted(os.sched_getaffinity(child.pid))
                        result['observed_affinity'][str(child.pid)] = affinity
                        assert affinity == [cpu]
                except (FileNotFoundError, ProcessLookupError):
                    pass
                if time.monotonic()-start > 15:
                    result['timed_out'] = True
                    break
                time.sleep(.001)
        except Exception as exc:
            result['cleanup_errors'].append(repr(exc))
        finally:
            # No poll()/wait() before signaling: the unreaped child still owns
            # this numeric PID, PGID and SID. Never signal after the final wait.
            members = native.group_members(child.pid)
            if not result['timed_out'] and members:
                result['leaked'] = members
            for sig in (signal.SIGTERM, signal.SIGKILL):
                if not members:
                    break
                assert os.getpgid(child.pid) == os.getsid(child.pid) == child.pid
                try:
                    os.killpg(child.pid, sig)
                except ProcessLookupError:
                    pass
                else:
                    result['cleanup_signals'].append(int(sig))
                until = time.monotonic()+1
                while (members := native.group_members(child.pid)) and time.monotonic() < until:
                    time.sleep(.01)
            result['group_closed'] = not members
            result['native_exit'] = child.wait(timeout=2)
            result['actual_wait'] = True
    result['seconds'] = time.monotonic()-start
    save(folder/(stem+'.native.json'), result)
    assert result['group_closed'] and result['actual_wait'] and result['observed_affinity']
    assert not result['timed_out'] and not result['cleanup_errors'] and not result['leaked']
    return result['native_exit']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = scratch/'ventium-data-size.v2HaTO2X'
    out = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(root) and not out.exists() and os.environ['INVOCATION_ID']
    assert os.sched_getaffinity(0) == {13, 14, 15}
    assert shutil.disk_usage(scratch).free > 4*1024**3 + 128*1024**2
    original = root/'response-kind-boundary-r1'
    failed = json.loads((original/'closed.json').read_text())
    assert not failed['passed'] and sorted(tuple(e['case']) for e in failed['errors']) == CASES
    begun = json.loads((original/'started.json').read_text())
    source = REPO/'verif/fe_pipe/prefix66-boundary.S'
    assert begun['pins'][str(source)] == sha(source)
    pins = {str(p): sha(p) for p in (Path(__file__), Path(recipe.__file__), Path(native.__file__),
        Path(tracefmt.__file__), Path(check_faultlog.__file__), original/'started.json',
        original/'closed.json', REPO/'verif/fe_pipe/prefix66-boundary.S')}
    models, sources, profiles = {}, {}, {}
    for name, leaf in (('control', 'prefix-payload-core-r1'), ('candidate', 'response-kind-core-r1')):
        core = root/leaf
        before = json.loads((core/'build-started.json').read_text())
        closed = json.loads((core/'build-closed.json').read_text())
        model = core/'obj/tb_ventium'; models[name] = model
        assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
        assert sha(model) == closed['binary_sha256'] == MODEL_HASHES[name]
        sources[name] = {str(Path(p).relative_to(core/'candidate')): h
                        for p, h in before['pins'].items() if Path(p).is_relative_to(core/'candidate')}
        assert len(sources[name]) == 195
        pins.update({str(core/'candidate'/p): h for p, h in sources[name].items()})
        stamp = model.parent/'Vventium_top__verFiles.dat'
        line = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        definitions = set(re.findall(r'\+define\+(\w+)', line))
        profiles[name] = definitions
        assert definitions == set(before['definitions']) and len(definitions) == 152
        assert ' --assert ' in line and {'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SEG_ENFORCE', 'VEN_FE_PIPE', 'VEN_P54_PREFIX66_SYSTEM', 'VEN_L1_AXI'} <= definitions
        assert not {'VEN_SYS_FASTPATH_ALL', 'SYNTHESIS', 'VTM_NO_DPI', 'VEN_UOPCACHE', 'VEN_CACHE_HALF'} & definitions
        for p in (model, stamp, core/'build-started.json', core/'build-closed.json'):
            pins[str(p)] = sha(p)
    assert profiles['control'] == profiles['candidate']
    assert sources['control'].keys() == sources['candidate'].keys()
    assert [p for p in sources['control'] if sources['control'][p] != sources['candidate'][p]] == [recipe.FILE]
    assert (root/'response-kind-core-r1/candidate'/recipe.FILE).read_text() == recipe.transform(
        (root/'prefix-payload-core-r1/candidate'/recipe.FILE).read_text())
    for _, reloc, offset in CASES:
        folder = original/f'k2-r{reloc}-o{offset}'
        assert json.loads((folder/'free-qemu.exit.json').read_text())['native_exit'] == 135
        assert not list(folder.glob('candidate*.vtrace'))
        for suffix in ('bin', 'elf'):
            p = folder/('test.'+suffix)
            assert sha(p) == sha(root/'prefix-payload-boundary-r1'/folder.name/p.name)
            pins[str(p)] = sha(p)
        pins[str(folder/'free-qemu.exit.json')] = sha(folder/'free-qemu.exit.json')
    assert all(sha(p) == h for p, h in pins.items())
    out.mkdir()
    save(out/'started.json', dict(pins=pins, cases=CASES, models={k: str(v) for k, v in models.items()},
        definitions=sorted(profiles['candidate']), invocation=os.environ['INVOCATION_ID'],
        differential=False, original_boundary_gate_passed=False, standard_suite=False, gameplay_ipc=None))
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1')

    def one(index, case):
        _, reloc, offset = case
        folder = out/f'k2-r{reloc}-o{offset}'; folder.mkdir()
        image = original/folder.name/'test.bin'
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output([
            'nm', '-n', image.with_suffix('.elf')], text=True).splitlines()
            if len(p := line.split()) == 3 and p[0] != 'U'}
        assert image.stat().st_size == 65536 and symbols['hot_probe'] == 0x2f000+offset
        rows, errors, traces = [], [], {}
        for name, model in models.items():
            for latency in (0, 7):
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{name}-lat{latency}-{mode}'; path = folder/(stem+'.vtrace')
                    row = dict(model=name, latency=latency, mode=mode, passed=False)
                    try:
                        code = execute([model, '--system', '--cosim', '--'+mode, '--l1-axi',
                            '--image', image, '--out', path, '--max-insn', '2000', '--max-cycles',
                            '1000000', '--quiesce', '4096', '+ven_faultlog'], 13+index % 3,
                            dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)), folder, stem)
                        trace = tracefmt.read_trace(str(path)); traces[name, latency, mode] = trace
                        row.update(grade(trace, (folder/(stem+'.stdout')).read_text(),
                            (folder/(stem+'.stderr')).read_text(), code, mode, symbols['hot_probe'], symbols['pair_v']))
                        row['passed'] = True
                    except Exception as exc:
                        errors.append(dict(stem=stem, error=repr(exc)))
                    rows.append(row)
        for latency in (0, 7):
            for mode in ('cycle-func', 'cycle'):
                try:
                    assert traces['control', latency, mode].records == traces['candidate', latency, mode].records
                except Exception as exc:
                    errors.append(dict(check=f'parent equality lat{latency} {mode}', error=repr(exc)))
            for name in models:
                selected = [r for r in rows if r['model'] == name and r['latency'] == latency]
                if not all(r['passed'] for r in selected) or selected[0]['clocks'] != selected[1]['clocks']:
                    errors.append(dict(check=f'{name} lat{latency} mode clocks', error='not verified equal'))
                try:
                    assert [r['pc'] for r in traces[name, latency, 'cycle-func'].records] == [
                        r['pc'] for r in traces[name, latency, 'cycle'].records]
                except Exception as exc:
                    errors.append(dict(check=f'{name} lat{latency} mode PCs', error=repr(exc)))
        result = dict(case=case, passed=not errors and all(r['passed'] for r in rows), rows=rows, errors=errors)
        save(folder/'closed.json', result)
        print(folder.name, 'PASS' if result['passed'] else 'FAIL', flush=True)
        return result

    start = time.monotonic(); result = dict(rows=[], errors=[], differential=False,
        original_boundary_gate_passed=False, standard_suite=False, physical_board=False, gameplay_ipc=None)
    with ThreadPoolExecutor(max_workers=3) as pool:
        pending = {pool.submit(one, i, c): c for i, c in enumerate(CASES)}
        for future in as_completed(pending):
            try:
                result['rows'].append(future.result())
            except Exception as exc:
                result['errors'].append(dict(case=pending[future], error=repr(exc)))
    result.update(seconds=time.monotonic()-start, pins_unchanged=all(sha(p) == h for p, h in pins.items()))
    cg = Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip().lstrip('/')
    result['memory_events'] = dict(line.split() for line in (cg/'memory.events').read_text().splitlines())
    result['passed'] = (len(result['rows']) == 8 and not result['errors'] and result['pins_unchanged']
        and all(r['passed'] for r in result['rows'])
        and all(result['memory_events'][k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill')))
    result['artifacts'] = {str(p.relative_to(out)): sha(p) for p in out.rglob('*') if p.is_file()}
    save(out/'closed.json', result)
    print(json.dumps({k: v for k, v in result.items() if k not in ('rows', 'artifacts')}, indent=2), flush=True)
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
