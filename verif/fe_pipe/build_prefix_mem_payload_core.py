"""Transfer the leaf-checked PREFIX66 cofactor to an exact private core closure."""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_prefix_mem_payload as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/sys/smsw_memory'))
spec = importlib.util.spec_from_file_location('prefix_payload_native_builder',
                                             REPO/'verif/sys/smsw_memory/build_core.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
MODEL = '1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'leaf', 'out'):
        ap.add_argument('--'+name, required=True, type=Path)
    args = ap.parse_args()
    parent, leaf = (getattr(args, key).resolve(strict=True) for key in ('parent', 'leaf'))
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == set(range(32))-{11}
    assert native.sha(native.__file__) == '9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime',
                    'ventium-ipc-parallel32.scope', 'MemoryMax=10G', 'MemorySwapMax=2G'],
                   check=True, timeout=10)
    old, built = (native.load(parent/name) for name in ('build-started.json', 'build-closed.json'))
    checked = native.load(leaf/'closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert [(r['name'], r['checks'], r['rejected_mutants']) for r in checked['profiles']] == [
        ('minimal', 17532577, 3), ('candidate', 17532577, 3)]
    assert native.stable(checked['input_pins'])
    assert len(checked['native']) == 10
    assert all(native.sha(row['log']) == row['log_sha256'] for row in checked['native'])
    source = parent/'candidate'
    files = native.common.candidate_files(source)
    assert len(files) == 195 and all(native.sha(p) == old['pins'][str(p)] for p in files)
    flags = [arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and '-GAXI_LINE_REPLAY=0' in flags[0]
    assert 'VL_J=32' in old['command']
    definitions = re.findall(r'\+define\+(\w+)', flags[0])
    assert len(set(definitions)) == 152 and definitions == checked['profiles'][1]['definitions']
    changed = recipe.transform((source/recipe.FILE).read_text(), (source/recipe.DECODER_FILE).read_text())
    assert changed == (leaf/'core_prefix66_decode.svh').read_text()
    pins = {**old['pins'], **checked['input_pins']}
    pins.update({row['log']: row['log_sha256'] for row in checked['native']})
    for path in (Path(__file__), Path(recipe.__file__), Path(native.__file__), Path(native.common.__file__),
                 leaf/'closed.json', parent/'build-started.json', parent/'build-closed.json',
                 parent/'obj/tb_ventium', leaf/'core_prefix66_decode.svh'):
        pins[str(path.resolve())] = native.sha(path)
    assert native.stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    (root/'candidate'/recipe.FILE).write_text(changed)
    names = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')] == names
    assert [n for n in names if native.sha(source/n) != native.sha(root/'candidate'/n)] == [recipe.FILE]
    host = root/('tb_prefix_payload_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = native.common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/n): native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json', dict(pins=pins, command=command, host=str(host), parent=str(parent),
        parent_model=MODEL, definitions=definitions, changes=[recipe.FILE], compiler_started=False,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
        gameplay_ipc=None, fmax_mhz=None))
    native.MODEL, native.CHANGES = MODEL, [recipe.FILE]
    code = native.build(root)
    if code == 0:
        actual = (root/'obj/Vventium_top__verFiles.dat').read_text()
        assert actual.count('-GAXI_LINE_REPLAY=0') == 1
        assert set(re.findall(r'\+define\+(\w+)', actual)) == set(definitions)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
