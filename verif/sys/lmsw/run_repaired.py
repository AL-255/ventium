"""Execute the immutable LMSW witnesses and compare complete system traces.

Uses unchanged pinned QEMU producer, trace format and functional comparator.
Both native success and full trace equality are required. Not a privilege/
fault matrix, canonical gate, gameplay measurement or standard-suite pass.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from run_probe import REPO, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('out', 'model', 'witness'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root, model, witness = args.out.resolve(), args.model.resolve(strict=True), args.witness.resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert os.sched_getaffinity(0) == {14, 15} and os.environ.get('INVOCATION_ID')
    assert shutil.disk_usage(scratch).free > 4*1024**3
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    source = REPO/'verif/qemu-trace/gen_trace.py'; compare = REPO/'verif/diff/compare.py'
    sys.path.insert(0, str(REPO/'verif/diff'))
    import tracefmt
    old = json.loads((witness/'closed.json').read_text())
    start = json.loads((witness/'started.json').read_text())
    built = json.loads((model.parent.parent/'build-closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and sha(model) == built['binary_sha256']
    assert old['passed'] and old['pins_unchanged'] and not old['repaired_rtl'] and len(old['rows']) == 16
    pins = dict(start['pins'])
    for path in (Path(__file__), model, model.parent.parent/'prepared.json',
                 model.parent.parent/'build-closed.json', qemu, source, compare,
                 REPO/'verif/diff/tracefmt.py', witness/'closed.json', witness/'started.json'):
        pins[str(path)] = sha(path)
    assert sha(qemu) == 'b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd'
    assert all(sha(p) == h for p,h in pins.items())
    root.mkdir()
    def save(name, value):
        with (root/name).open('x') as stream: json.dump(value, stream, indent=2)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VENTIUM_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(AXI_RLAT='7', AXI_WLAT='7', PYTHONDONTWRITEBYTECODE='1')
    def run(name, command, seconds=20):
        actual = ['taskset', '-c', '14,15', 'timeout', '--signal=TERM', '--kill-after=2s',
                  str(seconds)+'s', *map(str, command)]
        save(name+'.command.json', actual)
        with (root/(name+'.log')).open('x') as stream:
            return subprocess.run(actual, env=env, stdout=stream, stderr=subprocess.STDOUT).returncode
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        model_sha256=sha(model), affinity=[14,15], axi_latency=7, complete_trace=True))
    result = dict(passed=False, rows=[], errors=[], differential_gate=False, canonical_gate_passed=False,
                  standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    begin = time.monotonic()
    try:
        for index, row in enumerate(old['rows']):
            c = row['case']; name = f'm{c["MEMORY"]}-o{c["OP32"]}-v{c["VALUE"]:x}-c{c["CONTROL"]}'
            image = witness/(name+'.bin')
            assert sha(image) == row['image_sha256']; pins[str(image)] = sha(image)
            q = run(name+'-qemu', [qemu, '-display', 'none', '-monitor', 'none', '-serial', 'none',
                '-no-reboot', '-machine', 'pc', '-cpu', 'pentium', '-m', '32',
                '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04', '-bios', image], 5)
            rtl, golden = root/(name+'.rtl.vtrace'), root/(name+'.qemu.vtrace')
            r = run(name+'-rtl', [model, '--system', '--cosim', '--cycle-func', '--l1-axi',
                '--image', image, '--out', rtl, '--max-insn', '2000', '--max-cycles', '1000000',
                '--quiesce', '4096', '+ven_faultlog', '+ven_seglog'])
            g = run(name+'-golden', ['python3', source, '--system', '--qemu', qemu, '--cpu', 'pentium',
                '--image', image, '--image-mode', 'bios', '--max-insn', '2000', '--port', str(13380+index),
                '--out', golden])
            d = run(name+'-compare', ['python3', compare, '--mode', 'func', golden, rtl]) if g == 0 else None
            trace = tracefmt.read_trace(str(rtl))
            okay = q == 133 and r == 133 and g == 0 and d == 0 and trace.sys and trace.mode == 'func'
            okay &= 20 < len(trace.records) < 2000 and (int(trace.records[-1]['eax'],16) & 255) == 0x42
            okay &= '[FAULT] vec=' not in (root/(name+'-rtl.log')).read_text()
            okay &= 'guest exited' in (root/(name+'-golden.log')).read_text()
            if d == 0:
                log = (root/(name+'-compare.log')).read_text()
                okay &= 'sys compared: True' in log and 'RESULT: EQUIVALENT' in log
            result['rows'].append(dict(name=name, case=c, qemu_exit=q, rtl_exit=r, golden_exit=g,
                compare_exit=d, records=len(trace.records), passed=bool(okay),
                image_sha256=sha(image), rtl_sha256=sha(rtl), golden_sha256=sha(golden)))
            print(name, 'PASS' if okay else 'FAIL', flush=True)
        result['passed'] = all(r['passed'] for r in result['rows']) and len(result['rows']) == 16
        result['differential_gate'] = result['passed']
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin, pins=pins,
                  pins_unchanged=all(sha(p) == h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    result['artifacts'] = {str(p):sha(p) for p in root.iterdir() if p.is_file()}
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows', 'pins', 'artifacts')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
