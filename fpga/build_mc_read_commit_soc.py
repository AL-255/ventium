#!/usr/bin/env python3
"""Carry the source-tested read-hint cofactor into the unchanged PC platform."""
import argparse
import os
from pathlib import Path
import shutil
import sys

import build_pair_ready_soc as common

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_mc_read_commit as patch

PARENT_MODEL = '6583d6577f3099fe0e84bf52762516300843a8c1658f5cc373ec8c2240dcc090'
CORE_MODEL = '64dadfc92c708c49d45e8c0f3b7704e1c24dff48f8d525956dc4624946a07695'
TARGET = 'rtl/core/core_mem_chain.svh'
sha, load, save, stable = common.sha, common.load, common.save, common.stable


def prepare(parent, proof, root):
    assert not root.exists()
    old, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert closed['binary_sha256'] == sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == PARENT_MODEL
    core = proof/'core-r1'
    built, prepared = load(core/'build-closed.json'), load(core/'prepared.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(core/'obj/tb_ventium') == CORE_MODEL
    assert stable(prepared['pins'])
    pins = {}
    for name in ('memory-r1','store-r1','fp-r1/matrix'):
        before, checked = load(proof/name/'started.json'), load(proof/name/'closed.json')
        assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
        assert len(checked['measurements']) == 288 and stable(before['pins'])
        assert before['models']['candidate'] == str((core/'obj/tb_ventium').resolve())
        if name != 'fp-r1/matrix': assert checked['memory_v_retirements'] > 0
        pins.update(before['pins'])
        for file in ('started.json','closed.json'): pins[str(proof/name/file)] = sha(proof/name/file)
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p) == old['pins'][str(p)] for p in files)
    expected = patch.transform((source/'rtl/core/core.sv').read_text(), (source/TARGET).read_text())
    assert expected == (core/'candidate'/TARGET).read_text()
    shared = [str(p.relative_to(source)) for p in files
              if p.relative_to(source).parts[0] in ('rtl','fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared) == 102
    assert [p for p in shared if sha(source/p) != sha(core/'candidate'/p)] == [TARGET]
    root.mkdir(); shutil.copytree(source, root/'source')
    shutil.copyfile(core/'candidate'/TARGET, root/'source'/TARGET)
    assert all(sha(root/'source'/p) == sha(core/'candidate'/p) for p in shared)
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    host = root/'source/ao486-sim/ven'/('sim_mc_read_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(hosts[0],host)
    command = [s.replace(str(parent),str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    defs = [s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 154
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dep = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dep.read_text().replace('\\\n',' ').split()[1:]:
        path = Path(name)
        if path.is_absolute(): pins[str(path)] = sha(path)
    for p in (*files, *(p for p in (root/'source').rglob('*') if p.is_file()),
              Path(__file__), Path(common.__file__), Path(patch.__file__), root/'defines.txt',
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              core/'build-started.json',core/'build-closed.json',core/'prepared.json',core/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=[TARGET],added_defines=[],
        parent=str(parent),proof=str(proof),host=str(host),intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL,directed_model=CORE_MODEL,
        canonical_gate_passed=False,qualification='UNQUALIFIED'))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for name in ('parent','proof'): ap.add_argument('--'+name,type=Path)
    ap.add_argument('--out',type=Path,required=True); args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True); root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.proof
        prepare(args.parent.resolve(strict=True),args.proof.resolve(strict=True),root)
        print('Prepared private source-matched PC model; compiler not launched.',flush=True)
    else:
        raise SystemExit(common.build(root))
