#!/usr/bin/env python3
"""Integrate the qualified read-only I-fill cofactor into the exact timing parent.

Preserve the 195-source/150-define UV-fast profile. This is a private derivative;
compilation and leaf equivalence are not canonical or standard-suite acceptance.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

import build_pair_now_core as parent_builder
import prepare_ic_fill_read_ack as recipe
from run_ic_fill_read_ack_leaf import MODEL

common = parent_builder.common
sha, load, save, stable = common.sha, common.load, common.save, common.stable
REPO = Path(__file__).resolve().parents[2]
TARGET = 'rtl/core/core.sv'


def check_leaf(proof):
    assert proof['passed'] and proof['pins_unchanged'] and not proof['errors']
    rows = proof['rows']
    assert [(r['profile'], r['mutant']) for r in rows] == [
        ('early', 0), ('early', 1), ('early', 2), ('early', 3), ('early', 4), ('fallback', 0)]
    for row in rows:
        assert row['build_exit'] == 0
        if row['mutant']:
            assert row['native_exit'] != 0
        else:
            assert row['native_exit'] == 0
            assert row['counts']['samples'] == 50_331_648
            assert all(row['counts'][key] > 0 for key in (
                'pf', 'word0', 'completed', 'fragment', 'noack', 'flush', 'held', 'diverted', 'bypass'))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'leaf', 'out'):
        ap.add_argument('--'+name, required=True, type=Path)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, leaf = args.parent.resolve(strict=True), args.leaf.resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    assert re.fullmatch('[0-9a-f]{32}', os.environ['INVOCATION_ID'])
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    old, built, proof = load(parent/'build-started.json'), load(parent/'build-closed.json'), load(leaf/'closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    check_leaf(proof)
    pins = dict(old['pins'], **proof['pins'])
    for row in proof['rows']:
        log = leaf/(row['profile']+'-'+str(row['mutant'])+'.log')
        binary = leaf/row['profile']/'Vtb_ic_fill_read_ack'
        assert sha(log) == row['log_sha256'] and sha(binary) == row['binary_sha256']
        assert ('IC-FILL-EQUIV' if row['mutant'] else 'IC-FILL-READ-ACK-OK') in log.read_text()
        pins[str(log)], pins[str(binary)] = sha(log), sha(binary)
    assert stable(pins)
    files = common.candidate_files(parent/'candidate')
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    changed = recipe.transform((parent/'candidate'/TARGET).read_text())
    assert changed == (leaf/'core.sv').read_text()
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defs = re.findall(r'\+define\+(\w+)', flags)
    assert len(defs) == len(set(defs)) == 150 and '--assert' in flags and 'VL_J=32' in old['command']
    assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT', 'VEN_FP_LOAD_EARLY_CMD', 'VEN_IC_BRAM',
            'VEN_P54_DUAL_LOAD_PAIR', 'VEN_P54_DUAL_BYTE_LOAD_PAIR'} <= set(defs)
    assert not {'SYNTHESIS', 'VTM_NO_DPI'} & set(defs)
    for p in (Path(__file__), Path(recipe.__file__), Path(common.__file__), Path(parent_builder.__file__),
              REPO/'verif/l1/run_ic_fill_read_ack_leaf.py',
              parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium',
              leaf/'closed.json', leaf/'started.json'):
        pins[str(p)] = sha(p)
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    (root/'candidate'/TARGET).write_text(changed)
    relative = [str(p.relative_to(parent/'candidate')) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(parent/'candidate'/p) != sha(root/'candidate'/p)] == [TARGET]
    host = root/('tb_ic_fill_read_ack_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in relative})
    prepared = dict(command=command, pins=pins, host=str(host), definitions=defs,
        parent=str(parent), parent_model=MODEL, changes=[TARGET], leaf=str(leaf),
        compiler_started=False, canonical_gate_passed=False, gameplay_ipc=None)
    save(root/'prepared.json', prepared)
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(prepared, compiler_started=True,
        invocation=os.environ['INVOCATION_ID'], affinity=sorted(os.sched_getaffinity(0))))
    start = time.monotonic()
    result = dict(passed=False, errors=[], standard_suite=False, hardware_acceptance=False,
                  canonical_gate_passed=False, gameplay_ipc=None)
    try:
        with (root/'build.log').open('x') as stream:
            child = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                env=dict(os.environ, CCACHE_DISABLE='1'), pass_fds=(9,), timeout=660)
        result['native_exit'] = child.returncode
        assert child.returncode == 0
        obj = root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
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
    print(result, flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
