"""Prepare, but do not launch, the existing cold Win95 flow on the repair model.

The host wrapper never awards desktop acceptance. Retain original media,
native command, complete log collection and separate closed visual review.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import prepare_fp_repair_cold as q
from prepare_fragment_exact_timing import replace, sha, span

UNIT = 'ventium-fp-repair-win95-oct13.service'


def derive(original, soc, pins):
    text = original.replace(str(q.PARENT), str(soc)).replace(q.OLD_MODEL, q.MODEL)
    text = replace(text, 'ventium-sfetch16-win95-oct10.service', UNIT)
    text = replace(text, 'CPU, CYCLES, SECONDS = 26,', 'CPU, CYCLES, SECONDS = 10,')
    text = replace(text, "values['pids.max'] == '32'", "values['pids.max'] == '160'")
    block = 'PINS = {Path(p): h for p,h in ' + repr({str(p): h for p, h in pins.items()}) + '.items()}\n'
    block += '''PINS.update({MODEL: MODEL_SHA, DISK: DISK_SHA,
    FIXTURE / 'fixture-closed.json': '7b8c57e780fd36647dc0e915b9d0a7ef7eb07a87c106c659fcc132bfaf7ab579',
    **{ROMS / name: value for name, value in ROM_SHAS.items()},
    **{ROOT / 'tools' / (name + '.py'): value for name, value in HELPERS.items()}})
'''
    text = span(text, 'PINS = {', 'TERMINAL = ', block)
    text = replace(text, '    before = resource_receipt()\n', '''    before = resource_receipt()
    frozen = json.loads((HERE / 'build-started.json').read_text())
    built = json.loads((HERE / 'build-closed.json').read_text())
    require(built['passed'] and built['native_exit'] == 0 and built['inputs_unchanged'] and
            built['binary_sha256'] == MODEL_SHA, 'candidate build not closed')
    for path, expected in frozen['pins'].items():
        with Path(path).open('rb') as stream:
            require(hashlib.file_digest(stream, 'sha256').hexdigest() == expected, 'candidate input drift: ' + path)
''')
    text = replace(text, '        while process.poll() is None:\n', '''        while process.poll() is None:
            if shutil.disk_usage(stop.parent).free < 4 * 1024**3 and reason is None:
                reason = 'external disk reserve below 4 GiB; not desktop acceptance'
                request_stop(stop)
                deadline = min(deadline, time.monotonic() + 30)
''')
    ast.parse(text)
    assert "return 'CLOSED_UNQUALIFIED'" in text
    assert 'shutil.disk_usage(HERE).free >= 8 * 1024**3' in text
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == q.SCRATCH / 'ventium-fp-repair-transfer.a8nzrjHu'
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == q.SCRATCH
    soc = root / 'soc-r1'
    assert sha(soc / 'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == q.MODEL
    template = q.PARENT / 'run_win95_cold.py'
    assert sha(template) == q.TEMPLATES['run_win95_cold.py']
    manifest = root / 'fpga-r1/input-manifest.json'
    assert sha(manifest) == q.MANIFEST
    cm = json.loads((soc / 'coremark/audit.json').read_text())
    assert cm['passed'] and cm['model'] == q.MODEL
    pins = {template: sha(template)}
    for path in (soc / 'prepared.json', soc / 'build-started.json', soc / 'build-closed.json',
                 soc / 'defines.txt', soc / 'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat',
                 soc / 'coremark/audit.json', manifest, Path(__file__).resolve(), Path(q.__file__).resolve()):
        pins[path] = sha(path)
    target = soc / 'run_win95_full_cold.py'
    receipt = root / 'win95-prepared.json'
    assert not target.exists() and not receipt.exists()
    code = derive(template.read_text(), soc, pins)
    with target.open('x') as f:
        f.write(code)
    with receipt.open('x') as f:
        json.dump(dict(prepared_not_launched=True, model=q.MODEL, manifest=q.MANIFEST,
            inputs={str(p): h for p, h in pins.items()}, launcher=str(target), launcher_sha256=sha(target),
            unit=UNIT, cpu=10, tasks_max=160, memory_max=2*1024**3, swap_max=0,
            disk_admission=8*1024**3, disk_stop_floor=4*1024**3,
            cold_reset=True, snapshots=False, guest_modifications=False,
            desktop_acceptance=False, ui_acceptance=False, hardware_acceptance=False), f, indent=2)
    print('Cold Win95 prepared; no native run or acceptance.', flush=True)


if __name__ == '__main__':
    main()
