"""Reuse the source-closed 32-job builder with the early payload recipe.

The native build, cgroup/lock checks and private host-object rules are unchanged.
No existing source/model is edited. The whole-core old-driver shadow is retained
for assertions in this model and excluded from hardware by SYNTHESIS.
"""
import inspect
from pathlib import Path

import build_decode_bus_core as predecessor
import prepare_early_bus_payload as recipe
import run_early_bus_payload as leaf_runner

MODEL = '30274adaf425f55835f21562d845b08bec4552d37f4e29fd35ae7d3a95cb0b25'
native = predecessor.native


def check_leaf(leaf):
    before, checked = [native.load(leaf/n) for n in ('started.json','closed.json')]
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert not checked['whole_core'] and [r['mode'] for r in checked['rows']] == list(leaf_runner.MODES)
    for row in checked['rows']:
        assert all(r['actual_wait'] for r in row['results'].values())
        assert row['results']['compile']['native_exit'] == 0
        assert row['results']['native']['native_exit'] == (0 if row['mode']=='positive' else 1)
    assert checked['rows'][0]['results']['native']['coverage']['checks'] == 294912
    assert (leaf/'proof.log').read_text().strip() == 'unsat'
    assert native.stable(before['pins']) and native.stable(checked['artifacts'])
    return dict(before['pins']) | checked['artifacts'] | {
        str(Path(predecessor.__file__).resolve()): native.sha(predecessor.__file__),
        str(Path(leaf_runner.__file__).resolve()): native.sha(leaf_runner.__file__)}


def main():
    namespace = dict(predecessor.__dict__)
    namespace.update(__file__=__file__,recipe=recipe,MODEL=MODEL,check_leaf=check_leaf)
    source = inspect.getsource(predecessor.main)
    old = "contract_change='Only no-request DECODE address payload; MMU/fault/request authority unchanged'"
    new = "contract_change='Early linear default plus unchanged physical overrides; complete predecessor bus-driver shadow'"
    assert source.count(old) == 1
    source = source.replace(old,new).replace("'tb_decode_bus_'", "'tb_early_bus_'")
    exec(compile(source,__file__,'exec'),namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
