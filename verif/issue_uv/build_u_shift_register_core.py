#!/usr/bin/env python3
"""Build only the proven register-operand isolation on the carry-rotate model.

Preserve all 150 definitions, private harness/header ownership and source pins.
This is an unqualified timing experiment, not canonical or FPGA acceptance.
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
from prepare_u_shift_registers import transform

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
from build_mc_branch_residency_core import relocate

PARENT_MODEL = '1c9cc9ede4e2afe92d9b85333949f8a4ed5927757d6c309edfa0a370e33b7f29'
PAYLOAD = 'rtl/core/core.sv'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'leaf', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    parent, leaf = args.parent.resolve(strict=True), args.leaf.resolve(strict=True)
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == PARENT_MODEL
    before, checked = load(leaf/'started.json'), load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert [(r['name'], r['passed']) for r in checked['rows']] == [
        ('positive',True), ('bad-byte',True), ('bad-zero',True), ('bad-memory',True)]
    for row in checked['rows']:
        assert sha(leaf/(row['name']+'.log')) == row['log_sha256']
        assert sha(leaf/(row['name']+'-obj/Vtb_u_shift_registers')) == row['binary_sha256']
    assert Path(before['parent']) == parent
    replacement = transform((parent/'candidate'/PAYLOAD).read_text())
    assert replacement == (leaf/'core.sv').read_text()
    pins = {**old['pins'], **before['pins']}
    # Original failed port-collision receipts remain intact; only the complete
    # same-fixture sequential rerun can supply the missing AGI evidence.
    for label, count in [('branch',640), ('held',24), ('memory',72), ('fp',72), ('agi',12)]:
        folder = parent.parent/(label+('-r2' if label == 'agi' else '-r1'))
        receipt = folder/('result.json' if label == 'held' else 'closed.json')
        done = load(receipt)
        assert done['passed'] and not done['errors']
        assert done['inputs_unchanged' if label == 'held' else 'pins_unchanged']
        assert len(done['cases' if label == 'held' else 'measurements']) == count*(2 if label == 'held' else 4)
        pins[str(receipt)] = sha(receipt)
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defs = re.findall(r'\+define\+(\w+)', flags)
    assert len(defs) == len(set(defs)) == 150 and '--assert' in flags and 'VL_J=32' in old['command']
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
        'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_L1_AXI'} <= set(defs)
    assert all(sha(p) == h for p,h in pins.items())
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    (root/'candidate'/PAYLOAD).write_text(replacement)
    files = sorted(str(p.relative_to(parent/'candidate')) for p in (parent/'candidate').rglob('*') if p.is_file())
    assert sorted(str(p.relative_to(root/'candidate')) for p in (root/'candidate').rglob('*') if p.is_file()) == files
    assert [p for p in files if sha(root/'candidate'/p) != sha(parent/'candidate'/p)] == [PAYLOAD]
    oldhost = Path(old['host'])
    host = root/('tb_u_shift_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost, host)
    command = relocate(old['command'], parent, root, oldhost, host)
    for p in (Path(__file__).resolve(), Path(__file__).with_name('prepare_u_shift_registers.py'),
              REPO/'verif/l1/build_mc_branch_residency_core.py',
              parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium',
              leaf/'started.json', leaf/'closed.json', host):
        pins[str(p)] = sha(p)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in files})
    save(root/'build-started.json', dict(command=command, pins=pins, host=str(host),
        parent_model=PARENT_MODEL, changes=[PAYLOAD], invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), canonical_gate_passed=False, gameplay_ipc=None))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, gameplay_ipc=None, standard_suite=False)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            child = subprocess.run(command, env={**os.environ, 'CCACHE_DISABLE':'1'}, stdout=stream,
                stderr=subprocess.STDOUT, pass_fds=(9,), timeout=600)
        result['native_exit'] = child.returncode
        assert child.returncode == 0
        obj = root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p) == h for p,h in pins.items()), seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
