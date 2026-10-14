"""Build the sequentially checked next-line lookup as a one-file derivative.

Keep the current-tag parent, unique host/header, 152 defines, 32 jobs and the
shared bounded builder. Preparation/build are not canonical or FPGA acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

import prepare_parallel_next_tag as recipe
from build_window_current_core import native,REPO

MODEL='737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'
FILE='rtl/mem/ven_l1d.sv'
CACHE='3ffb3031b78800e507b71b6b2894dafc617ff963c7e666c2894bb40b41739516'
REGRESSION='1dd4b7175a442465dac426b026255b283acfd9d985bda1d9e7893b5872cddf28'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert native.sha(native.__file__)=='9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    if args.action=='build':
        assert os.sched_getaffinity(0)==set(range(8,16))
        assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
        subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
        assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
        subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                        'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
        native.MODEL=MODEL; native.CHANGES=[FILE]
        return native.build(root)
    assert not root.exists()
    data=scratch/'ventium-data-size.v2HaTO2X'
    parent,cache=data/'window-current-core-r1',data/'parallel-next-tag-cache-r1'
    old,built=native.load(parent/'build-started.json'),native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    assert native.sha(data/'window-current-regression-audit.json')==REGRESSION
    regression=native.load(data/'window-current-regression-audit.json')
    assert regression['audit_passed'] and regression['functional_passes']==108
    assert regression['cycle_traces_unchanged']==20 and not regression['canonical_gate_passed']
    assert native.sha(cache/'closed.json')==CACHE
    checked,begun=native.load(cache/'closed.json'),native.load(cache/'started.json')
    assert checked['passed'] and checked['pins_unchanged'] and checked['no_oom'] and not checked['error']
    assert [(r['mutant'],r['build_exit'],r['native_exit']) for r in checked['rows']]==[(False,0,0),(True,0,1)]
    assert checked['rows'][0]['coverage']==dict(hit=361977,owner=463,crossing=6984)
    owner=dict(line.split('=',1) for line in subprocess.check_output(['systemctl','--user','show',
        'ventium-next-tag-cache-oct13-r1.service','-pSubState','-pMainPID','-pExecMainStatus',
        '-pInvocationID'],text=True).splitlines())
    # systemd-run gives the inner scope its OWN invocation ID. Do not compare
    # it with the retained outer service's ID or mistake one for the other.
    assert owner==dict(SubState='exited',MainPID='0',ExecMainStatus='0',
                      InvocationID='640c23fe562c408d9151b34c64f1d9ef')
    assert re.fullmatch('[0-9a-f]{32}',begun['invocation'])
    entries=[json.loads(line)
             for line in subprocess.check_output(['journalctl','--user',
                 '_SYSTEMD_INVOCATION_ID='+begun['invocation'],'-o','json','--no-pager'],text=True).splitlines()]
    messages=[json.loads(e['MESSAGE']) for e in entries
              if e['MESSAGE'].startswith('{')]
    published=[m for m in messages if 'pins_unchanged' in m]
    assert len(published)==1 and published[0]=={k:v for k,v in checked.items() if k not in ('pins','rows')}
    source=parent/'candidate'; files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and '-GAXI_LINE_REPLAY=0' in flags[0]
    assert 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152
    assert ['+define+'+d for d in definitions]==[s for s in checked['rows'][0]['command'] if s.startswith('+define+')]
    changed=recipe.transform((source/FILE).read_text())
    assert changed==(cache/'positive/ven_l1d.sv').read_text()
    pins=dict(old['pins']); pins.update(checked['pins'])
    for row in checked['rows']: pins.update(row['artifacts'])
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
              Path(__file__).with_name('build_window_current_core.py'),cache/'started.json',cache/'closed.json',
              data/'window-current-regression-audit.json',parent/'build-started.json',
              parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/FILE).write_text(changed)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n)]==[FILE]
    host=root/('tb_parallel_next_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[FILE],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    print('Prepared next-line tag candidate; no compiler or FPGA launch.')
    return 0


if __name__=='__main__': raise SystemExit(main())
