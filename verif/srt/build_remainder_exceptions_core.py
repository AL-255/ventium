"""Build only the qualified shared-FPU exception delta on the numeric parent."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_remainder_exceptions as recipe
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import build_current_u_pair_core as base
native=base.native
MODEL='86afc1911cc3c9a066ad5888414af81683226c0a083e9f9d0e2acd4d13582f76'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('out','parent','leaf'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve();parent=a.parent.resolve(strict=True);leaf=a.leaf.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(32))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
        'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    old,built=[native.load(parent/n) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    checked=native.load(leaf/'closed.json');started=native.load(leaf/'started.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert [(r['name'],r['mismatches']) for r in checked['variants']]==[('parent',6860),('candidate',0)]
    assert all(r['cases']==9552 and r['native_exit']==r['build_exit']==0 for r in checked['variants'])
    props=dict(line.split('=',1) for line in subprocess.check_output(['systemctl','--user','show',
        'ventium-srt-remainder-exceptions-oct15-r3.service','-p','SubState','-p','MainPID','-p','ExecMainStatus'],text=True).splitlines())
    assert props==dict(SubState='exited',MainPID='0',ExecMainStatus='0')
    pins=dict(started['pins']);assert native.stable(pins)
    source=parent/'candidate';files=native.common.candidate_files(source);assert len(files)==195
    for p in files:
        assert native.sha(p)==old['pins'][str(p)]
        pins[str(p)]=native.sha(p)
    derived={n:recipe.transform((source/n).read_text(),n) for n in recipe.PARENTS}
    assert all(v==(leaf/'candidate/source'/n).read_text() for n,v in derived.items())
    host_old=Path(old['host']);dep=parent/'obj'/(host_old.stem+'.d')
    for token in dep.read_text().replace('\\\n',' ').split()[1:]:
        p=Path(token)
        if not p.is_absolute():p=parent/'obj'/p
        if p.is_relative_to(parent/'obj'):continue
        assert p.is_file()
        if str(p) in old['pins']:assert native.sha(p)==old['pins'][str(p)]
        pins[str(p)]=native.sha(p)
    for p in (REPO/'verif/tb').iterdir():
        if p.is_file() and (p.suffix in ('.cpp','.h','.hpp') or p.name=='Makefile'):
            if str(p) in old['pins']:assert native.sha(p)==old['pins'][str(p)]
            pins[str(p)]=native.sha(p)
    for p in (Path(__file__),Path(recipe.__file__),Path(base.__file__),Path(native.__file__),
              Path(native.common.__file__),REPO/'verif/l1/build_mc_branch_residency_core.py',
              REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',parent/'build-started.json',
              parent/'build-closed.json',parent/'obj/tb_ventium',host_old,dep,leaf/'started.json',leaf/'closed.json'):
        pins[str(p.resolve())]=native.sha(p)
    for v in checked['variants']:
        assert native.stable(v['artifacts']);pins.update(v['artifacts'])
    assert native.stable(pins)
    flags=next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions=re.findall(r'\+define\+(\w+)',flags)
    assert len(definitions)==len(set(definitions))==152
    assert '--assert' in flags and '-GAXI_LINE_REPLAY=0' in flags and 'VL_J=32' in old['command']
    root.mkdir();shutil.copytree(source,root/'candidate')
    for n,v in derived.items():(root/'candidate'/n).write_text(v)
    names=[str(p.relative_to(source)) for p in files];changes=sorted(recipe.PARENTS)
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert sorted(n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n))==changes
    host=root/('tb_remainder_exceptions_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(host_old,host)
    command=native.common.relocate(old['command'],parent,root,host_old,host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=changes,compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        contract_change='FPREM operand exceptions, unmasked abort, NaN priority and pseudo-denormal result'))
    native.MODEL,native.CHANGES=MODEL,changes
    return native.build(root)


if __name__=='__main__':raise SystemExit(main())
