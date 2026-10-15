"""Build the V-result carry cut from the exact tested 153-define parent.

Two source changes only: V result payload and a simulation-only accepted-V
witness. No decoder, issuer, occupancy, cache or commit-authority modification.
Build success is not functional, standard-suite, timing or FPGA acceptance.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_v_result_carry as recipe
import run_v_result_carry_leaf as leaf_runner

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
from build_current_u_pair_core import native

MODEL=leaf_runner.MODEL
CHANGES=sorted(recipe.HASHES)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','leaf','out'):ap.add_argument('--'+name,type=Path,required=True)
    a=ap.parse_args();parent=a.parent.resolve(strict=True);leaf=a.leaf.resolve(strict=True);root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root!=scratch and root.is_relative_to(scratch) and not root.exists()
    assert all(not root.is_relative_to(p) and not p.is_relative_to(root) for p in (parent,leaf,REPO))
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and os.sched_getaffinity(0)==set(range(32))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    old,built=[native.load(parent/n) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    pins=leaf_runner.check_receipt(leaf)
    # Check the strengthened broad-pair witness, not the earlier insufficient
    # decoder-only sweep whose four explicit class cases also happened to pass.
    checked=native.load(leaf/'closed.json')
    assert all(r['counts']['accepted_v']>=1000 for r in checked['rows'] if r['mutant']==0)
    source=parent/'candidate';files=native.common.candidate_files(source)
    assert len(files)==195
    for p in files:
        assert native.sha(p)==old['pins'][str(p)];pins[str(p)]=native.sha(p)
    replacements={name:recipe.transform((source/name).read_text(),name) for name in CHANGES}
    assert all(text==(leaf/Path(name).name).read_text() for name,text in replacements.items())
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
    for p in (Path(__file__),Path(recipe.__file__),Path(leaf_runner.__file__),Path(native.__file__),
              Path(native.common.__file__),REPO/'verif/l1/build_current_u_pair_core.py',
              REPO/'verif/l1/build_mc_branch_residency_core.py',REPO/'tools/build_scope.sh',
              REPO/'tools/verilator_serial.sh',parent/'build-started.json',parent/'build-closed.json',
              parent/'obj/tb_ventium',host_old,dep,leaf/'closed.json'):
        pins[str(p.resolve())]=native.sha(p)
    flags=next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions=re.findall(r'\+define\+(\w+)',flags)
    assert len(definitions)==len(set(definitions))==153 and definitions==old['definitions']
    assert {'VEN_FE_PIPE','VEN_L1_AXI','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_X87_MF_STRICT'}<=set(definitions)
    assert 'VEN_P54_REGMEM_PRIME' not in definitions
    assert '--assert' in flags and '-GAXI_LINE_REPLAY=0' in flags and 'VL_J=32' in old['command']
    assert native.stable(pins)
    root.mkdir();shutil.copytree(source,root/'candidate')
    for name,text in replacements.items():(root/'candidate'/name).write_text(text)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert sorted(n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n))==CHANGES
    host=root/('tb_v_result_carry_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(host_old,host)
    command=native.common.relocate(old['command'],parent,root,host_old,host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=CHANGES,compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        contract_change='V arithmetic result independent of CF; flag forwarding and all retirement authority retained'))
    native.MODEL,native.CHANGES=MODEL,CHANGES
    return native.build(root)


if __name__=='__main__':raise SystemExit(main())
