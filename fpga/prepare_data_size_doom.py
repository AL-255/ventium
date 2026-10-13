"""Prepare a bounded cold Doom startup probe on the current repaired PC.

Use the existing 100M-cycle/1800s diagnostic lifecycle, original media and
passive observers. No FPGA writes, snapshots, stepping or guest patches.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil

import build_data_size_soc as native
import prepare_data_size_synthesis as timing
import prepare_endpoint_map_doom_trace as trace


def transform(source):
    # This also checks the exact native runner hash before changing anything.
    text = trace.transform(source)
    for before, after, count in (
        ('34000000', '100000000', 2),
        ('900', '1800', 2),
        ('import build_endpoint_map_soc as native', 'import build_data_size_soc as native', 1),
        ('import prepare_endpoint_map_synthesis as timing', 'import prepare_data_size_synthesis as timing', 1),
        ('timing.ROOT', 'Path(__file__).resolve().parents[1]', 2),
        ("/'endpoint-map-soc-r1'", "/'soc-r1'", 1),
        ('ventium-endpoint-map-doom-smoke-', 'ventium-data-size-doom-smoke-', 1),
        ("'--vtm-dump-start','4098000'", "'--vtm-dump-start','6000000'", 1),
        ("'--ven-state-start','32720000'", "'--ven-state-start','50000000'", 1),
        ("'--ven-fault-ring-start','4000000','--ven-fault-ring-events','8'",
         "'--ven-fault-ring-start','6000000','--ven-fault-ring-events','16'", 1)):
        text = trace.change(text, before, after, count)
    # All spawning, timeout, cleanup, media/closure checks remain unchanged.
    boundary = '    child=None;reason=None;failure=None;'
    assert text[text.index(boundary):] == source[source.index(boundary):]
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    args = ap.parse_args()
    root = args.root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == scratch/'ventium-data-size.v2HaTO2X'
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    pc, out = root/'soc-r1', root/'doom-controller-r1'
    assert not out.exists()
    closed, started = native.load(pc/'build-closed.json'), native.load(pc/'build-started.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit'] == 0
    assert native.sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == closed['binary_sha256'] == timing.MODEL
    assert started['changes'] == native.CHANGES and native.stable(started['pins'])
    source = Path(__file__).with_name('run_endpoint_map_doom_smoke.py')
    text = transform(source.read_text())
    pins = {str(p):native.sha(p) for p in (Path(__file__), Path(native.__file__), Path(timing.__file__),
        Path(trace.__file__), source, pc/'build-started.json', pc/'build-closed.json')}
    out.mkdir()
    with (out/'run.py').open('x') as f: f.write(text)
    native.save(out/'prepared.json', dict(pins=pins, model=timing.MODEL,
        driver_sha256=hashlib.sha256(text.encode()).hexdigest(), max_cycles=100000000,
        max_seconds=1800, retire_window=[6000000,6040000], state_window=[50000000,50020000],
        fault_events=16, fault_start_retire=6000000, cold=True, passive=True,
        guest_modified=False, fpga_modified=False, standard_suite=False,
        hardware_acceptance=False, gameplay_ipc=None, fps=None))
    print('Prepared current-model cold Doom diagnostic; no run or board action launched.')


if __name__ == '__main__': main()
