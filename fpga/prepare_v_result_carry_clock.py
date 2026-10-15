"""Prepare a read-only, single-owner clock audit; never launch or retry CAD.

The original timing Tcl and resource/process lifetime remain byte-identical.
The current FPGA wrapper also adds AUX/mouse relative to the last synthesized
parent, so its timing/area delta cannot isolate the V-result change.
"""
import ast
import hashlib
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
MANIFEST = '716dab7ee8801e5f865699f2b8619ae881b9d442feb4d59b42399abea758c77e'
MODEL = 'b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'
TEMPLATES = {
    'run.py': 'e2c607958193a40d4a26db360cae35761129b22e07ba0296346de914595f88e7',
    'audit_closed.py': '5bce1d62d8ac5d304b3d763f67fbb71e82132b33d6eb9856e96e8ec0f8d5c5ae',
    'audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def guarded(new, old):
    boundary = 'owner = None\n'
    assert new[new.index(boundary):] == old[old.index(boundary):]
    a, b = 'host = available()\n', "(root/'once').mkdir()"
    assert new[new.index(a):new.index(b)] == old[old.index(a):old.index(b)]
    for invariant in ("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G'",
                      "'15m'", "VEN_FPGA_JOBS='1'", "VEN_FPGA_CORE_MHZ='40'",
                      "assert json.loads((synthesis/'audit.json').read_text())['passed']"):
        assert invariant in new


def derive(original):
    assert set(original) == set(TEMPLATES)
    for n, h in TEMPLATES.items():
        assert hashlib.sha256(original[n].encode()).hexdigest() == h, n
    old = original['run.py']
    run = old
    for before, after in (
        ("source = root.parent/'pipe-wait-fpga-r1'", "source = root.parent/'v-result-carry-fpga-r1'"),
        ("synthesis = root.parent/'pipe-wait-synthesis-r1'", "synthesis = root.parent/'v-result-carry-synthesis-r3'"),
        (str(ROOT/'demand-size-synthesis-r1'), str(ROOT/'pipe-wait-synthesis-r1')),
        ('5ebc7472c4130f7939e0673d78df53a5fee378bc7d7da2adbd4d740bd471cfd5',
         '1d9d3641ebe12b64f66e4b00f7dccd0da9a5b3c4f4de99d4116257a4cb02d30c'),
        ('ventium-pipe-wait-clock-oct15-r1.service', 'ventium-v-result-carry-clock-oct15-r1.service'),
        ('ventium-pipe-wait-synth-oct15-r1.service', 'ventium-v-result-carry-synth-oct15-r3.service'),
        ("manifest['simulator_sha256'] == model",
         "manifest['simulator_sha256'] is None and manifest['processor_platform_simulator_sha256'] == model"),
        ("manifest['variant'] == 'pipe_wait_read_ack_timing'", "manifest['variant'] == 'v_result_carry_aux_mouse_unqualified'"),
        ("len(manifest['files']) == 190", "len(manifest['files']) == 192"),
        ("root.parent/'pipe-wait-lint-r1/closed.json'", "root.parent/'v-result-carry-lint-r1/closed.json'"),
        ("generic_gate='FUNC 108/108 with existing masks; cycle/fault gates remain red; CPU lint only, not full SoC or suite'",
         "generic_gate='Canonical native exit 2 retained; 108 same-input architectural streams and 20 cycle streams identical; CPU lint only, not full SoC or suite'"),
    ):
        run = replace(run, before, after)
    run = replace(run, "pins = dict(freeze['input_pins'])",
        "assert manifest_sha == '"+MANIFEST+"' and model == '"+MODEL+"'\n"
        "pins = dict(freeze['input_pins'])\n"
        "prepared_path = root.parent/'v-result-carry-clock-prepared-r1.json'\n"
        "prepared = json.loads(prepared_path.read_text())\n"
        "pins.update(prepared['template_pins']); pins.update(prepared['outputs'])\n"
        "pins[str(prepared_path)] = sha(prepared_path)")
    guarded(run, old)
    audit = replace(original['audit_closed.py'], 'ventium-pipe-wait-clock-oct15-r1.service',
                    'ventium-v-result-carry-clock-oct15-r1.service')
    audit = replace(audit, 'parent_worst - (-2.874)', 'parent_worst - (-1.350)')
    audit = replace(audit, 'physical_frequency_mhz=None, routed=False,',
        'physical_frequency_mhz=None, routed=False, isolated_v_result_gain=False,\n'
        "    comparison_scope='V-result carry cut plus AUX ownership and mouse-wrapper integration',")
    result = {'run.py': run, 'audit_closed.py': audit, 'audit.tcl': original['audit.tcl']}
    for n in ('run.py', 'audit_closed.py'):
        ast.parse(result[n], filename=n)
    return result


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    assert sha(ROOT/'v-result-carry-fpga-r1/input-manifest.json') == MANIFEST
    destination = ROOT/'v-result-carry-clock-r1'
    receipt = ROOT/'v-result-carry-clock-prepared-r1.json'
    assert not destination.exists() and not receipt.exists()
    original = {n: (ROOT/'pipe-wait-clock-r1'/n).read_text() for n in TEMPLATES}
    output = derive(original)
    pins = {str(ROOT/'pipe-wait-clock-r1'/n): h for n, h in TEMPLATES.items()}
    for p in (Path(__file__).resolve(), Path(__file__).with_name('prepare_fragment_exact_timing.py').resolve()):
        pins[str(p)] = sha(p)
    destination.mkdir()
    for n, text in output.items():
        with (destination/n).open('x') as f:
            f.write(text)
    result = dict(prepared_not_launched=True, resource_guards_unchanged=True, tcl_unchanged=True,
        source_manifest_sha256=MANIFEST, model_sha256=MODEL, template_pins=pins,
        outputs={str(destination/n): sha(destination/n) for n in output},
        synthesis_directory='v-result-carry-synthesis-r3', isolated_v_result_gain=False,
        routed=False, hardware_acceptance=False, standard_suite=False, gameplay_ipc=None)
    with receipt.open('x') as f:
        json.dump(result, f, indent=2)
    print('Read-only clock controllers prepared, not launched; synthesis must first close and pass its audit.')


if __name__ == '__main__':
    main()
