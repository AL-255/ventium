#!/usr/bin/env python3
"""Transfer the verified read-only completion delta into the matching PC model.

Preparation requires all complete directed comparisons and canonical A/B; the
canonical gate's actual failure status is retained, never promoted to a pass.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_rem_split_soc as previous
base = previous.base
REPO = base.REPO
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_load_read_ack as recipe

sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = '61763f61ef15dadd24602e8cc86b1b4e3bdab75b5bc2c3280d84ad90bdb8cd58'
CORE_MODEL = '6d53d0934c9a3c6e7e89d632ccf0d677a0360b4dcb3caeeb917a1f131bd6e6cc'


def prepare(parent, core, out):
    assert not out.exists()
    old, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert closed['binary_sha256']==sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==PARENT_MODEL
    started, built = load(core/'build-started.json'), load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert built['binary_sha256']==sha(core/'obj/tb_ventium')==CORE_MODEL and stable(started['pins'])
    assert started['changes']==[recipe.PAYLOAD]
    pins, statistics = previous.regressions(core)
    far = core.parent/'far-r1'
    before, done = load(far/'started.json'), load(far/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors'] and stable(before['pins'])
    assert len(done['measurements'])==20 and all(sha(far/p)==h for p,h in done['artifacts'].items())
    assert str(core/'obj/tb_ventium') in before['pins']
    pins.update(before['pins'])
    for p in (far/'started.json',far/'closed.json'): pins[str(p)]=sha(p)
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p)==old['pins'][str(p)] for p in files)
    changed = recipe.transform((source/recipe.PAYLOAD).read_text())
    assert changed==(core/'candidate'/recipe.PAYLOAD).read_text()
    shared = [str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102
    assert [n for n in shared if sha(source/n)!=sha(core/'candidate'/n)]==[recipe.PAYLOAD]
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    out.mkdir()
    shutil.copytree(source,out/'source')
    shutil.copyfile(core/'candidate'/recipe.PAYLOAD,out/'source'/recipe.PAYLOAD)
    assert all(sha(out/'source'/n)==sha(core/'candidate'/n) for n in shared)
    host=out/'source/ao486-sim/ven'/('sim_load_read_ack_'+hashlib.sha256(str(out).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(out)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    definitions=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(definitions)==len(set(definitions))==156
    assert set(definitions)==set((parent/'defines.txt').read_text().splitlines())
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT',
            'VEN_FP_LOAD_EARLY_CMD','VEN_SRT_REM_OPERAND_SPLIT','VEN_P54_DUAL_LOAD_PAIR'}<=set(definitions)
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (out/'defines.txt').write_text('\n'.join(sorted(definitions))+'\n')
    dependency=parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        p=Path(name)
        if p.is_absolute(): pins[str(p)]=sha(p)
    for p in (*files,*(p for p in (out/'source').rglob('*') if p.is_file()),Path(__file__),
              Path(recipe.__file__),Path(previous.__file__),Path(base.__file__),out/'defines.txt',
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              core/'build-started.json',core/'build-closed.json',core/'obj/tb_ventium'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(out/'prepared.json',dict(command=command,pins=pins,changes=[recipe.PAYLOAD],added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        statistics=statistics,parent_model=PARENT_MODEL,directed_model=CORE_MODEL,
        canonical_gate_passed=False,qualification='UNQUALIFIED'))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('prepare','build'))
    for name in ('parent','core'): parser.add_argument('--'+name,type=Path)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    out=args.out.resolve()
    assert __debug__ and out!=scratch and out.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    if args.action=='prepare':
        prepare(args.parent.resolve(strict=True),args.core.resolve(strict=True),out)
        print('Prepared source-matched load-ACK PC; compiler not launched.',flush=True)
    else:
        raise SystemExit(base.build(out))
