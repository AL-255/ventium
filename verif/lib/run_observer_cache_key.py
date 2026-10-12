"""Reproduce/fix golden-cache mode aliasing with real QEMU and prebuilt RTL.

Single-worker light test; no RTL/QEMU build, modified oracle, fake trace,
comparator override, field mask or standard-suite claim. The experimental
observer binary must already have its separately qualified native hash.
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

import prepare_observer_cache_key as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as stream: json.dump(value, stream, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('tb', 'observer', 'out'): ap.add_argument('--'+key, type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out, tb, qemu = args.out.resolve(), args.tb.resolve(strict=True), args.observer.resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and shutil.disk_usage(scratch).free > 4*1024**3
    assert sha(qemu) == '52a9ca27d2d1bb40a360a7c2e881b8fe63b0795f285ae823b96e33e75ef0ff31'
    stamp = tb.parent/'Vventium_top__verFiles.dat'
    cmd = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
    defs = set(re.findall(r'\+define\+(\w+)', cmd))
    assert ' --assert ' in cmd and {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC'} <= defs
    assert not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_SYS_FASTPATH_ALL'} & defs
    ref = REPO/'ventium-refs/07-p5-emulation-harness'
    original = REPO/'verif/lib/verify_worker.sh'
    source = REPO/'verif/tests/smoke/smoke.s'
    out.mkdir()
    candidate = out/'worker-candidate.sh'
    candidate.write_text(recipe.transform(original.read_text()))
    subprocess.run(['bash', '-n', str(candidate)], check=True)
    base = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_'))}
    base.update(ROOT=str(REPO), QEMU=str(qemu), GEN_TRACE=str(REPO/'verif/qemu-trace/gen_trace.py'),
        COMPARE=str(REPO/'verif/diff/compare.py'), ELF2FLAT=str(REPO/'verif/tests/elf2flat.py'),
        ISA_VERIFY=str(ref/'tools/isa_verify.py'), P5TRACE=str(REPO/'build/p5trace.so'), TB_BIN=str(tb),
        M5_METRICS=str(REPO/'verif/m5_metrics.py'), PYTHON=sys.executable, CC='gcc',
        CFLAGS_BASE='-m32 -march=pentium -nostdlib -static -Wl,--build-id=none',
        PORTBASE='39800', M5_TOL_PCT='10', TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1',
        KCLASS='INT', TB_EXTRA_FLAGS='--cycle-func --l1-axi', TB_CYCLE_EXTRA_FLAGS='--l1-axi',
        AXI_RLAT='7', AXI_WLAT='7')
    pins = {str(p):sha(p) for p in (original, candidate, Path(__file__), Path(recipe.__file__),
        Path(tracefmt.__file__), source, tb, stamp, *(Path(base[k]) for k in
        ('QEMU', 'GEN_TRACE', 'COMPARE', 'ELF2FLAT', 'ISA_VERIFY', 'P5TRACE', 'M5_METRICS')))}
    save(out/'started.json', dict(pins=pins, invocation=os.environ.get('INVOCATION_ID'),
        affinity=sorted(os.sched_getaffinity(0)), model_sha256=sha(tb), oracle_sha256=sha(qemu)))
    result = dict(passed=False, rows=[], errors=[], gameplay_ipc=None, canonical_gate=False,
                  standard_suite=False, physical_board=False)
    begin = time.monotonic()

    def execute(group, index, mode, worker, value):
        work = out/group/f'case{index:02d}'; work.mkdir()
        cache = out/group/'cache'
        env = dict(base, WORKDIR=str(work), CACHE_DIR=str(cache), VTM_QEMU_GDB_PREEXIT=value)
        command = ['bash', '-x', str(worker), mode, 'smoke', str(source),
                   '0x08048000', '0x08048000', '22', '0', '0']
        save(work/'command.json', dict(argv=command, observer_value=value, mode=mode))
        with (work/'worker.log').open('x') as log:
            rc = subprocess.run(['timeout', '--kill-after=5s', '45s', *command], env=env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=55).returncode
        assert rc == 0, (group, index, rc)
        report = (work/f'smoke.{mode}.result').read_text().strip().split('|')
        log = (work/'worker.log').read_text()
        paths = re.findall(r'^\+ GOLD=(.+)$', log, re.M)
        assert len(paths) == 1 and Path(paths[0]).parent == cache
        golden = tracefmt.read_trace(paths[0])
        actual = tracefmt.read_trace(str(work/f'smoke.{mode}_rtl.vtrace'))
        assert len(actual.records) == 22
        assert all(r['n'] == i for i, r in enumerate(golden.records))
        assert all(r['n'] == i for i, r in enumerate(actual.records))
        assert [r['pc'] for r in actual.records[:len(golden.records)]] == [r['pc'] for r in golden.records]
        row = dict(group=group, index=index, mode=mode, observer_value=value,
            native_exit=rc, report=report, cache_hit=int(report[-1]), golden_path=paths[0],
            golden_sha256=sha(paths[0]), golden_records=len(golden.records), rtl_records=len(actual.records))
        if mode == 'func':
            row['verdict'] = report[3]
            assert row['verdict'] == ('PASS' if len(golden.records) == 22 else 'FAIL')
            assert ('length mismatch only' in (work/'smoke.func_cmp.txt').read_text()) == (len(golden.records) == 21)
        else:
            assert report[3] == '1' and 'CONTROL-FLOW DIVERGENCE' not in '|'.join(report)
            argv = (work/'smoke.cycle_rtl.argv').read_bytes().split(b'\0')
            assert argv.pop() == b''
            argv = [x.decode() for x in argv]
            func_gold = tracefmt.read_trace(result['rows'][-1]['golden_path'])
            row['init_esp'] = argv[argv.index('--init-esp')+1]
            assert row['init_esp'] == func_gold.records[0]['esp']
            row['paired_v'] = sum(r.get('pipe') == 'V' and bool(r.get('paired')) for r in actual.records)
            assert row['paired_v'] > 0 and argv.count('--cycle') == 1 and '--l1-axi' in argv
        result['rows'].append(row)
        save(work/'closed.json', row)
        print(json.dumps(row), flush=True)
        return row

    try:
        for group, worker, values, counts, hits in (
            ('old-forward', original, ('0','1'), (21,21), (0,1)),
            ('old-reverse', original, ('1','0'), (22,22), (0,1)),
            ('fixed', candidate, ('0','1','1','0'), (21,22,22,21), (0,0,1,1)),
        ):
            (out/group).mkdir(); (out/group/'cache').mkdir()
            for i, value in enumerate(values):
                row = execute(group, i, 'func', worker, value)
                assert (row['golden_records'], row['cache_hit']) == (counts[i], hits[i])
            golds = list((out/group/'cache').glob('*.vtrace'))
            assert len(golds) == (2 if group == 'fixed' else 1)
        execute('fixed', 4, 'cycle', candidate, '0')
        result['passed'] = True
    except Exception as error:
        import traceback
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p) == h for p,h in pins.items()), seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save(out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k != 'rows'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
