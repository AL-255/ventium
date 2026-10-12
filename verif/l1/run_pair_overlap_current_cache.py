#!/usr/bin/env python3
"""Full-size old/new cache miter for the rebased bank-overlap ACK cut.

Keep the historical coherent-store and same-line pair corpus; add owned and
unowned two-lane overlap plus retained response/backpressure transactions.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
import traceback

import prepare_pair_overlap_current as recipe
import run_pair_now_cache as common

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sha = common.sha


def fixture(flat):
    extra = (HERE/'tb_l1d_pair_now_extra.svh').read_text()
    overlap = (HERE/'tb_l1d_pair_overlap_extra.svh').read_text()
    anchor = "  warm_full_window(32'h64,mem[25]);\n  warm_full_window(32'h40,mem[16]);"
    assert extra.count(anchor) == 1
    extra = extra.replace(anchor, '  run_overlap_checks();\n'+anchor)
    return common.fixture((HERE/'tb_l1d_pair_store.sv').read_text(), flat, overlap+'\n'+extra)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'proof', 'out'):
        ap.add_argument('--'+name, required=True, type=Path)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    source, proof, root = args.source.resolve(strict=True), args.proof.resolve(strict=True), args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    old = source.read_text()
    changed = recipe.transform(old)
    leaf = json.loads((proof/'closed.json').read_text())
    assert leaf['passed'] and leaf['pins_unchanged'] and len(leaf['native_rows']) == 20
    assert [(r['label'], r['result']) for r in leaf['symbolic']] == [
        ('equivalent', 'unsat'), ('orphan-v', 'sat'), ('unowned-read', 'sat'), ('snoop', 'sat')]
    assert (proof/'ven_l1d.sv').read_text() == recipe.overlap.transform(recipe.restore_parent(old))
    pins = dict(leaf['pins'])
    for row in leaf['native_rows']:
        folder = proof/row['label']
        assert sha(folder/'tb.sv') == row['tb_sha256'] and sha(folder/'a.out') == row['binary_sha256']
        assert (folder/'run.log').read_text().strip() == row['log']
        assert row['native_exit'] == (1 if row['mutant'] else 0)
        for path in (folder/'tb.sv', folder/'a.out', folder/'run.log'):
            pins[str(path)] = sha(path)
    modules = [source.with_name(n) for n in ('ven_p54_bank_arb.sv', 'ven_p54_hit_return.sv')]
    dependencies = [Path(__file__), Path(recipe.__file__), Path(recipe.overlap.__file__),
        Path(recipe.same_line.__file__), Path(common.__file__), Path(common.pair.__file__),
        HERE/'run_parallel_tag_cache.py', HERE/'tb_l1d_pair_store.sv',
        HERE/'tb_l1d_pair_now_extra.svh', HERE/'tb_l1d_pair_overlap_extra.svh', source,
        proof/'closed.json', proof/'ven_l1d.sv', *modules]
    pins.update({str(p): sha(p) for p in dependencies})
    assert all(sha(p) == h for p, h in pins.items())
    root.mkdir()
    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)
    control = root/'control_l1d.sv'
    control.write_text(common.control_source(old))
    pins[str(control)] = sha(control)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), source=str(source)))
    start = time.monotonic()
    result = dict(passed=False, errors=[], rows=[], whole_core=False, standard_suite=False,
                  hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    try:
        for label, flat, shadow, mutant in (
            ('ff-primary', False, False, False), ('lut-primary-shadow', True, True, False),
            ('wrong-unowned-overlap', True, True, True)):
            assert shutil.disk_usage(scratch).free > 4*1024**3
            folder = root/label
            folder.mkdir()
            sv = changed
            if mutant:
                owned = recipe.overlap.OWNED
                assert sv.count(owned) == 1
                sv = sv.replace(owned, owned.replace('&& rd_match', ''))
            cache, tb = folder/'ven_l1d.sv', folder/'tb_l1d_pair_store.sv'
            cache.write_text(sv)
            tb.write_text(fixture(flat))
            pins.update({str(p): sha(p) for p in (cache, tb)})
            flags = common.pair.FLAGS+['VEN_P54_DUAL_HIT', 'VEN_P54_DUAL_HIT_LEGACY_CAPTURE',
                'VEN_P54_DUAL_LOAD_PAIR', 'VEN_P54_DUAL_BYTE_LOAD_PAIR',
                'VEN_L1D_WINDOW_REUSE', 'VEN_L1D_WINDOW_KEEP_STORE']
            if flat: flags += ['VEN_L1D_TAG_LUTRAM']
            if shadow: flags += ['VEN_L1D_TWO_WINDOW_REUSE', 'VEN_L1D_TWO_WINDOW_KEEP_STORE']
            command = [str(REPO/'tools/verilator_serial.sh'), '--binary', '--assert', '-sv',
                '--top-module', 'tb_l1d_pair_store', '--Mdir', str(folder/'obj'), '-j', '32',
                '--output-split', '20000', '--output-split-cfuncs', '2000', '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                *['+define+'+d for d in flags], *map(str, modules), str(control), str(cache), str(tb)]
            row = dict(label=label, mutant=mutant, definitions=flags, command=command)
            result['rows'].append(row)
            with (folder/'build.log').open('x') as stream:
                child = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                    pass_fds=(9,), env=dict(os.environ, CCACHE_DISABLE='1'), timeout=240)
            row['build_exit'] = child.returncode
            assert child.returncode == 0, label
            binary = folder/'obj/Vtb_l1d_pair_store'
            with (folder/'run.log').open('x') as stream:
                child = subprocess.run([binary], stdout=stream, stderr=subprocess.STDOUT, timeout=30)
            log = (folder/'run.log').read_text()
            row.update(native_exit=child.returncode, binary_sha256=sha(binary),
                log_sha256=sha(folder/'run.log'), build_log_sha256=sha(folder/'build.log'))
            if mutant:
                assert child.returncode != 0 and ('PAIR-OVERLAP-ACK' in log or 'MISMATCH' in log), label
            else:
                assert child.returncode == 0 and 'L1D-PAIR-STORE-GATE-OK' in log, label
                assert 'PAIR-OVERLAP-CACHE-OK checks=3 returns=2 held=3' in log, label
                assert re.search(r'PAIR-NOW-CACHE-CHECKS checks=\d+ returns=\d+ held=3', log), label
                assert not re.search(r'FAIL|%Error|%Fatal|MISMATCH', log), label
            save(label+'/closed.json', row)
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start, pins=pins,
                  pins_unchanged=all(sha(p)==h for p, h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins', 'rows')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
