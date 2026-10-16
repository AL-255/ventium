"""Build the source-proven RAW storage specialization on the faster parent."""
import inspect
from pathlib import Path
import subprocess
import sys

import prepare_raw_prime_storage as recipe
import run_raw_prime_storage as leaf_test

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'fetchguard'))
import build_decode_bus_core as previous

MODEL = 'e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a'
native = previous.native


def check_leaf(leaf):
    start, done = [native.load(leaf/name) for name in ('started.json', 'closed.json')]
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert not done['whole_core'] and not done['standard_suite'] and not done['physical_fpga']
    assert not any(done['memory_events'][k] for k in ('oom', 'oom_kill', 'oom_group_kill'))
    assert [(r['raw'], r['mode']) for r in done['rows']] == list(leaf_test.JOBS)
    owner = dict(s.split('=', 1) for s in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-raw-prime-storage-leaf-oct16-r1.service',
        '-p', 'InvocationID', '-p', 'MainPID', '-p', 'SubState', '-p', 'Result', '-p', 'ExecMainStatus'],
        text=True, timeout=10).splitlines())
    assert owner == dict(InvocationID=start['invocation'], MainPID='0', SubState='exited',
                         Result='success', ExecMainStatus='0')
    headers = [Path(p).parent for p in start['pins'] if p.endswith('/core_mem_chain.svh')]
    assert len(headers) == 1
    source = headers[0]
    assert (leaf/'core_mem_chain.svh').read_text() == recipe.transform((source/'core_mem_chain.svh').read_text())
    assert (leaf/'invariant.smt2').read_text() == leaf_test.proof()
    replay = subprocess.run(['/usr/bin/z3', str(leaf/'invariant.smt2')], capture_output=True, text=True, timeout=15)
    assert replay.returncode == 0 and replay.stdout.split() == ['unsat', 'sat', 'sat', 'sat']
    assert replay.stdout == (leaf/'proof.log').read_text()
    for row in done['rows']:
        assert row['passed'] and row['compile_exit'] == 0 and row['actual_wait'] and row['proc_gone']
        assert row['affinity'] == [18, 19, 20, 21] and not Path('/proc', str(row['pid'])).exists()
        assert row['native_exit'] == (0 if row['mode'] == 'positive' else 1)
        work = leaf/(('raw-' if row['raw'] else 'legacy-')+row['mode'])
        assert (work/'tb.sv').read_text() == leaf_test.fixture(source, row['raw'], row['mode'])
        log = (work/'native.log').read_text()
        if row['mode'] == 'positive':
            assert 'RAW-STORAGE-OK checks=16385' in log and 'FATAL' not in log
            if row['raw']: assert 'retained=0 ' in log
            else: assert 'retained=0 ' not in log
        else:
            assert 'RAW-STORAGE-LEAF mismatch' in log or 'RAW-PRIME-STORAGE:' in log
    pins = dict(start['pins']) | done['artifacts']
    for p in (leaf/'started.json', leaf/'closed.json', Path(__file__), Path(previous.__file__)):
        pins[str(p.resolve())] = native.sha(p)
    assert native.stable(pins)
    return pins


def adapted_main():
    assert native.sha(previous.__file__) == '8fa9b0f1db1225b6feeb6aa2e9c73262657bbc24651530bc128724d49c3132e6'
    text = inspect.getsource(previous.main)
    for old, new in (("(leaf/'core_bus_driver.svh')", "(leaf/'core_mem_chain.svh')"),
        ("'tb_decode_bus_'", "'tb_raw_prime_storage_'"),
        ('Only no-request DECODE address payload; MMU/fault/request authority unchanged',
         'Only unreachable RAW retained storage removed; original state machine retained as simulation witness')):
        assert text.count(old) == 1
        text = text.replace(old, new)
    return text


def main():
    scope = dict(previous.__dict__, __file__=__file__, recipe=recipe, MODEL=MODEL, check_leaf=check_leaf)
    exec(compile(adapted_main(), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__':raise SystemExit(main())
