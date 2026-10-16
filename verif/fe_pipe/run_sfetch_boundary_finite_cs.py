"""Run the eight unchanged finite-CS guests with the boundary-stage model.

Full architectural A/B equality, exact #GP restart/frame self-checks and real
paired execution remain mandatory. Cycles are measured, not required equal.
The known QEMU finite-CS discrepancy is retained, not counted as a pass.
"""
import inspect
import json
from pathlib import Path

import prepare_sfetch_boundary_stage as recipe
import run_fetch_fragment_finite_cs as previous

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
MODELS = {
    'parent': (str(ROOT/'v-result-carry-core-r1'),'a8e5d55b7704f2449002c71af8db1c5c2fe7ae908669fc5dbf2e663d3a59ff73'),
    'candidate': (str(ROOT/'sfetch-boundary-core-r1'),'e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a'),
}


def main():
    assert previous.sha(previous.__file__)=='d3693b7c473b5d02fe6c4c3c28f1a628f94e9463f972637382400ead0adef604'
    pins = {}
    for root,digest in MODELS.values():
        folder = Path(root)
        before,done = [json.loads((folder/n).read_text()) for n in ('build-started.json','build-closed.json')]
        assert done['passed'] and done['pins_unchanged'] and done['native_exit']==0
        assert previous.sha(folder/'obj/tb_ventium')==done['binary_sha256']==digest
        pins.update(before['pins'])
    for name in recipe.PARENTS:
        assert recipe.transform((ROOT/'v-result-carry-core-r1/candidate'/name).read_text(),name)==(
            ROOT/'sfetch-boundary-core-r1/candidate'/name).read_text()
    for p in (Path(__file__),Path(recipe.__file__),Path(recipe.base.__file__),Path(previous.__file__)):
        pins[str(p.resolve())]=previous.sha(p)
    assert all(previous.sha(p)==h for p,h in pins.items())
    namespace = dict(previous.__dict__, __file__=__file__, MODELS=MODELS, extra_pins=pins)
    definitions = inspect.getsource(previous.model_definitions)
    definitions = recipe.replace_once(definitions,'len(definitions) == 153 and len(counts) == 152',
        'len(definitions) == 154 and len(counts) == 153 and "VEN_X87_MF_STRICT" in counts')
    exec(compile(definitions,__file__,'exec'),namespace)
    text = inspect.getsource(previous.main)
    for old,new in (
        ('{13, 14, 15, 16}','{20, 21, 22, 23}'),
        ('pins = {}','pins = dict(extra_pins)'),
        ('13+index%4','20+index%4'),
        ("else: assert records[key] == trace.records, (case, latency, mode, 'full-state/cycle mismatch')",
         "elif mode == 'cycle-func': assert records[key] == trace.records, (case, latency, mode, 'full architectural state mismatch')"),
    ):
        assert old in text
        text = text.replace(old,new)
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':
    raise SystemExit(main())
