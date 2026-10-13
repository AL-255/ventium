"""Prepare/build the two-line environment-write repair on the timed core.

Require the closed native 64-failure witness before preparing; compile only
inside the existing 32-job guarded scope with no Vivado family alive.
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

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
import prepare_write_class as recipe
sys.path.insert(0,str(REPO/'verif/sys/smsw_memory'))
spec=importlib.util.spec_from_file_location('env_write_native_builder',REPO/'verif/sys/smsw_memory/build_core.py')
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
MODEL='fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert native.sha(native.__file__)=='9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    if a.action=='build':
        assert os.sched_getaffinity(0)==set(range(8,16))
        assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
        subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
        assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
        subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                        'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
        native.MODEL=MODEL;native.CHANGES=[recipe.FILE]
        return native.build(root)
    assert not root.exists()
    parent=scratch/'ventium-data-size.v2HaTO2X/core-r1'
    witness=scratch/'ventium-data-size.v2HaTO2X/envfault-r2'
    old,built=native.load(parent/'build-started.json'),native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    checked=native.load(witness/'closed.json')
    assert not checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert len(checked['rows'])==44 and native.stable({str(witness/n):h for n,h in checked['artifacts'].items()})
    failures=0
    for r in checked['rows']:
        c=r['case'];assert r['golden_exit']==0 and r['qemu_exit']==(135 if c['INJECT'] else 133)
        assert len(r['rows'])==2
        for m in r['rows']:
            if c['HEAD'] and not c['INJECT']:
                assert m['rtl_exit']==135 and not m['rtl_self_check'] and m['compare_exit']==1
                failures+=1
            else:
                assert m['rtl_self_check'] and m['compare_exit']==0
    assert failures==64
    source=parent/'candidate';files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and '-GAXI_LINE_REPLAY=0' in flags[0]
    assert 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0]);assert len(set(definitions))==152
    changed=recipe.transform((source/recipe.FILE).read_text())
    pins=dict(old['pins'])
    pins.update({str(witness/n):h for n,h in checked['artifacts'].items()})
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
              HERE/'test_write_class.py',witness/'closed.json',parent/'build-started.json',
              parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir();shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.FILE).write_text(changed)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n)]==[recipe.FILE]
    host=root/('tb_env_write_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.FILE],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    print('Prepared one-file environment-write repair; no compiler or FPGA launch.')
    return 0


if __name__=='__main__':raise SystemExit(main())
