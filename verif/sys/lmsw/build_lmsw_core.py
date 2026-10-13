"""Build a five-file LMSW derivative, preserving the frozen UV-fast profile.

The old missing-instruction witness stays immutable. No root RTL edits,
canonical golden changes, Vivado launch or inherited correctness acceptance.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_lmsw as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO/'verif/sys/smsw_memory'))
import build_core as native

MODEL = '164e17003b2ec03cd7b92cc8bbe89b576e5f440becc4204e37368e075c87e8df'
BUILDER_SHA = '9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
CHANGES = sorted('rtl/core/'+name for name in recipe.PARENTS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'witness', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    parent, witness = args.parent.resolve(strict=True), args.witness.resolve(strict=True)
    root = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert native.sha(native.__file__) == BUILDER_SHA
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime', 'ventium-ipc-parallel32.scope',
                    'MemoryMax=10G', 'MemorySwapMax=2G'], check=True, timeout=10)
    limits = dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-ipc-parallel32.scope',
        '-p', 'MemoryMax', '-p', 'MemorySwapMax', '-p', 'InvocationID'], text=True).splitlines())
    assert limits['MemoryMax'] == str(10*1024**3) and limits['MemorySwapMax'] == str(2*1024**3)
    old, built = native.load(parent/'build-started.json'), native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    assert not built['canonical_gate_passed'] and not built['standard_suite']
    missing = native.load(witness/'closed.json'); started = native.load(witness/'started.json')
    assert missing['passed'] and missing['pins_unchanged'] and not missing['repaired_rtl']
    assert len(missing['rows']) == 16
    assert all(r['qemu_exit'] == 133 and r['rtl_exit'] == (133 if r['case']['CONTROL'] else 135)
               for r in missing['rows'])
    assert native.stable(started['pins'])
    source = parent/'candidate'; files = native.common.candidate_files(source)
    assert len(files) == 195 and all(native.sha(p) == old['pins'][str(p)] for p in files)
    flags = [arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions = re.findall(r'\+define\+(\w+)', flags[0])
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_RAW_V_READ_PRIME'} <= set(definitions)
    assert not {'SYNTHESIS', 'VTM_NO_DPI'} & set(definitions)
    changes = {'rtl/core/'+name: recipe.transform((source/'rtl/core'/name).read_text(), name)
               for name in recipe.PARENTS}
    pins = dict(old['pins']); pins.update(started['pins'])
    for path in (Path(__file__), Path(recipe.__file__), Path(native.__file__), Path(native.common.__file__),
                 HERE/'test_prepare_lmsw.py', parent/'build-started.json', parent/'build-closed.json',
                 parent/'obj/tb_ventium', witness/'started.json', witness/'closed.json'):
        pins[str(path.resolve())] = native.sha(path)
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source, root/'candidate')
    for path, text in changes.items():
        (root/'candidate'/path).write_text(text)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if native.sha(source/p) != native.sha(root/'candidate'/p)] == CHANGES
    host = root/('tb_lmsw_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = native.common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/p): native.sha(root/'candidate'/p) for p in relative})
    native.save(root/'prepared.json', dict(pins=pins, command=command, host=str(host), parent=str(parent),
        parent_model=MODEL, definitions=definitions, changes=CHANGES, compiler_started=False,
        scope=limits, canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
        gameplay_ipc=None, fmax_mhz=None))
    native.MODEL = MODEL; native.CHANGES = CHANGES
    return native.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
