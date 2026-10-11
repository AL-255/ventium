#!/usr/bin/env python3
"""Prepare/build a private descriptor-width derivative, never alongside Vivado."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

import build_bus_cancel_core as common
import prepare_descriptor_read_extent as patch

REPO = Path(__file__).resolve().parents[2]
MODEL = 'e4ed9c0c01f53b96fc7da451695feea84b9eabf0891589107711300f042f65c8'
REPRO = '99c156ec5eda4f8506b7b066dfe29512563f5560ded58b8abe5ff1700f297429'
CHANGES = ['rtl/core/core.sv', 'rtl/core/core_bus_driver.svh']
sha, save, load, stable = common.sha, common.save, common.load, common.stable


def prepare(parent, proof, root):
    assert not root.exists()
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    assert sha(proof/'closed.json') == REPRO
    witness = load(proof/'closed.json')
    assert witness['investigation_completed'] and witness['pins_unchanged']
    assert not witness['candidate_fixed'] and stable(witness['pins'])
    assert len(witness['rows']) == 12
    assert sum(m['differential_exit'] != 0 for r in witness['rows'] for m in r['measurements']) == 32
    source = parent/'candidate'
    files = common.candidate_files(source)
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    corrected = patch.transform(*((source/name).read_text() for name in CHANGES))
    flags = next(arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)', flags)
    assert len(definitions) == len(set(definitions)) == 150 and '--assert' in flags
    assert 'VL_J=32' in old['command']
    assert {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_L1_AXI'} <= set(definitions)
    cpp = next(arg for arg in old['command'] if arg.startswith('CPP_SRCS=')).split('=', 1)[1].split()
    dependencies = {Path(p) for p in cpp}
    for name in cpp:
        dep = parent/'obj'/(Path(name).stem+'.d')
        dependencies.add(dep)
        dependencies.update(Path(p) for p in dep.read_text().replace('\\\n', ' ').split()[1:]
                            if Path(p).is_absolute())
    dependencies.update((Path(__file__).resolve(), Path(patch.__file__), Path(common.__file__),
        REPO/'verif/tb/Makefile', REPO/'verif/tb/model_input_snapshot.mk',
        REPO/'tools/gen_model_input_snapshot.py', REPO/'tools/build_scope.sh',
        REPO/'tools/verilator_serial.sh', REPO/'verif/l1/build_mc_branch_residency_core.py',
        parent/'build-started.json', parent/'build-closed.json', proof/'closed.json'))
    pins = dict(witness['pins'])
    pins.update({str(p): sha(p) for p in [*files, *dependencies]})
    assert stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    for name, text in zip(CHANGES, corrected):
        (root/'candidate'/name).write_text(text)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(source/p) != sha(root/'candidate'/p)] == CHANGES
    host = root/('tb_descriptor_extent_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(old['host'], host)
    command = common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in relative})
    save(root/'prepared.json', dict(command=command, pins=pins, parent=str(parent),
        host=str(host), definitions=definitions, parent_model=MODEL, changes=CHANGES,
        compiler_started=False, canonical_gate_passed=False, gameplay_ipc=None))
    print(json.dumps(dict(prepared=str(root), files=len(relative), changes=CHANGES)), flush=True)


def build(root):
    before = load(root/'prepared.json')
    assert not (root/'build-started.json').exists() and os.environ.get('INVOCATION_ID')
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert stable(before['pins']) and before['parent_model'] == MODEL and before['changes'] == CHANGES
    parent = Path(before['parent'])
    old = load(parent/'build-started.json')
    assert before['command'] == common.relocate(old['command'], parent, root,
                                               Path(old['host']), Path(before['host']))
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(before, compiler_started=True,
        preparation_sha256=sha(root/'prepared.json'), invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, gameplay_ipc=None,
                  standard_suite=False, hardware_acceptance=False)
    start = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            child = subprocess.run(before['command'], env={**os.environ, 'CCACHE_DISABLE': '1'},
                stdout=stream, stderr=subprocess.STDOUT, pass_fds=(9,), timeout=660)
        result['native_exit'] = child.returncode
        assert child.returncode == 0
        obj, host = root/'obj', Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(p) for p in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
                   if Path(p).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=stable(before['pins']), seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'build'))
    parser.add_argument('--parent', type=Path)
    parser.add_argument('--proof', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.proof
        prepare(args.parent.resolve(strict=True), args.proof.resolve(strict=True), root)
        return 0
    return build(root)


if __name__ == '__main__':
    raise SystemExit(main())
