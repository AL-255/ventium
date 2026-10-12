#!/usr/bin/env python3
"""Build the combined I-fill/bank-overlap/payload-kind timing derivative.

Admit the actual closed cache tests and byte-identical extracted proofs. Retain
all 195 sources, all 150 parent definitions, and one payload-only sideband flag.
This is a private candidate, not canonical, standard-suite or FPGA acceptance.
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

import build_payload_code_hint_core as prior
import prepare_payload_current as recipe
import run_payload_code_hint_leaf as mux
import run_payload_fetch_kind_leaf as requests

common = prior.common
sha, load, save, stable = common.sha, common.load, common.save, common.stable
REPO = prior.REPO
MODEL = '4f7a740c471cfe9e81ca7d6d86dbbaf00c24c5987d95ff6688ae1338d1649f02'


def check_overlap(result):
    assert result['passed'] and result['pins_unchanged'] and not result['errors']
    assert [(r['label'], r['build_exit'], r['native_exit'], r['mutant']) for r in result['rows']] == [
        ('ff-primary', 0, 0, False), ('lut-primary-shadow', 0, 0, False),
        ('wrong-unowned-overlap', 0, 1, True)]


def terminal(unit, invocation):
    owner = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-pInvocationID', '-pMainPID',
        '-pSubState', '-pExecMainStatus'], text=True).splitlines())
    assert owner == dict(InvocationID=invocation, MainPID='0', SubState='exited', ExecMainStatus='0'), owner
    return owner


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'prior-prepared', 'overlap-cache', 'out'):
        ap.add_argument('--'+name, required=True, type=Path)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, oldroot, overlap = (getattr(args, n).resolve(strict=True)
                               for n in ('parent', 'prior_prepared', 'overlap_cache'))
    root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    assert re.fullmatch('[0-9a-f]{32}', os.environ['INVOCATION_ID'])
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    previous = load(oldroot/'prepared.json')
    pins = dict(old['pins'], **previous['pins'])
    old_source = Path(previous['parent'])/'candidate'
    originals = {n: (old_source/n).read_text() for n in recipe.CURRENT}
    current = {n: (parent/'candidate'/n).read_text() for n in recipe.CURRENT}
    changed = recipe.transform(current, originals)
    old_hint = recipe.payload.transform(originals)
    for on in (False, True):
        assert mux.leaf(changed['rtl/mem/ven_l1d.sv'], 'check', on) == mux.leaf(
            old_hint['rtl/mem/ven_l1d.sv'], 'check', on)
    assert requests.extract(changed['rtl/core/core.sv'],
                            (parent/'candidate/rtl/core/core_bus_driver.svh').read_text()) == requests.extract(
        originals['rtl/core/core.sv'], (old_source/'rtl/core/core_bus_driver.svh').read_text())
    cache = Path(previous['cache'])
    payload_gate = load(cache/'closed.json')
    prior.cache_passed(payload_gate)
    pins.update(load(cache/'started.json')['pins'])
    for row in payload_gate['variants']:
        folder = cache/row['name']
        pins[str(folder/'obj/test')] = row['binary_sha256']
        for label in ('positive', 'negative') if row['name'] == 'on' else ('positive',):
            pins[str(folder/(label+'.log'))] = row[label+'_log_sha256']
            pins[str(folder/(label+'.cycles.txt.gz'))] = row[label+'_observations_gz_sha256']
    pair_gate = load(overlap/'closed.json')
    check_overlap(pair_gate)
    pins.update(pair_gate['pins'])
    assert (overlap/'ff-primary/ven_l1d.sv').read_text() == recipe.overlap.transform(current['rtl/mem/ven_l1d.sv'])
    for row in pair_gate['rows']:
        folder = overlap/row['label']
        for path, key in ((folder/'obj/Vtb_l1d_pair_store', 'binary_sha256'),
                          (folder/'run.log', 'log_sha256'), (folder/'build.log', 'build_log_sha256')):
            pins[str(path)] = row[key]
        log = (folder/'run.log').read_text()
        assert ('PAIR-OVERLAP-ACK' in log or 'MISMATCH' in log) if row['mutant'] else (
            'PAIR-OVERLAP-CACHE-OK checks=3 returns=2 held=3' in log and 'L1D-PAIR-STORE-GATE-OK' in log)
    owners = {
        'payload': terminal('ventium-payload-code-hint-cache-oct12.service', 'bc5d852e779a49d0b43463626c6dcda0'),
        'overlap': terminal('ventium-pair-overlap-current-cache-r2-oct12.service', 'a5d89ba6fb814021a108b3630742474c'),
    }
    files = common.candidate_files(parent/'candidate')
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    for p in (Path(__file__), Path(prior.__file__), Path(recipe.__file__), Path(mux.__file__),
              Path(requests.__file__), Path(recipe.overlap.__file__), Path(recipe.payload.__file__),
              Path(recipe.fetch.__file__), parent/'build-started.json', parent/'build-closed.json',
              parent/'obj/tb_ventium', oldroot/'prepared.json', overlap/'started.json', overlap/'closed.json',
              cache/'started.json', cache/'closed.json'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    for name, source in changed.items():
        (root/'candidate'/name).write_text(source)
    relative = [str(p.relative_to(parent/'candidate')) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [n for n in relative if sha(parent/'candidate'/n) != sha(root/'candidate'/n)] == sorted(recipe.CURRENT)
    host = root/('tb_payload_current_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command, definitions = prior.build_command(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/n): sha(root/'candidate'/n) for n in relative})
    prepared = dict(command=command, definitions=definitions, pins=pins, host=str(host),
        parent=str(parent), parent_model=MODEL, changes=sorted(recipe.CURRENT), owners=owners,
        compiler_started=False, canonical_gate_passed=False, standard_suite=False,
        hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    save(root/'prepared.json', prepared)
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(prepared, compiler_started=True,
        invocation=os.environ['INVOCATION_ID'], affinity=sorted(os.sched_getaffinity(0))))
    start = time.monotonic()
    result = dict(passed=False, errors=[], canonical_gate_passed=False, standard_suite=False,
                  hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
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
