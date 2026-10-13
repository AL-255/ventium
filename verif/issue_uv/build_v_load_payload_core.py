"""Prepare/build the checked V-load selector on the current-tag core.

Preparation copies private sources only. Native compilation retains the shared
32-job builder, unique host/header check and no-concurrent-Vivado admission.
This does not qualify the canonical gate, standard suite or physical hardware.
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

import prepare_v_load_payload as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO/'verif/sys/smsw_memory'))
spec = importlib.util.spec_from_file_location('v_load_native_builder', REPO/'verif/sys/smsw_memory/build_core.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
MODEL = '737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'
LEAF_AUDIT = '55826128d28ff75f915f669a74f6f07c34b70d8b6a07f8a61ad9a82c5b5f10fa'
PARENT_AUDIT = '1dd4b7175a442465dac426b026255b283acfd9d985bda1d9e7893b5872cddf28'
CHANGES = sorted(recipe.PARENTS)


def profile(command):
    flags = [arg for arg in command if arg.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and '-GAXI_LINE_REPLAY=0' in flags[0]
    assert 'VL_J=32' in command
    definitions = re.findall(r'\+define\+(\w+)', flags[0])
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_RAW_V_READ_PRIME',
            'VEN_P54_DUAL_LOAD_PAIR', 'VEN_P54_DUAL_BYTE_LOAD_PAIR',
            'VEN_AO486_SINGLE_FILL'} <= set(definitions)
    assert not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_P54_DUAL_LOAD_PRIME'} & set(definitions)
    return definitions


def prepare(root, scratch):
    assert not root.exists()
    evidence = scratch/'ventium-data-size.v2HaTO2X'
    parent, leaf = evidence/'window-current-core-r1', evidence/'v-load-payload-leaf-r2'
    old, built = native.load(parent/'build-started.json'), native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    audit_path = evidence/'window-current-regression-audit.json'
    assert native.sha(audit_path) == PARENT_AUDIT
    audit = native.load(audit_path)
    assert audit['audit_passed'] and audit['functional_passes'] == 108
    assert audit['cycle_traces_unchanged'] == 20 and not audit['canonical_gate_passed']
    assert native.sha(leaf/'audit.json') == LEAF_AUDIT
    checked = native.load(leaf/'audit.json')
    assert checked['passed'] and checked['source_transformation_exact']
    assert (checked['profiles'], checked['comparisons'], checked['negative_variants'],
            checked['actual_native_commands']) == (8, 55296, 4, 26)
    assert not checked['sequential_core'] and not checked['physical_board']
    leaf_start = native.load(leaf/'started.json')
    props = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', leaf_start['unit'], '-pSubState', '-pMainPID',
        '-pExecMainStatus', '-pInvocationID'], text=True).splitlines())
    assert props == dict(SubState='exited', MainPID='0', ExecMainStatus='0',
                         InvocationID=leaf_start['invocation'])
    source = parent/'candidate'
    files = native.common.candidate_files(source)
    assert len(files) == 195 and all(native.sha(p) == old['pins'][str(p)] for p in files)
    definitions = profile(old['command'])
    changes = recipe.transform({p: (source/p).read_text() for p in recipe.PARENTS})
    assert all(text == (leaf/'proposal'/p).read_text() for p, text in changes.items())
    pins = {**old['pins'], **leaf_start['pins'], **checked['artifacts']}
    for p in (Path(__file__), Path(recipe.__file__), Path(native.__file__), Path(native.common.__file__),
              HERE/'test_build_v_load_payload_core.py', parent/'obj/tb_ventium',
              parent/'build-started.json', parent/'build-closed.json', audit_path,
              leaf/'started.json', leaf/'closed.json', leaf/'audit.json'):
        pins[str(p.resolve())] = native.sha(p)
    assert native.stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    for name, text in changes.items():
        (root/'candidate'/name).write_text(text)
    names = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')] == names
    assert sorted(n for n in names if native.sha(source/n) != native.sha(root/'candidate'/n)) == CHANGES
    host = root/('tb_v_load_payload_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = native.common.relocate(old['command'], parent, root, Path(old['host']), host)
    assert profile(command) == definitions
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/n): native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json', dict(pins=pins, command=command, host=str(host), parent=str(parent),
        parent_model=MODEL, definitions=definitions, changes=CHANGES, compiler_started=False,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
        gameplay_ipc=None, fmax_mhz=None))
    print('Prepared source-matched V-load payload core; no native build or FPGA launch.')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare', 'build'))
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert native.sha(native.__file__) == '9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    if args.action == 'prepare':
        prepare(root, scratch)
        return 0
    assert os.sched_getaffinity(0) == set(range(8, 16))
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime', 'ventium-ipc-parallel32.scope',
                    'MemoryMax=10G', 'MemorySwapMax=2G'], check=True, timeout=10)
    native.MODEL, native.CHANGES = MODEL, CHANGES
    return native.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
