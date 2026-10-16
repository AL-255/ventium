"""Prepare matched fetch-cofactor synthesis/clock controllers; launch nothing.

Keep the measured-parent disk admission, exclusive Vivado owner and native
cleanup unchanged. The parent estimate is 36.968577 MHz, not routed sign-off.
"""
import ast
import json
import os
from pathlib import Path

import sfetch_interior_evidence as evidence
import prepare_sfetch_boundary_timing as previous
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded as synth_guarded
from prepare_v_result_carry_clock import guarded as clock_guarded

ROOT = previous.ROOT
SOURCE, SYNTH, CLOCK = ('sfetch-interior-fpga-r1','sfetch-interior-synthesis-r1','sfetch-interior-clock-r1')
RECEIPT = 'sfetch-interior-timing-prepared-r1.json'
TEMPLATES = previous.TEMPLATES


def common(text):
    for old, new in (
        ('backing-direction-', 'sfetch-interior-'),
        ('backing_direction_', 'sfetch_interior_'),
        (previous.evidence.previous.MANIFEST, evidence.MANIFEST),
        (previous.evidence.previous.MODEL, evidence.MODEL),
        ('posted-mouse-synthesis-r1', 'sfetch-boundary-synthesis-r1'),
        ('v-result-carry-posted-mouse-fpga-r1', 'sfetch-boundary-fpga-r1'),
        (evidence.parent_evidence.previous.mouse.MANIFEST, evidence.parent_evidence.MANIFEST),
        ('9354b17d35b1c0cb4a49bf1bcd00cf6e511b8253c5b250b427d10e6764741315',
         'cdfd1aebe93772078decc21741296b136908179f316b23393419e2971db5119c'),
        ('baseline_gameplay_ipc=0.48146083,baseline_window=[1100065247,1200065247]',
         'baseline_gameplay_ipc=0.49046518,baseline_window=[1600065247,1700065247]'),
    ):
        text = text.replace(old, new)
    return text


def derive(original):
    output = {}
    old = original['backing-direction-synthesis-r1/run.py']; text = common(old)
    text = replace(text, 'Measure V-result carry cut with current AUX/mouse; no route or deployment.',
                   'Measure cycle-neutral interior fetch-size cofactor; no route or deployment.')
    text = span(text, "matched=load_proof('sfetch-interior-matched-r1/closed.json')",
        "pc=load_proof('sfetch-interior-soc-r1/build-closed.json')",
        "functional=load_proof('sfetch-interior-func-r1/audit.json')\n"
        "assert functional['passed'] and functional['model']==native.CORE_MODEL\n"
        "assert functional['functional_passes']==108 and functional['functional_records']==80800\n"
        "assert functional['unmasked_functional_passes']==105 and not functional['canonical_gate_passed']\n"
        "pins.update(functional['pins']);pins.update(functional['artifacts'])\n")
    text = replace(text, "[r['ticks'] for r in cm['results']]==[4767218,4753406]",
                   "[r['ticks'] for r in cm['results']]==[4771298,4755366]")
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='One exact interior fetch-size output cofactor against the boundary-stage parent. "
        "Same 159 defines, full source closure, corrected wrapper, mapper and 40/100 MHz constraints. "
        "No added registers/cycles/ports; binary proof, boundary/interior traces and short cold CRC controls pass. "
        "Canonical FAIL retained. Timing diagnosis only; no route, suite or physical acceptance.',\n")
    policy = "    generic_gate='Canonical native exit2 retained; fresh private-reference 108/108 under existing masks, 105 unmasked, all 20 parent cycle streams identical. Strict CPU lint only, not full SoC or standard suite.',\n"
    text = span(text, '    generic_gate=', '    hardware_acceptance=', policy)
    synth_guarded(text, old)
    a, b = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)] == old[old.index(a):old.index(b)]
    output[SYNTH+'/run.py'] = text
    audit = common(original['backing-direction-synthesis-r1/audit_closed.py'])
    manifest = json.loads((ROOT/SOURCE/'input-manifest.json').read_text())
    changes = {r['frozen']:r['sha256'] for r in manifest['files'] if r['frozen'] in evidence.export.CHANGES}
    assert sorted(changes) == evidence.export.CHANGES
    audit = span(audit, 'expected_changes=', 'assert set(changed)', f'expected_changes={changes!r}\n')
    audit = replace(audit, 'V-result cut plus current AUX/mouse integration', 'single-core interior fetch-size cofactor')
    output[SYNTH+'/audit_closed.py'] = audit
    output[SYNTH+'/launch_checked.tcl'] = original['backing-direction-synthesis-r1/launch_checked.tcl']
    old = original['backing-direction-clock-r1/run.py']; text = common(old)
    text = span(text, '    generic_gate=', '    hardware_acceptance=', policy)
    clock_guarded(text, old)
    assert text[text.index(a):text.index(b)] == old[old.index(a):old.index(b)]
    output[CLOCK+'/run.py'] = text
    audit = common(original['backing-direction-clock-r1/audit_closed.py'])
    audit = replace(audit, 'parent_worst - (-3.858)', 'parent_worst - (-2.050)')
    audit = replace(audit, 'Only early inactive L1 backing direction; corrected AUX/mouse wrapper unchanged',
                    'Only interior fetch-size cofactor; boundary-stage and corrected wrapper unchanged')
    output[CLOCK+'/audit_closed.py'] = audit
    output[CLOCK+'/audit.tcl'] = original['backing-direction-clock-r1/audit.tcl']
    for name, text in output.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    pins = evidence.check(ROOT/SOURCE); original = {}
    for name, digest in TEMPLATES.items():
        p = ROOT/name; assert sha(p) == digest; original[name] = p.read_text(); pins[str(p)] = digest
    for module in (evidence,previous):
        path = Path(module.__file__).resolve(); pins[str(path)] = sha(path)
    for name in ('prepare_sfetch_interior_timing.py','prepare_fragment_exact_timing.py',
                 'prepare_payload_current_synthesis.py','prepare_v_result_carry_clock.py'):
        p = Path(__file__).with_name(name).resolve(); pins[str(p)] = sha(p)
    output = derive(original)
    assert not (ROOT/RECEIPT).exists() and all(not (ROOT/n).exists() for n in output)
    for name, text in output.items():
        p = ROOT/name; p.parent.mkdir(exist_ok=True)
        with p.open('x') as stream: stream.write(text)
    result = dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
        template_pins=pins,outputs={str(ROOT/n):sha(ROOT/n) for n in output},
        source_manifest_sha256=evidence.MANIFEST,model_sha256=evidence.MODEL,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (ROOT/RECEIPT).open('x') as stream: json.dump(result,stream,indent=2)
    print('Matched interior-fetch synthesis/clock controllers prepared, not launched.')


if __name__ == '__main__': main()
