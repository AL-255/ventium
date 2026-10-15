"""Prepare the existing cold Quake flow for the DECODE-bus candidate.

Identity-only adaptation: no new simulator, snapshot, guest change, relaxed
acceptance criterion or resource limit. Preparation does not launch anything.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import prepare_fp_repair_cold as parent
from prepare_fragment_exact_timing import replace, sha

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
MODEL = '7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68'
MANIFEST = '36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc'
PARENT_GENERATOR = '6d8bb0f872a0e33566ee5a57e35f990ab5ff7008870664c2aaf5953558915ef4'
UNIT = 'ventium-decode-bus-quake-oct15-r1.service'
LEAF = 'quake-cold-decode-bus-oct15.1'


def derive(original, soc, pins):
    old_model = parent.MODEL
    try:
        parent.MODEL = MODEL
        outputs = parent.derive(original, soc, pins)
    finally:
        parent.MODEL = old_model
    name = 'run_quake_cold.py'
    old = outputs[name]
    text = replace(old, "'quake-cold-fp-repair-oct13.1'", repr(LEAF))
    text = replace(text, "'ventium-fp-repair-quake-oct13.service'", repr(UNIT))
    # Everything after identity/pin declarations, including native argv,
    # ownership, waits, EOF, closure and output checks, remains byte-identical.
    anchor = 'def require('
    assert old[old.index(anchor):] == text[text.index(anchor):]
    outputs[name] = text
    for name, code in outputs.items():
        ast.parse(code, filename=name)
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    assert sha(Path(parent.__file__)) == PARENT_GENERATOR
    soc = root/'decode-bus-soc-r1'
    manifest = root/'decode-bus-fpga-r1/input-manifest.json'
    assert sha(manifest) == MANIFEST
    assert sha(soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    prepared = json.loads((soc/'prepared.json').read_text())
    assert prepared['added_defines'] == ['VEN_X87_MF_STRICT']
    assert prepared['changes'] == ['rtl/core/core_bus_driver.svh']
    defines = (soc/'defines.txt').read_text().splitlines()
    assert len(defines) == len(set(defines)) == 157
    assert {'VEN_X87_MF_STRICT', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_BOUNDED',
            'VEN_SYS_FASTSTORE_FLAT', 'VEN_DDR_POSTED', 'VEN_AO486_SINGLE_FILL'} <= set(defines)
    closed = json.loads((soc/'build-closed.json').read_text())
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert closed['binary_sha256'] == MODEL
    cm = json.loads((soc/'coremark-r1/audit.json').read_text())
    assert cm['passed'] and cm['model'] == MODEL and cm['no_oom'] and cm['all_children_reaped']
    original, pins = {}, {}
    for name, digest in parent.TEMPLATES.items():
        path = parent.PARENT/name
        assert sha(path) == digest
        original[name], pins[path] = path.read_text(), digest
    for path in (soc/'prepared.json', soc/'build-started.json', soc/'build-closed.json',
                 soc/'defines.txt', soc/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat',
                 soc/'coremark-r1/audit.json', manifest, Path(parent.__file__).resolve(),
                 Path(__file__).resolve()):
        pins[path] = sha(path)
    outputs = derive(original, soc, pins)
    receipt = root/'decode-bus-cold-prepared.json'
    assert not receipt.exists() and all(not (soc/name).exists() for name in outputs)
    for name, code in outputs.items():
        path = soc/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream:
            stream.write(code)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, model=MODEL, manifest=MANIFEST,
            inputs={str(path): digest for path, digest in pins.items()},
            outputs={str(soc/name): sha(soc/name) for name in outputs}, unit=UNIT, leaf=LEAF,
            cold_reset=True, snapshots=False, guest_patches=False, cpu=11, tasks_max=160,
            memory_max=2*1024**3, swap_max=0, disk_launch_floor=6*1024**3,
            disk_stop_floor=4*1024**3, unchanged_native_argv_and_acceptance=True,
            canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
            gameplay_ipc=None), stream, indent=2)
    print('Candidate cold Quake prepared; no run launched. Win95 helper cannot launch Win95.', flush=True)


if __name__ == '__main__':
    main()
