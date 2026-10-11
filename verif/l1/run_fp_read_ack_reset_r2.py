#!/usr/bin/env python3
"""R2 real L1 reset/owner test, including the active dual-hit dependencies.

This is a sequential cache test, not whole-core reset or FPGA acceptance.
Run inside the shared build guard; no live/frozen RTL source is modified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('candidate', 'parent', 'out'):
        parser.add_argument('--'+key, type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    candidate, parent = args.candidate.resolve(strict=True), args.parent.resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and not out.exists() and out.is_relative_to(scratch)
    assert candidate.is_relative_to(scratch) and parent.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert subprocess.run([str(repo/'tools/build_scope.sh'), '--is-active'], pass_fds=(9,)).returncode == 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    manifest = json.loads((candidate/'input-manifest.json').read_text())
    assert sha(candidate/'input-manifest.json') == '1be147cc54d3f92991bef55d739fb2254eb5883079fe075da3cdee01385a1383'
    defs = (candidate/'defines.txt').read_text().splitlines()
    assert defs == manifest['hardware_defines'] and len(defs) == 156
    assert 'VEN_L1D_HIT_STREAM' not in defs
    # SYNTHESIS alone is removed so assertions execute. All hardware feature
    # switches stay present; the extra stream profile is explicitly diagnostic.
    defs.remove('SYNTHESIS')
    dut = candidate/'ventium/rtl/mem/ven_l1d.sv'
    old = parent/'ventium/rtl/mem/ven_l1d.sv'
    assert sha(dut) == '401f52cc73746b5d130c0d5d8e9a6009f9372b78dc6b40f316c61690e48dd11d'
    assert sha(old) == '11ed3337a28f0eebd546860ad2abad7996352036d2fc86c930b578009e0c42e0'
    # VEN_P54_DUAL_HIT is active in the hardware profile. Its response slots
    # instantiate the bank arbiter, so the L1 source alone is not a closure.
    dependency_names = ('ven_p54_bank_arb.sv', 'ven_p54_hit_return.sv')
    dependencies = {}
    for label, base in (('parent', parent), ('candidate', candidate)):
        rows = {r['frozen']: r['sha256'] for r in
                json.loads((base/'input-manifest.json').read_text())['files']}
        paths = [base/'ventium/rtl/mem'/n for n in dependency_names]
        for p in paths:
            assert sha(p) == rows[str(p.relative_to(base))]
        dependencies[label] = paths
    assert all(sha(a) == sha(b) for a,b in
               zip(dependencies['parent'], dependencies['candidate']))
    tb = repo/'verif/l1/tb_fp_read_ack_reset.sv'
    pins = {str(p): sha(p) for p in (Path(__file__), tb, dut, old,
        candidate/'input-manifest.json', candidate/'defines.txt',
        repo/'tools/build_scope.sh', repo/'tools/verilator_serial.sh',
        parent/'input-manifest.json', *dependencies['parent'], *dependencies['candidate'])}
    out.mkdir()

    def save(name, value):
        with (out/name).open('x') as f:
            json.dump(value, f, indent=2)

    save('started.json', dict(pins=pins, defines=defs, removed_define='SYNTHESIS',
        invocation=os.environ['INVOCATION_ID'], cgroup=Path('/proc/self/cgroup').read_text(),
        affinity=sorted(os.sched_getaffinity(0)), gameplay_ipc=None,
        whole_core_reset=False, physical_board=False))
    runs = []
    start = time.monotonic()
    error = None
    try:
        for stream in (False, True):
            summaries = []
            for label, source in (('parent', old), ('candidate', dut)):
                name = label+('-stream' if stream else '-hardware')
                work = out/name
                extra = (['READ_ACK_PORT'] if label == 'candidate' else [])
                if stream:
                    extra += ['VEN_L1D_HIT_STREAM']
                cmd = [str(repo/'tools/verilator_serial.sh'), '--binary', '--assert',
                    '-sv', '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                    *['-Werror-'+w for w in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN',
                        'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                    *['+define+'+d for d in defs+extra],
                    '--top-module', 'tb_fp_read_ack_reset', '--Mdir', str(work),
                    *map(str, dependencies[label]), str(source), str(tb)]
                save(name+'.build-command.json', cmd)
                with (out/(name+'.build.log')).open('x') as f:
                    p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT,
                                       pass_fds=(9,), timeout=90)
                row = dict(name=name, build_exit=p.returncode)
                runs.append(row)
                assert p.returncode == 0, row
                binary = work/'Vtb_fp_read_ack_reset'
                row['binary_sha256'] = sha(binary)
                with (out/(name+'.run.log')).open('x') as f:
                    p = subprocess.run([str(binary)], stdout=f, stderr=subprocess.STDOUT,
                                       timeout=15)
                row['native_exit'] = p.returncode
                row['run_log_sha256'] = sha(out/(name+'.run.log'))
                assert p.returncode == 0, row
                log = (out/(name+'.run.log')).read_text()
                markers = re.findall(r'^FP-READ-ACK-RESET-OK .+$', log, re.M)
                assert len(markers) == 1 and '%Error' not in log
                counts = {k: int(v) for k,v in re.findall(r'(\w+)=(\d+)', markers[0])}
                assert counts['fills'] == 24 and counts['hits'] == counts['stores'] == counts['writes'] == 3
                assert counts['streams'] == (3 if stream else 0)
                assert counts['comparisons'] > 100 and counts['reads'] >= 36
                row['summary'] = counts
                summaries.append(counts)
                print(json.dumps(row), flush=True)
            assert summaries[0] == summaries[1], 'complete test counts differ from parent'
    except BaseException as exc:
        import traceback
        error = dict(error=repr(exc), traceback=traceback.format_exc())
    stable = all(sha(p) == h for p,h in pins.items())
    result = dict(passed=error is None and stable and len(runs) == 4,
        error=error, runs=runs, pins_unchanged=stable, seconds=time.monotonic()-start,
        actual_cache_array=True, injected_internal_state=False,
        whole_core_reset=False, standard_suite=False, physical_board=False, gameplay_ipc=None)
    save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
