"""Build the leaf-tested repair without inheriting rejected fetch metadata RTL."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_remainder_underflow_core as recipe
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import build_current_u_pair_core as base
native = base.native
MODEL = '2ac15c8ba4fd6fbfcfb2dccb0daa0bb41448e7756b6abd2b2e32b8a92684bc1e'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('out','parent','leaf'): ap.add_argument('--'+n,type=Path,required=True)
    a = ap.parse_args(); root = a.out.resolve(); parent = a.parent.resolve(strict=True)
    leaf = a.leaf.resolve(strict=True); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3 and os.sched_getaffinity(0) == set(range(32))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    old,built = [native.load(parent/n) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    checked,started = [native.load(leaf/n) for n in ('closed.json','started.json')]
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert native.sha(leaf/'obj/test') == checked['binary_sha256'] == \
        '899139eaff1daa55ba00ed3cfc9003614775b36bebbea8c89f303f8544ab623b'
    for key,count,negative in (('underflow',7104,3216),('operands',9552,0),('infinite-divisor',576,72)):
        row = checked['matrices'][key]
        assert row['cases'] == count and row['latencies_unchanged']
        assert row['failures'] == dict(native=0,reference=0,candidate=0,control=negative)
        assert all(r['native_exit'] == 0 and r['actual_wait'] and r['reaped'] for r in row['executions'])
    props = dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',
        'ventium-fprem-underflow-rtl-oct15-r2.service','-p','SubState','-p','MainPID','-p','ExecMainStatus',
        '-p','InvocationID'],text=True).splitlines())
    # The controller service and guarded scope have distinct invocation IDs.
    # The leaf writes the scope's inherited INVOCATION_ID, not its controller's.
    assert props == dict(SubState='exited',MainPID='0',ExecMainStatus='0',
                         InvocationID='5c78150da5fd4f2e86d6c5af93e8ad8f')
    assert started['invocation'] == 'cc7f07f511b344b3aa54ba60a079de06'
    pins = dict(started['pins']); assert native.stable(pins)
    source = parent/'candidate'; files = native.common.candidate_files(source)
    assert len(files) == 195
    for p in files:
        assert native.sha(p) == old['pins'][str(p)]; pins[str(p)] = native.sha(p)
    derived = {n:recipe.transform((source/n).read_text(),n) for n in recipe.PARENTS}
    for n in recipe.PARENTS:
        if n != recipe.CORE: assert derived[n] == (leaf/'source'/n).read_text()
    # Audit the entire source closure against the tested leaf, not only the
    # changed FPU files. Its sole deliberate difference is the rejected core
    # metadata experiment; all other 194 files must be identical.
    leaf_files = native.common.candidate_files(leaf/'source')
    names = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(leaf/'source')) for p in leaf_files] == names
    for n in names:
        if n == recipe.CORE: continue
        if n in derived: assert derived[n] == (leaf/'source'/n).read_text()
        else: assert native.sha(source/n) == native.sha(leaf/'source'/n)
    assert 'u_fetch_metadata' not in derived[recipe.CORE]
    host_old = Path(old['host']); dep = parent/'obj'/(host_old.stem+'.d')
    for token in dep.read_text().replace('\\\n',' ').split()[1:]:
        p = Path(token)
        if not p.is_absolute(): p = parent/'obj'/p
        if p.is_relative_to(parent/'obj'): continue
        assert p.is_file()
        if str(p) in old['pins']: assert native.sha(p) == old['pins'][str(p)]
        pins[str(p)] = native.sha(p)
    for p in (REPO/'verif/tb').iterdir():
        if p.is_file() and (p.suffix in ('.cpp','.h','.hpp') or p.name == 'Makefile'):
            if str(p) in old['pins']: assert native.sha(p) == old['pins'][str(p)]
            pins[str(p)] = native.sha(p)
    for p in (Path(__file__),Path(recipe.__file__),Path(recipe.leaf.__file__),Path(base.__file__),
              Path(native.__file__),Path(native.common.__file__),REPO/'verif/l1/build_mc_branch_residency_core.py',
              REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',parent/'build-started.json',
              parent/'build-closed.json',parent/'obj/tb_ventium',host_old,dep,
              leaf/'started.json',leaf/'closed.json',leaf/'obj/test',leaf/'engine.out'):
        pins[str(p.resolve())] = native.sha(p)
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)',flags)
    assert definitions == started['definitions'] and len(definitions) == len(set(definitions)) == 152
    assert '--assert' in flags and '-GAXI_LINE_REPLAY=0' in flags and 'VL_J=32' in old['command']
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    for n,v in derived.items(): (root/'candidate'/n).write_text(v)
    changes = sorted(recipe.PARENTS)
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')] == names
    assert sorted(n for n in names if native.sha(source/n) != native.sha(root/'candidate'/n)) == changes
    host = root/('tb_remainder_underflow_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(host_old,host)
    command = native.common.relocate(old['command'],parent,root,host_old,host)
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=changes,compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        rejected_metadata_inherited=False,legacy_unmasked_underflow_fixed=False,
        contract_change='FPREM exact tiny-result UE and exponent scaling in shared FPU'))
    native.MODEL,native.CHANGES = MODEL,changes
    return native.build(root)


if __name__ == '__main__': raise SystemExit(main())
