#!/usr/bin/env python3
"""Build a one-header bus-cancellation derivative of the measured shift core.

No timing result or whole-system equivalence follows from the leaf proof.
Use the shared guarded compiler scope and a private harness/generated header.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

from prepare_bus_cancel_payload import transform

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
from build_mc_branch_residency_core import relocate

PARENT_MODEL = 'ce54833f54ad48e002ad001b0eb7223ac81e910f5aca8400a04634babf948fa0'
PARENT_AUDIT = 'd59eb7c496caeb74fac5880d60fbcb067e2db7283f77bd38ac8cd181c172c211'
PAYLOAD = 'rtl/core/core_bus_driver.svh'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def stable(pins):
    return all(sha(path) == digest for path, digest in pins.items())


def candidate_files(source):
    files = sorted(path for path in source.rglob('*') if path.is_file())
    assert files and not any(path.is_symlink() for path in source.rglob('*'))
    return files


def prepare(args, root):
    parent, leaf = args.parent.resolve(strict=True), args.leaf.resolve(strict=True)
    assert not root.exists()
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    audit_path = parent.parent/'core-audit.json'
    assert sha(audit_path) == PARENT_AUDIT
    audit = load(audit_path)
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == audit['model_sha256'] == sha(parent/'obj/tb_ventium') == PARENT_MODEL
    assert audit['audit_complete'] and audit['directed_regressions_passed']
    assert not audit['canonical_gate_passed']
    checked = load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert not checked['whole_core'] and checked['translation_abstracted']
    expected = []
    for name, status in (('positive', 0), ('bad-permission', 1), ('bad-a20', 1), ('bad-pre', 1)):
        expected.extend(((name+'-proof', 0), (name+'-build', 0), (name, status)))
    assert [(row['label'], row['native_exit']) for row in checked['rows']] == expected
    assert 'BUS-CANCEL-PAYLOAD-OK checked=532480 ' in (leaf/'positive.log').read_text()
    pins = dict(checked['pins'])
    for row in checked['rows']:
        path = leaf/(row['label']+'.log')
        assert sha(path) == row['log_sha256']
        pins[str(path)] = sha(path)
    assert stable(pins)
    source = parent/'candidate'
    changed = transform((source/PAYLOAD).read_text())
    assert changed == (leaf/'candidate-header.svh').read_text()
    files = candidate_files(source)
    for path in files:
        assert sha(path) == old['pins'][str(path)]
        pins[str(path)] = old['pins'][str(path)]
    flags = next(arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES='))
    defs = re.findall(r'\+define\+(\w+)', flags)
    assert len(defs) == len(set(defs)) == 150 and '--assert' in flags
    assert 'VL_J=32' in old['command']
    assert {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_L1_AXI'} <= set(defs)
    oldhost = Path(old['host'])
    cpp = next(arg for arg in old['command'] if arg.startswith('CPP_SRCS=')).split('=', 1)[1].split()
    dependencies = {Path(path) for path in cpp}
    for source_file in cpp:
        dep = parent/'obj'/(Path(source_file).stem+'.d')
        assert dep.is_file()
        dependencies.add(dep)
        for name in dep.read_text().replace('\\\n', ' ').split()[1:]:
            path = Path(name)
            if path.is_absolute():
                dependencies.add(path)
    dependencies.update((REPO/'verif/tb/Makefile', REPO/'verif/tb/model_input_snapshot.mk',
        REPO/'tools/gen_model_input_snapshot.py', REPO/'tools/build_scope.sh',
        REPO/'tools/verilator_serial.sh', REPO/'verif/l1/build_mc_branch_residency_core.py',
        Path(__file__).resolve(), Path(__file__).with_name('prepare_bus_cancel_payload.py'),
        parent/'build-started.json', parent/'build-closed.json', audit_path,
        leaf/'started.json', leaf/'closed.json'))
    pins.update({str(path): sha(path) for path in dependencies})
    assert stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    (root/'candidate'/PAYLOAD).write_text(changed)
    relative = [str(path.relative_to(source)) for path in files]
    assert [str(path.relative_to(root/'candidate')) for path in candidate_files(root/'candidate')] == relative
    assert [path for path in relative if sha(source/path) != sha(root/'candidate'/path)] == [PAYLOAD]
    host = root/('tb_bus_cancel_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost, host)
    command = relocate(old['command'], parent, root, oldhost, host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/path): sha(root/'candidate'/path) for path in relative})
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, host=str(host),
        definitions=defs, parent_model=PARENT_MODEL, parent=str(parent), changes=[PAYLOAD],
        compiler_started=False, canonical_gate_passed=False, gameplay_ipc=None))
    print(json.dumps(dict(prepared=str(root), files=len(relative), pins=len(pins), compiler_started=False)), flush=True)


def build(root):
    before = load(root/'prepared.json')
    assert not (root/'build-started.json').exists()
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert stable(before['pins'])
    parent = Path(before['parent'])
    original = load(parent/'build-started.json')
    assert before['parent_model'] == PARENT_MODEL and before['changes'] == [PAYLOAD]
    assert before['command'] == relocate(original['command'], parent, root,
                                         Path(original['host']), Path(before['host']))
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(before, compiler_started=True,
        preparation_sha256=sha(root/'prepared.json'), invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, gameplay_ipc=None,
                  standard_suite=False, hardware_acceptance=False)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native = subprocess.run(before['command'], env={**os.environ, 'CCACHE_DISABLE': '1'},
                stdout=stream, stderr=subprocess.STDOUT, pass_fds=(9,), timeout=660)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj, host = root/'obj', Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(name) for name in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
                   if Path(name).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=stable(before['pins']), seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'build'))
    parser.add_argument('--out', type=Path, required=True)
    for name in ('parent', 'leaf'):
        parser.add_argument('--'+name, type=Path)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch)
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.leaf
        prepare(args, root)
        return 0
    return build(root)


if __name__ == '__main__':
    raise SystemExit(main())
