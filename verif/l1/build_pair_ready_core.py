#!/usr/bin/env python3
"""Build a frozen UV-fast core with only the proven L1 readiness delta."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import prepare_pair_ready_cofactor as patch

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/issue_uv'))
import build_bus_cancel_core as common

MODEL = '87035ad6ae27896b38274a908b5fcb92e37f6c5c1b1a66b8b3f122f491ed6ddf'
TARGET = 'rtl/mem/ven_l1d.sv'
sha, save, load, stable = common.sha, common.save, common.load, common.stable


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('parent', 'leaf', 'out'):
        ap.add_argument('--'+key, type=Path, required=True)
    args = ap.parse_args()
    parent, leaf, root = args.parent.resolve(strict=True), args.leaf.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ.get('INVOCATION_ID')
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    proof = load(leaf/'closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    assert proof['passed'] and proof['pins_unchanged'] and proof['proof_exit'] == 0 and not proof['errors']
    assert len(proof['rows']) == 7 and sum(not row['mutant'] for row in proof['rows']) == 6
    pins = dict(proof['pins'])
    for row in proof['rows']:
        runlog = leaf/row['label']/'run.log'
        assert sha(runlog) == row['log_sha256']
        pins[str(runlog)] = sha(runlog)
    assert stable(pins)
    files = common.candidate_files(parent/'candidate')
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defs = re.findall(r'\+define\+(\w+)', flags)
    assert len(defs) == len(set(defs)) == 150 and '--assert' in flags
    assert 'VL_J=32' in old['command'] and not {'SYNTHESIS','VTM_NO_DPI'} & set(defs)
    assert {'VEN_L1_AXI','VEN_SYS_FASTPATH_RELOC','VEN_FE_PIPE',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT'} <= set(defs)
    changed = patch.transform((parent/'candidate'/TARGET).read_text())
    assert changed == (leaf/'ven_l1d.sv').read_text()
    # Preserve all predecessor build dependencies, not only the changed RTL.
    pins.update(old['pins'])
    for p in (Path(__file__), Path(patch.__file__), leaf/'closed.json',
              parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    (root/'candidate'/TARGET).write_text(changed)
    relative = [str(p.relative_to(parent/'candidate')) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(parent/'candidate'/p) != sha(root/'candidate'/p)] == [TARGET]
    host = root/('tb_pair_ready_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(old['host'], host)
    command = common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    prepared = dict(command=command, pins=pins, host=str(host), parent=str(parent),
        parent_model=MODEL, changes=[TARGET], definitions=defs, compiler_started=False,
        canonical_gate_passed=False, gameplay_ipc=None)
    save(root/'prepared.json', prepared)
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(prepared, compiler_started=True,
        invocation=os.environ['INVOCATION_ID'], affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], standard_suite=False, hardware_acceptance=False,
                  canonical_gate_passed=False, gameplay_ipc=None)
    start = time.monotonic()
    try:
        with (root/'build.log').open('x') as f:
            child = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT,
                env=dict(os.environ, CCACHE_DISABLE='1'), pass_fds=(9,), timeout=660)
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
    result.update(pins_unchanged=stable(pins), seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
