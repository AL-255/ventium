#!/usr/bin/env python3
"""Check exact prepared caller bodies against a pinned frozen core in four states.

Run inside a bounded user service; generates only small external leaf fixtures.
No running model, frozen input or production RTL is changed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import prepare_integration as integration

HERE = Path(__file__).resolve().parent


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args()
    assert __debug__
    core = args.core.resolve(strict=True)
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert shutil.disk_usage(scratch).free > 2*1024**3
    assert re.fullmatch('[0-9a-f]{32}',os.environ.get('INVOCATION_ID',''))
    pins = {str(p):sha(p) for p in (Path(__file__).resolve(),core,
        HERE/'prepare_integration.py',HERE/'extract_reference.py',
        HERE/'ic_front_residency.svh',HERE/'tb_ic_residency_span.sv')}
    original = core.read_text()
    candidate = integration.transform(original)
    root.mkdir()
    (root/'core.sv').write_text(candidate)
    shutil.copyfile(HERE/'ic_front_residency.svh',root/integration.HEADER)
    shutil.copyfile(HERE/'ic_front_residency.svh',root/'ic_front_residency.svh')
    with (root/'extract.log').open('x') as log:
        run = subprocess.run(['python3','-B',str(HERE/'extract_reference.py'),
            '--core',str(core),'--output',str(root/'ic_residency_reference.svh')],
            stdout=log,stderr=subprocess.STDOUT,timeout=10)
    assert run.returncode == 0
    # The tested new expressions are extracted from the prepared core, not a
    # second manually maintained copy of the intended integration.
    bodies = []
    for name in integration.CALLERS:
        matches = re.findall(r'`ifdef '+integration.FLAG+r'\s*('+name+r'\s*=.*?;)\s*`else',
                             candidate,re.S)
        assert len(matches) == 1
        bodies.append(re.sub(r'^'+name+r'\b','new_'+name,matches[0]))
    tb = (HERE/'tb_ic_residency_span.sv').read_text()
    start = tb.index('  always_comb begin\n    new_pipe_bytes_ok')
    end = tb.index('\n  end',start)+len('\n  end')
    tb = tb[:start]+'  always_comb begin\n'+'\n'.join('    '+s for s in bodies)+'\n  end'+tb[end:]
    (root/'tb_integrated.sv').write_text(tb)
    generated = {str(p):sha(p) for p in root.iterdir() if p.is_file()}
    with (root/'started.json').open('x') as f:
        json.dump(dict(pins=pins,generated=generated,invocation=os.environ['INVOCATION_ID'],
                       candidate_core_sha256=sha(root/'core.sv'),production_modified=False),f,indent=2)
    def one(variant):
        mode, cpu = variant
        cmd = ['taskset','-c',str(cpu),'iverilog','-g2012','-gstrict-ca-eval',
            '-s','tb_ic_residency_span','-DVEN_IC_BRAM']
        if mode: cmd += ['-DVEN_IC_NO_FETCH_BYPASS']
        binary = root/f'variant{mode}.vvp'
        cmd += ['-I'+str(root),'-o',str(binary),str(root/'tb_integrated.sv')]
        started = time.monotonic()
        with (root/f'compile{mode}.log').open('x') as log:
            compile_run = subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=30)
        assert compile_run.returncode == 0
        command = ['taskset','-c',str(cpu),'vvp',str(binary)]
        with (root/f'run{mode}.log').open('x') as log:
            native = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=115)
        text = (root/f'run{mode}.log').read_text()
        expected = f'IC-RESIDENCY-PROPOSAL-OK no_bypass={mode} checks=5534560'
        passed = native.returncode == 0 and text.count(expected) == 1
        return dict(mode=mode,cpu=cpu,compile=cmd,command=command,native_exit=native.returncode,
            passed=passed,checks=5534560 if passed else None,seconds=time.monotonic()-started,
            log_sha256=sha(root/f'run{mode}.log'))
    error, rows = None, []
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            rows = list(pool.map(one,[(0,10),(1,12)]))
    except BaseException as exc:
        error = repr(exc)
    stable = all(sha(Path(p)) == h for p,h in {**pins,**generated}.items())
    result = dict(passed=error is None and stable and len(rows)==2 and all(r['passed'] for r in rows),
        error=error,rows=rows,inputs_unchanged=stable,invocation=os.environ['INVOCATION_ID'],
        full_core=False,standard_suite=False,fpga=False,gameplay_ipc=None,
        limitation='Settled four-state helper/caller proof; not fixed-address event sensitivity or full-core wiring.')
    with (root/'closed.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
