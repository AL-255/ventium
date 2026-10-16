"""Wait for the exact active CAD sequence, then build one prepared UI model.

No CAD retry, guest launch or FPGA programming. A replaced/failed owner or
resource deadline fails closed; the existing build_scope lock is never bypassed.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import time

import build_next_ready_ui_soc as build

UNIT = 'ventium-next-ready-timing-chain-oct16-r1.service'
INVOCATION = '53b5d32e82414436a25eee699e0d28dd'


def disposition(state):
    assert state['InvocationID'] == INVOCATION, 'CAD owner replaced'
    assert state['LoadState'] == 'loaded', 'CAD owner missing'
    if state['SubState'] == 'running':
        assert int(state['MainPID']) > 0 and state['ActiveState'] == 'active'
        return 'wait'
    assert state['SubState'] == 'exited' and state['MainPID'] == '0'
    assert state['Result'] == 'success' and state['ExecMainStatus'] == '0'
    return 'build'


def owner():
    fields = ('LoadState','ActiveState','SubState','MainPID','InvocationID','Result','ExecMainStatus')
    return dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show',UNIT,*['-p'+s for s in fields]],text=True,timeout=10).splitlines())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args(); root = args.out.resolve(strict=True)
    assert __debug__ and root.parent == build.ROOT
    assert Path(os.environ['TMPDIR']).resolve() == build.ROOT.parent
    assert os.environ['INVOCATION_ID'] and not (root/'build-started.json').exists()
    assert root.stat().st_dev != build.cpu.REPO.stat().st_dev
    prepared = root/'prepared.json'
    pins = {str(p):build.sha(p) for p in (prepared,Path(__file__),Path(build.__file__))}
    initial = owner(); assert disposition(initial) == 'wait'
    assert Path('/proc',initial['MainPID']).exists()
    build.save(root/'build-wait-started.json',dict(pins=pins,owner=initial,
        invocation=os.environ['INVOCATION_ID'],wait_seconds_limit=3000,build_once=True))
    started = time.monotonic(); result = dict(passed=False,error=None,build_launched=False)
    try:
        while True:
            state = owner(); action = disposition(state)
            assert time.monotonic()-started < 3000, 'CAD observation deadline; no restart'
            assert shutil.disk_usage(root).free > 5*1024**3, 'external disk reserve'
            assert build.stable(pins), 'prepared inputs changed'
            if action == 'build': break
            assert state['MainPID'] == initial['MainPID'] and Path('/proc',state['MainPID']).exists()
            print('Waiting for exact CAD sequence; compiler not started.',flush=True)
            time.sleep(30)
        proof = build.ROOT/'next-ready-sequence-closed.json'
        closed = build.load(proof)
        assert closed['passed'] and closed['error'] is None
        assert closed['synthesis']['InvocationID'] == '881fba3884214158a222ab511a4d4e13'
        for key in ('synthesis','clock'):
            assert closed[key]['SubState'] == 'exited' and closed[key]['MainPID'] == '0'
            assert closed[key]['ExecMainStatus'] == '0' and closed[key]['Result'] == 'success'
        result.update(cad_owner=state,cad_proof_sha256=build.sha(proof))
        # Independent exclusive guard remains inside the original build command.
        env = dict(os.environ,VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
        probe = subprocess.check_output([str(build.cpu.REPO/'tools/verilator_serial.sh'),'--version'],
                                        env=env,text=True,timeout=10)
        assert 'Verilator 5.046' in probe
        result['compiler_probe'] = probe.strip(); result['build_launched'] = True
        code = build.cpu.base.build(root)
        result['native_exit'] = code
        result['passed'] = code == 0 and build.load(root/'build-closed.json')['passed']
    except Exception as exc:
        result['error'] = repr(exc)
    result.update(seconds=time.monotonic()-started,pins_unchanged=build.stable(pins),
                  standard_suite=False,physical_fpga=False,gameplay_ipc=None)
    result['passed'] &= result['pins_unchanged']
    build.save(root/'build-wait-closed.json',result)
    print(result,flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
