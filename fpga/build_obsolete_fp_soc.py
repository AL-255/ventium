"""Transfer checked extent + obsolete-x87 deltas to a diagnostic full PC.

Canonical and state differential failures remain failures. Never claim FPGA
acceptance from a successful source transfer or native compiler exit.
"""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/sys/obsolete_fp'))
import prepare_repaired as fp_recipe
spec=importlib.util.spec_from_file_location('segment_extent_recipe',REPO/'verif/segment_extent/prepare.py')
extent=importlib.util.module_from_spec(spec);spec.loader.exec_module(extent)

sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='3e0f22506604fba879a6fa292463b5d07e442e86d24a4e91ec012cfcf2d05751'
CORE_MODEL='2fc497047dc64848f28a920522a6fa4ec1e8ef0c686179394576d6237402acb2'
BUILDER='9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
CHANGES=sorted([extent.FILE,*('rtl/core/'+n for n in fp_recipe.PARENTS)])


def prepare(parent,core,basic,state,replay,root):
    assert not root.exists() and sha(base.__file__)==BUILDER
    pins={}
    for folder,count,passed,diff in ((basic,32,True,32),(state,24,False,6)):
        c,s=load(folder/'closed.json'),load(folder/'started.json')
        assert c['passed']==passed and c['pins_unchanged'] and not c['errors']
        assert s['model_sha256']==CORE_MODEL and len(s['definitions'])==152
        assert len(c['rows'])==count and all(r['rtl_self_check'] for r in c['rows'])
        assert sum(r['passed'] for r in c['rows'])==diff
        assert not c['standard_suite'] and not c['hardware_acceptance']
        pins.update(s['pins'])
        for row in c['rows']:pins.update(row['artifacts'])
        pins[str(folder/'closed.json')]=sha(folder/'closed.json')
    a,astart=load(replay/'closed.json'),load(replay/'started.json')
    assert a['same_input_regression_passed'] and a['pins_unchanged'] and not a['errors']
    assert len(a['rows'])==108 and a['records']==80800 and not a['canonical_gate_passed']
    assert astart['models']['candidate']==str(core/'obj/tb_ventium')
    pins.update(astart['pins']);pins[str(replay/'closed.json')]=sha(replay/'closed.json')
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    before,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged']
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==CORE_MODEL
    assert stable(before['pins']) and stable(pins)
    source=parent/'source';files=sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==old['pins'][str(p)] for p in files)
    shared=[str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
            and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102 and [p for p in shared if sha(source/p)!=sha(core/'candidate'/p)]==CHANGES
    assert extent.transform((source/extent.FILE).read_text())==(core/'candidate'/extent.FILE).read_text()
    for name in fp_recipe.PARENTS:
        assert fp_recipe.transform((source/'rtl/core'/name).read_text(),name)==(core/'candidate/rtl/core'/name).read_text()
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    root.mkdir();shutil.copytree(source,root/'source')
    for name in CHANGES:shutil.copyfile(core/'candidate'/name,root/'source'/name)
    assert all(sha(root/'source'/name)==sha(core/'candidate'/name) for name in shared)
    host=root/'source/ao486-sim/ven'/('sim_obsolete_fp_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(root)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]
    assert command[:2]==[str(REPO/'tools/build_scope.sh'),'--'] and '600s' in command
    defs=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs)==len(set(defs))==156 and set(defs)==set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dependency=parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        p=Path(name)
        if p.is_absolute():pins[str(p)]=sha(p)
    for p in (*files,*(p for p in (root/'source').rglob('*') if p.is_file()),Path(__file__),
        Path(fp_recipe.__file__),Path(extent.__file__),Path(base.__file__),Path(base.common.__file__),
        root/'defines.txt',parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
        core/'build-started.json',core/'build-closed.json',core/'verify-closed.json',core/'obj/tb_ventium'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL,directed_model=CORE_MODEL,canonical_gate_passed=False,
        state_differential_gate_passed=False,qualification='UNQUALIFIED'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('prepare','build'))
    for name in ('parent','core','basic','state','replay'):parser.add_argument('--'+name,type=Path)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args();root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and sha(base.__file__)==BUILDER
    if args.action=='prepare':
        names=('parent','core','basic','state','replay')
        assert all(getattr(args,n) for n in names)
        prepare(*(getattr(args,n).resolve(strict=True) for n in names),root)
        print('Prepared exact three-file full-PC transfer; no compiler or FPGA action.',flush=True)
        return 0
    return base.build(root)


if __name__=='__main__':raise SystemExit(main())
