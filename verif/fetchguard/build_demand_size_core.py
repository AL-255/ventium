"""Source-closed demand-width derivative; preserve the 32-job native builder.

Require both leaf profiles and all negative controls before compiling a new
private whole-core model. A successful build is not functional acceptance.
"""
import inspect
from pathlib import Path

import build_decode_bus_core as predecessor
import prepare_demand_size_payload as recipe
import run_demand_size_payload as leaf_runner

MODEL = 'c55b996c2c8309e2c152dbab2813a144e5e30db83df6acfa190425e94067b84f'
native = predecessor.native


def check_leaf(leaf):
    before, checked = [native.load(leaf/n) for n in ('started.json', 'closed.json')]
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert not checked['whole_core'] and before['cpu'] == 13
    assert before['limits'] == {'memory.max': str(512*1024**2),
                                'memory.swap.max': '0', 'pids.max': '64'}
    assert all(checked['memory_events'][k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    assert [(r['profile'], r['mode']) for r in checked['rows']] == [
        (profile, mode) for profile in (False, True) for mode in leaf_runner.MODES]
    for row in checked['rows']:
        prefix = str(int(row['profile']))+'-'+row['mode']
        result = row['results']
        positive = row['mode'] == 'positive'
        for label in ('compile', 'native'):
            run = result[label]
            assert run['actual_wait'] and run['affinity'] == [13]
            assert run['log_sha256'] == native.sha(leaf/(prefix+'.'+label+'.log'))
        assert result['compile']['native_exit'] == 0
        assert result['native']['native_exit'] == (0 if positive else 1)
        log = (leaf/(prefix+'.native.log')).read_text()
        if positive:
            coverage = result['native']['coverage']
            assert coverage['checks'] == 229376 and coverage['beats'] == 6944
            assert coverage['idle'] > 0 and coverage['clipped'] > 0
            assert 'DEMAND-SIZE-OK checks=229376 beats=6944 ' in log
        else:
            marker = ('DEMAND-SIZE-PAYLOAD-DEPENDENCE' if row['mode'] == 'late-control'
                      else 'DEMAND-SIZE-MISMATCH')
            assert marker in log
    assert native.stable(before['pins']) and native.stable(checked['artifacts'])
    return dict(before['pins']) | checked['artifacts'] | {
        str(Path(p).resolve()): native.sha(p) for p in
        (predecessor.__file__, leaf_runner.__file__, leaf/'started.json')}


def main():
    namespace = dict(predecessor.__dict__)
    namespace.update(__file__=__file__, recipe=recipe, MODEL=MODEL, check_leaf=check_leaf)
    source = inspect.getsource(predecessor.main)
    changes = [
        ("(leaf/'core_bus_driver.svh')", "(leaf/'core.sv')"),
        ("'tb_decode_bus_'", "'tb_demand_size_'"),
        ("contract_change='Only no-request DECODE address payload; MMU/fault/request authority unchanged'",
         "contract_change='Demand width payload independent of request; issued extent and all authority unchanged'")]
    for old, new in changes:
        assert source.count(old) == 1
        source = source.replace(old, new)
    exec(compile(source, __file__, 'exec'), namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
