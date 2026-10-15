"""Build the one-file fetch-fragment derivative of the retained faster parent.

Keep the existing bounded builder, all 195 frozen sources and 152 defines.
The sole separately recorded tooling delta is the installed, native-qualified
worker cache repair. Old closed ledgers are never rewritten.
"""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_fetch_fragment_extent as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/sys/smsw_memory'))
spec=importlib.util.spec_from_file_location('fetch_fragment_native_builder',REPO/'verif/sys/smsw_memory/build_core.py')
native=importlib.util.module_from_spec(spec); spec.loader.exec_module(native)
sys.path.insert(0,str(REPO/'verif/lib'))
import prepare_worker_cache_identity as cache_recipe

MODEL='e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'
WORKER=str(REPO/'verif/lib/verify_worker.sh')
WORKER_NEW='a39a497a74a92deef65c648a535835192085e904e8dffb497ef64aec7c6aa3e6'


def promote_worker_pin(pins, current):
    if pins.get(WORKER)!=cache_recipe.preexit.PARENT:
        raise ValueError('unexpected predecessor worker identity')
    if hashlib.sha256(current.encode()).hexdigest()!=WORKER_NEW:
        raise ValueError('unqualified current worker')
    if hashlib.sha256(cache_recipe.original(current).encode()).hexdigest()!=pins[WORKER]:
        raise ValueError('worker repair is not exact')
    return dict(pins, **{WORKER:WORKER_NEW})


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','leaf','out'): ap.add_argument('--'+name,required=True,type=Path)
    args=ap.parse_args()
    parent=args.parent.resolve(strict=True); leaf=args.leaf.resolve(strict=True)
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and os.sched_getaffinity(0)==set(range(32))
    assert native.sha(native.__file__)=='9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    subprocess.run(['systemctl','--user','set-property','--runtime',
        'ventium-ipc-parallel32.scope','MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    old,built=(native.load(parent/name) for name in ('build-started.json','build-closed.json'))
    checked=native.load(leaf/'closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert checked['profiles']==[dict(demand16=d,checks=8529920,mutants_failed=2) for d in (False,True)]
    assert [p['result'] for p in checked['proofs']]==['unsat','sat','sat','sat']
    assert len(checked['native'])==12 and native.stable(checked['pins'])
    assert all(native.sha(row['log'])==row['sha256'] and row['actual_wait'] and row['reaped']
               and row['affinity']==list(range(13,17)) for row in checked['native'])
    source=parent/'candidate'; files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and '-GAXI_LINE_REPLAY=0' in flags[0]
    assert 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(set(definitions))==len(definitions)==152
    changed=recipe.transform((source/recipe.FILE).read_text())
    assert changed==(leaf/'core.sv').read_text()
    pins=promote_worker_pin(old['pins'],Path(WORKER).read_text())
    qualification=scratch/'ventium-data-size.v2HaTO2X/worker-cache-identity-r2/composed-closed.json'
    assert native.sha(qualification)=='44f0e788f774cd044c9a00d51648a605d96195eddf61286ccdb12eecda744066'
    assert native.load(qualification)['passed']
    pins.update(checked['pins'])
    pins.update({row['log']:row['sha256'] for row in checked['native']})
    for path in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
                 Path(cache_recipe.__file__),Path(cache_recipe.preexit.__file__),qualification,
                 leaf/'closed.json',parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(path.resolve())]=native.sha(path)
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.FILE).write_text(changed)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n)]==[recipe.FILE]
    host=root/('tb_fetch_fragment_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.FILE],compiler_started=False,
        tooling_deltas=[dict(path=WORKER,before=old['pins'][WORKER],after=WORKER_NEW,
                            qualification=str(qualification),kind='native-qualified cache identity repair')],
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    native.MODEL,native.CHANGES=MODEL,[recipe.FILE]
    code=native.build(root)
    if code==0:
        actual=(root/'obj/Vventium_top__verFiles.dat').read_text()
        assert actual.count('-GAXI_LINE_REPLAY=0')==1
        assert set(re.findall(r'\+define\+(\w+)',actual))==set(definitions)
    return code


if __name__=='__main__': raise SystemExit(main())
