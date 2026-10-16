#!/usr/bin/env python3
"""Bounded actual-wrapper mouse CSR gate; unrelated modules are black boxes.

Both DDR selections, 3.125/40 MHz parameters, and the old posted failure are
required. This does not execute the CPU, DDR, live mouse motion or Windows.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import repair_posted_mouse_wrapper as fix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != Path('/').stat().st_dev and shutil.disk_usage(scratch).free > 4*1024**3
    assert os.sched_getaffinity(0) <= {12, 13}
    parent, candidate, out = args.parent.resolve(strict=True), args.candidate.resolve(strict=True), args.out.resolve()
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert not any(out.is_relative_to(p) or p.is_relative_to(out) for p in (parent,candidate))
    pins = {}
    def pin(path):
        pins[str(path)] = fix.sha(path.read_bytes())
        return path
    old = json.loads(pin(parent/'input-manifest.json').read_text())
    new = json.loads(pin(candidate/'input-manifest.json').read_text())
    assert pins[str(parent/'input-manifest.json')] == fix.PARENT_SHA
    assert new['hardware_defines'] == old['hardware_defines']
    for folder, manifest in ((parent,old), (candidate,new)):
        for row in manifest['files']:
            path = pin(folder/row['frozen']); assert pins[str(path)] == row['sha256']
    assert (candidate/fix.WRAPPER).read_text() == fix.repair((parent/fix.WRAPPER).read_text())
    for path in (Path(__file__),Path(fix.__file__),Path(__file__).with_name('tb_posted_mouse_wrapper.sv'),
                 Path('/usr/bin/iverilog'),Path('/usr/bin/vvp')): pin(path.resolve())
    out.mkdir(mode=0o700)
    # Snapshot the actual compile inputs, so a later source edit cannot erase
    # a failed testcase or silently change its reproduction.
    names = (fix.WRAPPER,'flow/src/ven_mgmt_axil.v',
             'flow/src/ven_ps2_mailbox.sv','flow/src/ven_ps2_device.sv')
    frozen = {}
    for label, folder in (('parent',parent),('candidate',candidate)):
        frozen[label] = []
        for name in names:
            path = out/'source'/label/Path(name).name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes((folder/name).read_bytes())
            pin(path); frozen[label].append(path)
    tb = out/'source/tb_posted_mouse_wrapper.sv'
    tb.write_bytes(Path(__file__).with_name(tb.name).read_bytes()); pin(tb)
    start = time.monotonic(); rows = []
    (out/'started.json').write_text(json.dumps(dict(pins=pins,affinity=sorted(os.sched_getaffinity(0)),
        invocation=os.environ.get('INVOCATION_ID'), unrelated_modules_blackboxed=True),indent=2)+'\n')
    error = None
    try:
        for hz in (3125000,40000000):
            for posted in (False,True):
                for label, folder in (('parent',parent),('candidate',candidate)):
                    name = f'{label}-{hz}-posted{int(posted)}'
                    defines = [n for n in old['hardware_defines'] if posted or n!='VEN_DDR_POSTED']
                    executable = out/(name+'.vvp')
                    command = ['/usr/bin/iverilog','-g2012','-i','-s','tb_posted_mouse_wrapper',
                        '-Ptb_posted_mouse_wrapper.CLK_HZ='+str(hz),'-o',str(executable)]
                    command += ['-D'+n for n in defines]
                    command += [str(p) for p in frozen[label]]
                    command += [str(tb)]
                    compile_run = subprocess.run(command,capture_output=True,text=True,timeout=30)
                    (out/(name+'.compile.log')).write_text(compile_run.stdout+compile_run.stderr)
                    assert compile_run.returncode == 0, name+' compile failed'
                    run = subprocess.run(['/usr/bin/vvp',str(executable)],capture_output=True,text=True,timeout=15)
                    text = run.stdout+run.stderr
                    (out/(name+'.native.log')).write_text(text)
                    expected_failure = label=='parent' and posted
                    if expected_failure:
                        assert run.returncode == 1 and 'POSTED-MOUSE-CAPABILITY-MISSING' in text, name
                    else:
                        assert run.returncode == 0 and 'POSTED-MOUSE-WRAPPER-MICRO-OK' in text, name
                    rows.append(dict(name=name,command=command,compile_exit=compile_run.returncode,
                        native_exit=run.returncode,expected_old_bug=expected_failure,
                        executable_sha256=fix.sha(executable.read_bytes())))
        assert all(fix.sha(Path(p).read_bytes()) == h for p,h in pins.items())
    except Exception as exc:
        error = repr(exc)
    result = dict(passed=error is None,error=error,rows=rows,seconds=time.monotonic()-start,
        pins_unchanged=all(fix.sha(Path(p).read_bytes()) == h for p,h in pins.items()),
        full_wrapper_elaboration=False,processor=False,windows=False,physical_board=False,
        standard_suite=False,gameplay_ipc=None)
    (out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2),flush=True)
    return 0 if result['passed'] and result['pins_unchanged'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
