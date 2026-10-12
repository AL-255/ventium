#!/usr/bin/env python3
"""Build the same-line ACK derivative only after actual cache tests close.

Preserve all 150 UV-fast definitions, the predecessor's private harness and
195-source closure. No symbolic-only result admits this whole-core build.
Run under the shared guarded-32 scope after Vivado has actually exited.
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

import prepare_pair_now_ack_cut as patch

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/issue_uv'))
import build_bus_cancel_core as common

MODELS = {
    '64e997d504e7f73fcd1f6b5e524a68cb6f901bf88f44b97fb613dfa1adf9d055': 'readiness',
    'eefa9d57c41c5eb5154d0319fb2e82240f90469b7ce119ae0abe36d6aada9702': 'mc-pair-srt',
}
TARGET = 'rtl/mem/ven_l1d.sv'
sha, save, load, stable = common.sha, common.save, common.load, common.stable


def known_model(recorded, actual):
    assert recorded == actual and actual in MODELS, 'unknown or changed parent model'
    return actual


def check_rows(rows):
    """Require native positive transactions and a natively rejected mutant."""
    assert [(r['label'], r['mutant']) for r in rows] == [
        ('ff-primary', False), ('lut-primary-shadow', False), ('wrong-unowned', True)]
    for row in rows:
        assert row['build_exit'] == 0
        if row['mutant']:
            assert row['native_exit'] != 0
        else:
            assert row['native_exit'] == 0
            assert row['checks'] >= 12 and row['returns'] >= 4 and row['held'] == 3


def cache_pins(cache):
    proof = load(cache/'closed.json')
    assert proof['passed'] and proof['pins_unchanged'] and not proof['errors']
    check_rows(proof['rows'])
    pins = dict(proof['pins'])
    for row in proof['rows']:
        folder = cache/row['label']
        for relative, key in (('run.log', 'log_sha256'), ('build.log', 'build_log_sha256'),
                              ('obj/Vtb_l1d_pair_store', 'binary_sha256')):
            path = folder/relative
            assert sha(path) == row[key]
            pins[str(path)] = row[key]
        log = (folder/'run.log').read_text()
        if row['mutant']:
            assert 'PAIR-NOW' in log or 'MISMATCH' in log
        else:
            assert 'L1D-PAIR-STORE-GATE-OK' in log
            assert not re.search(r'FAIL|%Error|%Fatal|MISMATCH', log)
            match = re.search(r'PAIR-NOW-CACHE-CHECKS checks=(\d+) returns=(\d+) held=(\d+)', log)
            assert match and tuple(map(int, match.groups())) == (
                row['checks'], row['returns'], row['held'])
    pins[str(cache/'closed.json')] = sha(cache/'closed.json')
    assert stable(pins)
    return pins


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('parent', 'leaf', 'cache', 'out'):
        ap.add_argument('--'+key, type=Path, required=True)
    args = ap.parse_args()
    parent, leaf, cache = [getattr(args, name).resolve(strict=True)
                           for name in ('parent', 'leaf', 'cache')]
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    model = known_model(built['binary_sha256'], sha(parent/'obj/tb_ventium'))
    pins = cache_pins(cache)
    # The cache checker pins the source-extracted proof and its actual native
    # source/binary/log sets. Recheck that it used this exact private candidate.
    assert str(leaf/'closed.json') in pins and str(leaf/'ven_l1d.sv') in pins
    assert stable(old['pins'])
    files = common.candidate_files(parent/'candidate')
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defs = re.findall(r'\+define\+(\w+)', flags)
    assert len(defs) == len(set(defs)) == 150 and '--assert' in flags
    assert 'VL_J=32' in old['command'] and not {'SYNTHESIS', 'VTM_NO_DPI'} & set(defs)
    assert {'VEN_L1_AXI', 'VEN_SYS_FASTPATH_RELOC', 'VEN_FE_PIPE',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT',
            'VEN_P54_DUAL_LOAD_PAIR', 'VEN_P54_DUAL_BYTE_LOAD_PAIR'} <= set(defs)
    changed = patch.transform((parent/'candidate'/TARGET).read_text())
    assert changed == (leaf/'ven_l1d.sv').read_text()
    assert changed == (cache/'ff-primary/ven_l1d.sv').read_text()
    assert changed == (cache/'lut-primary-shadow/ven_l1d.sv').read_text()
    pins.update(old['pins'])
    for path in (Path(__file__), Path(patch.__file__), Path(common.__file__),
                 REPO/'verif/l1/build_mc_branch_residency_core.py',
                 parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    (root/'candidate'/TARGET).write_text(changed)
    relative = [str(p.relative_to(parent/'candidate')) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(parent/'candidate'/p) != sha(root/'candidate'/p)] == [TARGET]
    host = root/('tb_pair_now_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in relative})
    prepared = dict(command=command, pins=pins, host=str(host), parent=str(parent),
        parent_model=model, parent_family=MODELS[model], changes=[TARGET], definitions=defs, compiler_started=False,
        canonical_gate_passed=False, gameplay_ipc=None, cache=str(cache))
    save(root/'prepared.json', prepared)
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(prepared, compiler_started=True,
        invocation=os.environ['INVOCATION_ID'], affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], standard_suite=False, hardware_acceptance=False,
                  canonical_gate_passed=False, gameplay_ipc=None)
    start = time.monotonic()
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
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
