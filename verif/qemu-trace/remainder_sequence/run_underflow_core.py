"""Cold complete-core underflow differential tests with the retained bad core."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

from run_small_quotient import sha, save
HERE = Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('out','parent','candidate','reference'): ap.add_argument('--'+n,type=Path,required=True)
    a = ap.parse_args(); root = a.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == {13}
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free > 4*1024**3+64*1024**2
    models = {key:getattr(a,key).resolve(strict=True) for key in ('parent','candidate')}
    ref = a.reference.resolve(strict=True)
    pins = {str(p):sha(p) for p in (Path(__file__),HERE/'run_exception_core.py',HERE/'run_small_quotient.py')}
    for core in models.values():
        built = json.loads((core/'build-closed.json').read_text())
        assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
        assert sha(core/'obj/tb_ventium') == built['binary_sha256']
        for n in ('build-started.json','build-closed.json','obj/tb_ventium'): pins[str(core/n)] = sha(core/n)
    assert sha(models['parent']/'obj/tb_ventium') == '2ac15c8ba4fd6fbfcfb2dccb0daa0bb41448e7756b6abd2b2e32b8a92684bc1e'
    built = json.loads((ref/'closed.json').read_text())
    assert built['passed'] and built['pins_unchanged']
    assert sha(ref/'build/qemu-i386') == built['sha256'] == '998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85'
    for n in ('closed.json','source.json','build/qemu-i386'): pins[str(ref/n)] = sha(ref/n)
    fixtures = ('unmasked_underflow','underflow_bypass','underflow_operand_priority')
    for n in fixtures: pins[str(HERE/(n+'.S'))] = sha(HERE/(n+'.S'))
    root.mkdir(); save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        cycle_mode=1,axi_backend=True,axi_latency=7,cold=True,trace_masks_added=False,
        expected_parent_failures=list(fixtures[:2]),rejected_metadata_inherited=False))
    result = dict(passed=False,errors=[],rows=[],canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    start = time.monotonic()
    try:
        for name in fixtures:
            for label,core in models.items():
                out = root/(name+'-'+label)
                command = [sys.executable,'-B',HERE/'run_exception_core.py','--out',out,
                    '--core',core,'--build',ref,'--program',HERE/(name+'.S')]
                with (root/(name+'-'+label+'.log')).open('x') as log:
                    code = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=180).returncode
                closed = json.loads((out/'closed.json').read_text())
                expected = label == 'candidate' or name == 'underflow_operand_priority'
                assert code == (0 if expected else 1)
                assert closed['passed'] == expected and closed['pins_unchanged']
                assert closed['native_selfcheck_exit'] == closed['qemu_selfcheck_exit'] == 0
                assert closed['actual_v_retirements'] > 0 and closed['axi_backend']
                if not expected: assert closed['rtl_guest_exit'] == 1 and closed['qemu_guest_exit'] == 0
                result['rows'].append(dict(fixture=name,model=label,native_exit=code,
                    expected_pass=expected,actual_v_retirements=closed['actual_v_retirements'],
                    qemu_records=closed['qemu_records'],rtl_records=closed['rtl_records'],
                    seconds=closed['seconds'],closed_sha256=sha(out/'closed.json')))
        result['passed'] = True
    except Exception as e: result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']; save(root/'closed.json',result)
    print(json.dumps(result,indent=2),flush=True); return int(not result['passed'])


if __name__ == '__main__': raise SystemExit(main())
