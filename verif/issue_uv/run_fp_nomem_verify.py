#!/usr/bin/env python3
"""Run the unchanged canonical gate, retaining its failures and all cycle deltas."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--core', type=Path, required=True)
    args = ap.parse_args()
    root, parent = args.core.resolve(strict=True), args.parent.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == root
    built = json.loads((root/'build-closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    pins = json.loads((root/'build-started.json').read_text())['pins']
    for p in (Path(__file__), root/'obj/tb_ventium', REPO/'verif/verify.sh', REPO/'verif/lib/verify_worker.sh',
              parent/'verify-closed.json'):
        pins[str(p)] = sha(p)
    assert all(sha(p) == h for p, h in pins.items())
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_','VERIFY_'))}
    env.update(TMPDIR=str(root), PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator',
        TB_BIN=str(root/'obj/tb_ventium'), TB_EXTRA_FLAGS='--cycle-func --l1-axi',
        TB_CYCLE_EXTRA_FLAGS='--l1-axi', AXI_RLAT='7', AXI_WLAT='7',
        VERIFY_WORKDIR=str(root/'generic-work'), VERIFY_CACHE_DIR=str(root/'generic-cache'),
        VERIFY_JOBS='4', PORTBASE='39500')
    command = [str(REPO/'tools/build_scope.sh'), '--', 'taskset', '-c', '0-3',
        'timeout', '--signal=TERM', '--kill-after=15s', '600s', 'make', 'verify']
    def save(name, value):
        with (root/name).open('x') as f:
            json.dump(value, f, indent=2)
    save('verify-started.json', dict(command=command, pins=pins, invocation=os.environ.get('INVOCATION_ID'),
        environment={k:v for k,v in env.items() if k.startswith(('TB_','AXI_','VERIFY_')) or k in ('TMPDIR','PORTBASE')}))
    begin = time.monotonic()
    with (root/'generic.log').open('x') as f:
        p = subprocess.run(command, env=env, cwd=REPO, stdout=f, stderr=subprocess.STDOUT, timeout=660)
    old = sorted((parent/'generic-work').glob('*.cycle_rtl.vtrace'))
    new = sorted((root/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(old) == len(new) == 20 and [f.name for f in old] == [f.name for f in new]
    deltas = []
    for a, b in zip(old, new):
        x, y = tracefmt.read_trace(str(a)), tracefmt.read_trace(str(b))
        deltas.append(dict(name=b.name, same_records=x.records == y.records, records=len(y.records)))
    unchanged = all(sha(p) == h for p, h in pins.items())
    save('verify-closed.json', dict(canonical_gate_native_exit=p.returncode,
        canonical_gate_passed=p.returncode == 0, pins_unchanged=unchanged, deltas=deltas,
        seconds=time.monotonic()-begin, standard_suite=False, gameplay_ipc=None,
        masks_or_goldens_or_bands_changed=False))
    assert unchanged and all(row['same_records'] for row in deltas), 'A/B canonical cycle regression'
    return 0 if p.returncode == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
