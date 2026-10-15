"""Build the no-request DECODE payload cofactor without changing its authority.

Use the strict-MF core as parent, preserve its complete source/define closure,
and require the source-linked selector miter plus all-address local proof.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_decode_bus_payload as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
from build_current_u_pair_core import native

MODEL = '08be10a26af0eb36e9393837bebca22b1eed186ad3020179f438143cb4fa8605'


def check_leaf(leaf):
    before, checked = [native.load(leaf/n) for n in ('started.json', 'closed.json')]
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert not checked['whole_core']
    assert [r['mode'] for r in checked['rows']] == [
        'positive', 'unconditional', 'drop-ordinary', 'wrong-address', 'late-control']
    for row in checked['rows']:
        result = row['results']
        positive = row['mode'] == 'positive'
        assert all(r['actual_wait'] for r in result.values())
        assert result['compile']['native_exit'] == result['proof']['native_exit'] == 0
        assert result['native']['native_exit'] == (0 if positive else 1)
        assert result['proof']['answer'] == ('unsat' if positive else 'sat')
    assert checked['rows'][0]['results']['native']['coverage']['checks'] == 65536
    assert native.stable(before['pins']) and native.stable(checked['artifacts'])
    return dict(before['pins']) | checked['artifacts']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'leaf', 'out'): ap.add_argument('--'+name, type=Path, required=True)
    a = ap.parse_args()
    parent, leaf, root = a.parent.resolve(strict=True), a.leaf.resolve(strict=True), a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3 and os.sched_getaffinity(0) == set(range(32))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime', 'ventium-ipc-parallel32.scope',
                    'MemoryMax=10G', 'MemorySwapMax=2G'], check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    old, built = [native.load(parent/n) for n in ('build-started.json', 'build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    pins = check_leaf(leaf)
    source = parent/'candidate'
    files = native.common.candidate_files(source)
    assert len(files) == 195
    for p in files:
        assert native.sha(p) == old['pins'][str(p)]
        pins[str(p)] = native.sha(p)
    replacement = recipe.transform((source/recipe.FILE).read_text())
    assert replacement == (leaf/'core_bus_driver.svh').read_text()
    host_old = Path(old['host'])
    dep = parent/'obj'/(host_old.stem+'.d')
    for token in dep.read_text().replace('\\\n', ' ').split()[1:]:
        p = Path(token)
        if not p.is_absolute(): p = parent/'obj'/p
        if p.is_relative_to(parent/'obj'): continue
        assert p.is_file()
        if str(p) in old['pins']: assert native.sha(p) == old['pins'][str(p)]
        pins[str(p)] = native.sha(p)
    for p in (REPO/'verif/tb').iterdir():
        if p.is_file() and (p.suffix in ('.cpp', '.h', '.hpp') or p.name == 'Makefile'):
            if str(p) in old['pins']: assert native.sha(p) == old['pins'][str(p)]
            pins[str(p)] = native.sha(p)
    for p in (Path(__file__), Path(recipe.__file__), Path(native.__file__), Path(native.common.__file__),
              REPO/'verif/l1/build_mc_branch_residency_core.py', REPO/'tools/build_scope.sh',
              REPO/'tools/verilator_serial.sh', parent/'build-started.json', parent/'build-closed.json',
              parent/'obj/tb_ventium', host_old, dep, leaf/'closed.json'):
        pins[str(p.resolve())] = native.sha(p)
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)', flags)
    assert len(definitions) == len(set(definitions)) == 153 and definitions == old['definitions']
    assert 'VEN_X87_MF_STRICT' in definitions
    assert '--assert' in flags and '-GAXI_LINE_REPLAY=0' in flags and 'VL_J=32' in old['command']
    assert native.stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    (root/'candidate'/recipe.FILE).write_text(replacement)
    names = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')] == names
    assert sorted(n for n in names if native.sha(source/n) != native.sha(root/'candidate'/n)) == [recipe.FILE]
    host = root/('tb_decode_bus_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(host_old, host)
    command = native.common.relocate(old['command'], parent, root, host_old, host)
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/n): native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json', dict(pins=pins, command=command, host=str(host), parent=str(parent),
        parent_model=MODEL, definitions=definitions, changes=[recipe.FILE], compiler_started=False,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None,
        contract_change='Only no-request DECODE address payload; MMU/fault/request authority unchanged'))
    native.MODEL, native.CHANGES = MODEL, [recipe.FILE]
    return native.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
