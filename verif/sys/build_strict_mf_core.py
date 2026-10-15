"""Enable the existing architectural waiting-x87 policy in a private model.

The source closure is unchanged; add only VEN_X87_MF_STRICT. Preparation is
read/copy-only and may run during synthesis. Compilation requires the ordinary
exclusive guarded-32 launcher and refuses a live Vivado family.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
from build_current_u_pair_core import native

MODEL = '6deb3e92ae302d2166c18d239711754c049f1f775f2518a2f5b576108eb8b16d'
FLAG = 'VEN_X87_MF_STRICT'


def enable(command):
    result = list(command)
    slots = [i for i, arg in enumerate(result) if arg.startswith('VL_EXTRA_DEFINES=')]
    assert len(slots) == 1
    i = slots[0]
    definitions = re.findall(r'\+define\+(\w+)', result[i])
    assert len(definitions) == len(set(definitions)) == 152 and FLAG not in definitions
    assert '--assert' in result[i] and '-GAXI_LINE_REPLAY=0' in result[i]
    assert {'VEN_FP_SHARED_DIRECT', 'VEN_FP_ASYNC', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_FE_PIPE', 'VEN_L1_AXI', 'VEN_AO486_SINGLE_FILL'} <= set(definitions)
    result[i] += ' +define+'+FLAG
    return result, definitions+[FLAG]


def prepare(parent, proof, root):
    old, built = [native.load(parent/n) for n in ('build-started.json', 'build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    closed = native.load(proof/'closed.json')
    assert closed['completed'] and not closed['candidate_passed'] and not closed['errors']
    assert closed['pins_unchanged'] and len(closed['rows']) == 216
    assert closed['summary']['branch'] == dict(fwait=dict(passed=24, total=24),
        fnop=dict(passed=24, total=24), fld1=dict(passed=0, total=24))
    pins = native.load(proof/'started.json')['pins']
    assert native.stable(pins)
    source = parent/'candidate'
    files = native.common.candidate_files(source)
    assert len(files) == 195 and all(native.sha(p) == old['pins'][str(p)] for p in files)
    host_old = Path(old['host'])
    dep = parent/'obj'/(host_old.stem+'.d')
    for token in dep.read_text().replace('\\\n', ' ').split()[1:]:
        p = Path(token)
        if not p.is_absolute(): p = parent/'obj'/p
        if p.is_relative_to(parent/'obj'): continue
        assert p.is_file()
        if str(p) in old['pins']: assert native.sha(p) == old['pins'][str(p)]
        pins[str(p)] = native.sha(p)
    pins.update({str(p): native.sha(p) for p in files})
    for p in (Path(__file__), Path(native.__file__), Path(native.common.__file__),
              REPO/'verif/l1/build_mc_branch_residency_core.py',
              REPO/'tools/build_scope.sh', REPO/'tools/verilator_serial.sh',
              parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium',
              proof/'started.json', proof/'closed.json', host_old, dep):
        pins[str(p.resolve())] = native.sha(p)
    assert native.stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    names = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')] == names
    assert all(native.sha(source/n) == native.sha(root/'candidate'/n) for n in names)
    host = root/('tb_strict_mf_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(host_old, host)
    original = native.common.relocate(old['command'], parent, root, host_old, host)
    command, definitions = enable(original)
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/n): native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json', dict(pins=pins, command=command, host=str(host),
        parent=str(parent), parent_model=MODEL, definitions=definitions, changes=[],
        added_define=FLAG, compiler_started=False, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None))


def build(root):
    before = native.load(root/'prepared.json')
    assert not (root/'build-started.json').exists() and native.stable(before['pins'])
    assert os.sched_getaffinity(0) == set(range(32))
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime', 'ventium-ipc-parallel32.scope',
                    'MemoryMax=10G', 'MemorySwapMax=2G'], check=True)
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    old = native.load(Path(before['parent'])/'build-started.json')
    expected, definitions = enable(native.common.relocate(old['command'], Path(before['parent']),
        root, Path(old['host']), Path(before['host'])))
    assert before['command'] == expected and before['definitions'] == definitions
    assert before['parent_model'] == MODEL and before['changes'] == [] and before['added_define'] == FLAG
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    native.save(root/'build-started.json', dict(before, compiler_started=True,
        invocation=os.environ['INVOCATION_ID'], preparation_sha256=native.sha(root/'prepared.json'),
        affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, standard_suite=False,
                  hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            child = subprocess.run(expected, env=dict(os.environ, CCACHE_DISABLE='1'),
                stdout=stream, stderr=subprocess.STDOUT, pass_fds=(9,), timeout=660)
        result['native_exit'] = child.returncode
        assert child.returncode == 0
        obj, host = root/'obj', Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(n) for n in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
                   if Path(n).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=native.sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin, pins_unchanged=native.stable(before['pins']))
    result['passed'] &= result['pins_unchanged']
    native.save(root/'build-closed.json', result)
    print(result, flush=True)
    return int(not result['passed'])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare', 'build'))
    ap.add_argument('--parent', type=Path)
    ap.add_argument('--proof', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    scratch, root = Path('/home/yukidama/external/tmp').resolve(strict=True), a.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if a.action == 'prepare':
        assert a.parent and a.proof and not root.exists()
        prepare(a.parent.resolve(strict=True), a.proof.resolve(strict=True), root)
        print('STRICT-MF-PREPARED: one define added, no source edits; compiler not launched.', flush=True)
        return 0
    return build(root)


if __name__ == '__main__':
    raise SystemExit(main())
