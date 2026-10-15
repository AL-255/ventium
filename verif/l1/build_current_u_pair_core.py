"""Build the private current-U pairing specialization from the faster parent."""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_current_u_pair as recipe

REPO = Path(__file__).resolve().parents[2]
DATA = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve()
sys.path.insert(0, str(REPO/'verif/sys/smsw_memory'))
spec = importlib.util.spec_from_file_location('current_u_native_builder', REPO/'verif/sys/smsw_memory/build_core.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
MODEL = 'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == set(range(32))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], check=True, pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    parent = DATA/'prefix-payload-core-r1'
    old, built = [native.load(parent/name) for name in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    leaf = DATA/'current-u-pair-leaf-r1'
    checked = native.load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert [(r['label'],r['native_exit']) for r in checked['rows']] == [
        ('generic',0),('current-u',0),('current-u-lutram-two-window',0),('mutant-unowned',1)]
    assert native.stable(checked['pins'])
    # This is the direct source/build closure, not a recursively duplicated
    # ledger of every ancestral experiment. Unrelated verifier changes are
    # neither silently admitted nor misrepresented as compiler inputs.
    source = parent/'candidate'
    files = native.common.candidate_files(source)
    assert len(files) == 195
    pins = dict(checked['pins'])
    for path in files:
        assert native.sha(path) == old['pins'][str(path)]
        pins[str(path)] = native.sha(path)
    host_old = Path(old['host'])
    # Read the actual compiled host dependency closure, including private
    # reset/memcmp helpers. Generated model headers belong to the new model.
    dep = parent/'obj'/(host_old.stem+'.d')
    dependencies = dep.read_text().replace('\\\n',' ').split()[1:]
    for token in dependencies:
        path = Path(token)
        if not path.is_absolute(): path = parent/'obj'/path
        if path.is_relative_to(parent/'obj'): continue
        assert path.is_file(), path
        digest = native.sha(path)
        if str(path) in old['pins']: assert digest == old['pins'][str(path)], path
        pins[str(path)] = digest
    for path in (REPO/'verif/tb').iterdir():
        if path.is_file() and (path.suffix in ('.cpp','.h','.hpp') or path.name == 'Makefile'):
            if str(path) in old['pins']: assert native.sha(path) == old['pins'][str(path)], path
            pins[str(path)] = native.sha(path)
    for path in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(native.__file__),
                 Path(native.common.__file__),REPO/'verif/l1/build_mc_branch_residency_core.py',
                 REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',
                 parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium',
                 leaf/'closed.json',host_old,dep): pins[str(path)] = native.sha(path)
    assert native.stable(pins)
    flags = next(arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)',flags)
    assert len(definitions) == len(set(definitions)) == 152
    assert '--assert' in flags and '-GAXI_LINE_REPLAY=0' in flags and 'VL_J=32' in old['command']
    root.mkdir(); shutil.copytree(source,root/'candidate')
    for name in recipe.PARENTS:
        (root/'candidate'/name).write_text(recipe.transform((source/name).read_text(),name))
    assert (root/'candidate/rtl/mem/ven_l1d.sv').read_text() == (leaf/'current-u/ven_l1d.sv').read_text()
    names = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')] == names
    changes = sorted(recipe.PARENTS)
    assert sorted(n for n in names if native.sha(source/n) != native.sha(root/'candidate'/n)) == changes
    host = root/('tb_current_u_pair_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(host_old,host)
    command = native.common.relocate(old['command'],parent,root,host_old,host)
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=changes,compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        contract_change='Reject standalone/no-current-U sideband requests only in the core current-U client'))
    native.MODEL,native.CHANGES = MODEL,changes
    return native.build(root)


if __name__ == '__main__': raise SystemExit(main())
