"""Compose the sequentially checked current-tag cut onto the x87-write repair.

Private source tree, unchanged 152 definitions/board single-fill policy, unique
host object/header and the established 32-job guarded native builder.
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

import prepare_window_current_reuse as recipe

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
sys.path.insert(0,str(REPO/'verif/sys/smsw_memory'))
spec=importlib.util.spec_from_file_location('window_current_native_builder',REPO/'verif/sys/smsw_memory/build_core.py')
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
MODEL='360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779'
FILE='rtl/mem/ven_l1d.sv'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    assert native.sha(native.__file__)=='9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    if a.action=='build':
        assert os.sched_getaffinity(0)==set(range(8,16))
        assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
        subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
        assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
        subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                        'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
        native.MODEL=MODEL;native.CHANGES=[FILE]
        return native.build(root)
    assert not root.exists()
    evidence=scratch/'ventium-data-size.v2HaTO2X'
    parent,cache=evidence/'env-write-core-r1',evidence/'window-current-cache-r1'
    old,built=native.load(parent/'build-started.json'),native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    regress=native.load(evidence/'env-write-regression-audit.json')
    assert regress['audit_passed'] and regress['functional_passes']==108
    assert regress['cycle_traces_unchanged']==20 and not regress['canonical_gate_passed']
    checked=native.load(cache/'closed.json');begun=native.load(cache/'started.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert [(r['mutant'],r['build_exit'],r['native_exit']) for r in checked['rows']]==[(False,0,0),(True,0,1)]
    assert 'PARALLEL-CACHE-MITER checks=747037 next=463' in checked['rows'][0]['coverage']
    props=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',
        'ventium-window-current-cache-oct13-r1.service','-pSubState','-pMainPID','-pExecMainStatus'],text=True).splitlines())
    assert props==dict(SubState='exited',MainPID='0',ExecMainStatus='0')
    source=parent/'candidate';files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and '-GAXI_LINE_REPLAY=0' in flags[0]
    assert 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(set(definitions))==152 and set(begun['defines'])=={'+define+'+d for d in definitions}
    changed=recipe.transform((source/FILE).read_text())
    assert changed==(cache/'positive/ven_l1d.sv').read_text()
    pins=dict(old['pins']);pins.update(checked['pins'])
    for row in checked['rows']:pins.update(row['artifacts'])
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
              HERE/'test_window_current_driver.py',cache/'started.json',cache/'closed.json',
              evidence/'env-write-audit.json',evidence/'env-write-regression-audit.json',
              parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir();shutil.copytree(source,root/'candidate')
    (root/'candidate'/FILE).write_text(changed)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n)]==[FILE]
    host=root/('tb_window_current_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[FILE],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    print('Prepared current-tag saved-window candidate; no compiler or FPGA launch.')
    return 0


if __name__=='__main__':raise SystemExit(main())
