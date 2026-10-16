"""Cold full-state checks and cycle-cost measurement for staged slow fetch.

Reuse the original guests, QEMU comparisons, fault witnesses, complete traces,
native exit checks and UV/AXI observations. Unlike combinational experiments,
this intentionally changes cycles; report them rather than asserting equality.
The original cycle-equivalence gate is neither edited nor reported as passing.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import build_sfetch_beat_core as builder
import prepare_sfetch_beat_stage as recipe
from run_sfetch_beat_stage_leaf import sha

REPO = Path(__file__).resolve().parents[2]
SOURCES = {
    'boundaries': ('verif/fetchguard/run_probe_boundary_ab.py',
                   '79d92aa2d3c620fc4612914ef9ef5f17516962514178976078b791a69da8dea1'),
    'demand': ('verif/fe_pipe/run-sfetch16-demand.py',
               'c080f9c022f32176c24bd9c596eb0d5733a74b453fc6a94880730a6134a1f78c'),
}


def derive(mode):
    name, digest = SOURCES[mode]
    source = REPO/name
    assert sha(source) == digest
    original = source.read_text()
    if mode == 'boundaries':
        edits = [
            ('REPO=Path(__file__).resolve().parents[2]', 'REPO=Path('+repr(str(REPO))+')'),
            ("assert both['parent']==both['candidate'],('complete A/B mismatch',case,latency)",
             "assert both['parent']['cycle-func']==both['candidate']['cycle-func'],('complete architectural A/B mismatch',case,latency)"),
            ('complete QEMU/state/cycle A/B PASS', 'complete QEMU/state PASS; cycles measured separately'),
        ]
    else:
        edits = [
            ('HERE = Path(__file__).resolve().parent', 'HERE = Path('+repr(str(REPO/'verif/fe_pipe'))+')'),
            ("assert profiles['candidate'] == profiles['control'] | {'VEN_SFETCH16_DEMAND'}",
             "assert profiles['candidate'] == profiles['control'] and 'VEN_SFETCH16_DEMAND' in profiles['candidate']"),
        ]
    text = original
    for old,new in edits:
        text = recipe.replace_once(text,old,new)
    recovered = text
    for old,new in reversed(edits):
        recovered = recipe.replace_once(recovered,new,old)
    assert recovered == original
    compile(text,str(source),'exec')
    return source,text,edits


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode',choices=tuple(SOURCES))
    for name in ('core','out'): ap.add_argument('--'+name,type=Path,required=True)
    a = ap.parse_args()
    core,out = a.core.resolve(strict=True),a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert out.is_relative_to(scratch) and not out.exists()
    started,built = [json.loads((core/n).read_text()) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    parent = Path(started['parent'])
    assert sha(parent/'obj/tb_ventium')==started['parent_model']==builder.MODEL
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']
    assert started['changes']==sorted(recipe.PARENTS)
    for name in recipe.PARENTS:
        assert recipe.transform((parent/'candidate'/name).read_text(),name)==(core/'candidate'/name).read_text()
    assert all(sha(p)==h for p,h in started['pins'].items())
    source,text,edits = derive(a.mode)
    driver = out.with_suffix('.driver.py')
    with driver.open('x') as f: f.write(text)
    if a.mode=='boundaries':
        tail = ['--parent',str(parent),'--candidate',str(core),'--fixtures',
                str(scratch/'ventium-data-size.v2HaTO2X/fetch-fixtures'),'--out',str(out)]
    else:
        tail = ['--control',str(parent/'obj/tb_ventium'),'--candidate',str(core/'obj/tb_ventium'),
                '--out',str(out),'--workers','32','--offset','0','--offset','31']
    command = [sys.executable,'-B',str(driver),*tail]
    pins = {str(p.resolve()):sha(p) for p in (Path(__file__),Path(recipe.__file__),source,driver,
        core/'build-started.json',core/'build-closed.json',parent/'obj/tb_ventium',core/'obj/tb_ventium')}
    with out.with_suffix('.adapter.json').open('x') as f:
        json.dump(dict(pins=pins,command=command,substitutions=edits,invocation=os.environ['INVOCATION_ID'],
                       architectural_comparisons_unchanged=True,cycle_equality_required=False),f,indent=2)
    status = subprocess.run(command,timeout=600,pass_fds=(9,) if a.mode=='demand' else ()).returncode
    stable = all(sha(p)==h for p,h in pins.items())
    with out.with_suffix('.adapter-closed.json').open('x') as f:
        json.dump(dict(native_exit=status,pins_unchanged=stable),f,indent=2)
    assert stable
    return status


if __name__=='__main__':
    raise SystemExit(main())
