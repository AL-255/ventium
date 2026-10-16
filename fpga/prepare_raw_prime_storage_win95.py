"""Prepare the current source-sealed PC's cold Win95 run; never launch it.

Use the established unmodified standard-VGA disk and cold-reset controller.
Only model/source lineage and the owning service change. Desktop evidence,
input interaction and physical FPGA acceptance remain separate requirements.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import shutil

import prepare_fp_repair_win95 as previous
import raw_prime_storage_controls as controls
import raw_prime_storage_evidence as evidence

ROOT = controls.build.ROOT
MODEL = evidence.MODEL
UNIT = 'ventium-raw-prime-storage-win95-oct16-r1.service'
PREVIOUS_SHA = '62a2da769a1fc9bcc2249cabd7ee3df6d8ba99843f2ce4a05f8d9270f0c63b9e'


def derive(original, soc, pins):
    assert previous.sha(Path(previous.__file__)) == PREVIOUS_SHA
    text = previous.derive(original, soc, pins)
    # CPU10 and all native arguments, resource checks, collection, shutdown,
    # error scanning and classification stay exactly as in the qualified runner.
    for old, new in ((previous.q.MODEL, MODEL), (previous.UNIT, UNIT)):
        assert text.count(old) == 1
        text = text.replace(old, new)
    ast.parse(text)
    return text


def check_controls(soc):
    model = controls.selected_model(soc)
    assert model == MODEL
    paths = [ROOT/'raw-prime-storage-input-r1/audit.json',
             soc/'coremark-ui-disabled-r1/audit.json']
    for path in paths:
        value = controls.build.load(path)
        assert value['passed'] and value['model'] == MODEL and not value['standard_suite']
    assert not controls.build.load(paths[1])['duration_valid']
    return paths


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == ROOT and root.parent == scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != controls.build.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 4*1024**3 + 10*1024**2
    soc = root/'raw-prime-storage-soc-r1'
    control_paths = check_controls(soc)
    manifest = root/'raw-prime-storage-fpga-r1/input-manifest.json'
    source_pins = evidence.check(manifest.parent)
    template = previous.q.PARENT/'run_win95_cold.py'
    assert previous.sha(template) == previous.q.TEMPLATES['run_win95_cold.py']
    definitions = set((soc/'defines.txt').read_text().splitlines())
    assert len(definitions) == 157 and {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH',
        'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_BOUNDED', 'VEN_SYS_FASTSTORE_FLAT',
        'VEN_X87_MF_STRICT', 'VEN_DDR_POSTED', 'VEN_AO486_SINGLE_FILL'} <= definitions
    target = soc/'run_win95_full_cold.py'
    receipt = root/'raw-prime-storage-win95-prepared.json'
    assert not target.exists() and not receipt.exists()
    paths = [template, Path(__file__).resolve(), Path(previous.__file__).resolve(),
        Path(previous.q.__file__).resolve(), Path(controls.__file__).resolve(),
        Path(evidence.__file__).resolve(), soc/'prepared.json', soc/'build-started.json',
        soc/'build-closed.json', soc/'defines.txt',
        soc/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat', manifest, *control_paths]
    pins = {p: previous.sha(p) for p in paths}
    code = derive(template.read_text(), soc, pins)
    assert controls.build.stable(source_pins)
    with target.open('x') as stream:
        stream.write(code)
    value = dict(prepared_not_launched=True, model=MODEL, manifest=evidence.MANIFEST,
        inputs={str(p): h for p, h in pins.items()}, source_pins_checked=len(source_pins),
        launcher=str(target), launcher_sha256=previous.sha(target), unit=UNIT,
        cpu=10, tasks_max=160, memory_max=2*1024**3, swap_max=0,
        cpu_quota_percent=100, file_size_limit=4*1024**3, runtime_max_seconds=262800,
        native_wall_seconds=259200, native_cycle_cap=9000000000,
        disk_admission=8*1024**3, disk_stop_floor=4*1024**3,
        cold_reset=True, snapshots=False, guest_modifications=False,
        unchanged_native_command_and_environment=True, ui_input_enabled=False,
        canonical_gate_passed=False, desktop_acceptance=False, ui_acceptance=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None,
        next='Launch only with sufficient disk headroom; freeze actual live admission, '
             'inspect the desktop, close normally, then independently grade closed evidence. '
             'This controller is boot-only, not keyboard/mouse interaction acceptance.')
    with receipt.open('x') as stream:
        json.dump(value, stream, indent=2)
    print('Prepared cold Win95 controller for '+MODEL+'; no guest launched.', flush=True)


if __name__ == '__main__':
    main()
