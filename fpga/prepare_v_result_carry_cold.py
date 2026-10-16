"""Prepare a cold Quake run of the current V-result CPU model; no CAD launch.

Preserve the existing guest, transport, closure checks and resource limits.
Use CPU 14 so the older decode-bus run on CPU 11 remains independent.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import prepare_fp_repair_cold as parent
from prepare_fragment_exact_timing import replace, sha

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
MODEL = 'b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'
MANIFEST = 'ab1c791f3f472ec72a0c36628291d3c6d2e78a6a4a1b449a71a06840800ba8e0'
PARENT_GENERATOR = '6d8bb0f872a0e33566ee5a57e35f990ab5ff7008870664c2aaf5953558915ef4'
UNIT = 'ventium-v-result-carry-quake-oct16-r1.service'
LEAF = 'quake-cold-v-result-carry-oct16.1'


def derive(original, soc, pins):
    previous = parent.MODEL
    try:
        parent.MODEL = MODEL
        outputs = parent.derive(original, soc, pins)
    finally:
        parent.MODEL = previous
    old = outputs['run_quake_cold.py']
    text = replace(old, "'quake-cold-fp-repair-oct13.1'", repr(LEAF))
    text = replace(text, "'ventium-fp-repair-quake-oct13.service'", repr(UNIT))
    text = replace(text, 'CPU, CYCLES, SECONDS = 11,', 'CPU, CYCLES, SECONDS = 14,')
    anchor = 'def require('
    assert old[old.index(anchor):] == text[text.index(anchor):]
    outputs['run_quake_cold.py'] = text
    for name, code in outputs.items(): ast.parse(code, filename=name)
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    assert sha(Path(parent.__file__)) == PARENT_GENERATOR
    soc = root/'v-result-carry-soc-r1'
    manifest = root/'v-result-carry-posted-mouse-fpga-r1/input-manifest.json'
    assert sha(manifest) == MANIFEST
    assert sha(soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    prepared = json.loads((soc/'prepared.json').read_text())
    assert prepared['added_defines'] == []
    assert prepared['changes'] == ['rtl/core/core.sv', 'rtl/core/v_pipe.sv']
    assert prepared['aux_sha256'] == '2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da'
    defines = (soc/'defines.txt').read_text().splitlines()
    assert len(defines) == len(set(defines)) == 157
    assert {'VEN_X87_MF_STRICT', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_BOUNDED',
            'VEN_SYS_FASTSTORE_FLAT', 'VEN_DDR_POSTED', 'VEN_AO486_SINGLE_FILL'} <= set(defines)
    closed = json.loads((soc/'build-closed.json').read_text())
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert closed['binary_sha256'] == MODEL
    cm = json.loads((soc/'coremark-r1/audit.json').read_text())
    assert cm['passed'] and cm['model'] == MODEL and cm['no_oom'] and cm['all_children_reaped']
    assert not cm['duration_valid'] and not cm['standard_suite']
    frozen = json.loads((soc/'build-started.json').read_text())
    for path, expected in frozen['pins'].items(): assert sha(Path(path)) == expected, path
    original, pins = {}, {}
    for name, digest in parent.TEMPLATES.items():
        path = parent.PARENT/name
        assert sha(path) == digest
        original[name], pins[path] = path.read_text(), digest
    for path in (soc/'prepared.json', soc/'build-started.json', soc/'build-closed.json',
                 soc/'defines.txt', soc/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat',
                 soc/'coremark-r1/audit.json', manifest, Path(parent.__file__).resolve(),
                 Path(__file__).resolve()): pins[path] = sha(path)
    outputs = derive(original, soc, pins)
    receipt = root/'v-result-carry-cold-prepared.json'
    assert not receipt.exists() and all(not (soc/name).exists() for name in outputs)
    for name, code in outputs.items():
        path = soc/name; path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream: stream.write(code)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, model=MODEL, manifest=MANIFEST,
            inputs={str(path): digest for path, digest in pins.items()},
            outputs={str(soc/name): sha(soc/name) for name in outputs}, unit=UNIT, leaf=LEAF,
            cold_reset=True, snapshots=False, guest_patches=False, cpu=14, tasks_max=160,
            memory_max=2*1024**3, swap_max=0, disk_launch_floor=6*1024**3,
            disk_stop_floor=4*1024**3, unchanged_native_argv_except_cpu_and_identity=True,
            canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
            ps2_loss_resync_candidate_included=False, gameplay_ipc=None), stream, indent=2)
    print('Current CPU cold Quake prepared; no run launched. Win95 helper is resource-only.', flush=True)


if __name__ == '__main__': main()
