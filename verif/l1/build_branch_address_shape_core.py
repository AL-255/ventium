"""Isolated early branch-address model; preserve the qualified underflow core."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess

import prepare_branch_address_shape as recipe
from build_current_u_pair_core import native

REPO = Path(__file__).resolve().parents[2]
MODEL = '77c0c895122a6d7c890924e4806af51d287cd64c5d2094aa9eaa8032079fab1d'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','leaf','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); parent=a.parent.resolve(strict=True); leaf=a.leaf.resolve(strict=True); root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and os.sched_getaffinity(0)==set(range(32))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    old,built=[native.load(parent/n) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    before,checked=[native.load(leaf/n) for n in ('started.json','closed.json')]
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert [(r['name'],r['native_exit']) for r in checked['rows']]==[
        ('positive',0),('drop-held',1),('drop-fp',1),('never-branch',1),('always-branch',1)]
    pins=dict(before['pins']); assert native.stable(pins)
    source=parent/'candidate'; files=native.common.candidate_files(source)
    assert len(files)==195
    for p in files:
        assert native.sha(p)==old['pins'][str(p)]; pins[str(p)]=native.sha(p)
    replacement=recipe.transform((source/recipe.FILE).read_text())
    assert replacement==(leaf/'core_mem_chain.svh').read_text()
    host_old=Path(old['host']); dep=parent/'obj'/(host_old.stem+'.d')
    for token in dep.read_text().replace('\\\n',' ').split()[1:]:
        p=Path(token)
        if not p.is_absolute(): p=parent/'obj'/p
        if p.is_relative_to(parent/'obj'): continue
        assert p.is_file()
        if str(p) in old['pins']: assert native.sha(p)==old['pins'][str(p)]
        pins[str(p)]=native.sha(p)
    for p in (REPO/'verif/tb').iterdir():
        if p.is_file() and (p.suffix in ('.cpp','.h','.hpp') or p.name=='Makefile'):
            if str(p) in old['pins']: assert native.sha(p)==old['pins'][str(p)]
            pins[str(p)]=native.sha(p)
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
              REPO/'verif/l1/build_mc_branch_residency_core.py',REPO/'tools/build_scope.sh',
              REPO/'tools/verilator_serial.sh',parent/'build-started.json',parent/'build-closed.json',
              parent/'obj/tb_ventium',host_old,dep,leaf/'started.json',leaf/'closed.json',leaf/'core_mem_chain.svh'):
        pins[str(p.resolve())]=native.sha(p)
    flags=next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions=re.findall(r'\+define\+(\w+)',flags)
    assert len(definitions)==len(set(definitions))==152
    assert '--assert' in flags and '-GAXI_LINE_REPLAY=0' in flags and 'VL_J=32' in old['command']
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.FILE).write_text(replacement)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert sorted(n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n))==[recipe.FILE]
    host=root/('tb_branch_address_shape_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(host_old,host)
    command=native.common.relocate(old['command'],parent,root,host_old,host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.FILE],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        contract_change='Only unused raw non-memory query payloads may differ; original admission unchanged'))
    native.MODEL,native.CHANGES=MODEL,[recipe.FILE]
    return native.build(root)


if __name__=='__main__':raise SystemExit(main())
