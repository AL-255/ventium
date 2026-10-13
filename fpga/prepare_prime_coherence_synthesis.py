"""Prepare the commit-cofactor timing experiment; do not launch Vivado.

Keep the matched logic-only mapper, resource watchdog and 40/100 MHz clocks.
The control is the closed 32.270556344 MHz FP-WIDE-CONTEXT synthesized netlist.
Canonical failure is explicit; no FPGA acceptance is inferred.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_prime_coherence_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST = '6c60993a794d840af5e97398f7379754a8a4a2a2dc0aeff8ef6f0f582cc18e06'
PARENT_DCP = '7e479811aac60c6c900c62f2d519fc36c010c25844a2cb130a259acdcb97c86e'
TEMPLATES = {
    'fp-wide-context-synthesis-r1/run.py': '2cae6a8dd423a622b54b2288a37df0c058e3ad47cf3b4cf1a60b420a48e07dc2',
    'fp-wide-context-clock-r1/run.py': '51eda6b32b079f1e8dbd9b3cdedbd9059181a142271614b605cd0ab4c547b1fc',
    'fp-wide-context-synthesis-r1/audit_closed.py': '95b346d8cce69f4b0c0d8beca4c689bbdba8b95f10479c55cd24fb93fb60f172',
    'fp-wide-context-clock-r1/audit_closed.py': 'ce0efb96ba69e24c40e186cbf924f4683e6ca920ddd5a79859f14b650efd9ae3',
    'fp-wide-context-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original, changes):
    assert changes == {'ventium/'+n: native.recipe.CHILDREN[n] for n in native.CHANGES}
    result = {}
    for phase in ('synthesis', 'clock'):
        name = 'fp-wide-context-'+phase+'-r1/run.py'
        text = original[name].replace('fp-wide-context-', 'prime-coherence-')
        text = replace(text, "manifest['variant'] == 'fp_wide_context_timing'",
                       "manifest['variant'] == 'prime_coherence_timing'")
        if phase == 'synthesis':
            text = replace(text, '0a6bbdb15f7ed7994641ab7ea1934a0d830b5f50d857853e5bbea29140a18e4f', native.CORE_MODEL)
            text = replace(text,
                "changes=['rtl/core/core.sv', 'rtl/mem/ven_l1d.sv', 'rtl/mem/ventium_l1_axi.sv', 'rtl/ventium_top.sv']",
                'changes='+repr(native.CHANGES))
            # Two changes versus the native MC-local parent, but three versus
            # the earlier PC/hardware parent. Never drop the first cofactor.
            text = replace(text, "assert core['changes']==changes and len(core['definitions'])==152",
                "assert core['changes']=="+repr(native.recipe.hint.CHANGES)+" and len(core['definitions'])==152")
            text = replace(text, 'source-matched FP-only contextual wide response',
                           'source-matched local commit and no-memory hint cofactors')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Remove unrelated AGI/ref commits from pipeline owner acceptance and impossible live own-store snoop feedback from no-memory hint commits. Sticky poison and external invalidation remain. Same logic-only mapper, UV+fast/full P5 caches and original 40/100 MHz clocks. Matched FP-WIDE-CONTEXT control is 32.270556344 MHz. Canonical remains FAIL; no route, board or timing pass inherited.',\n")
        else:
            text = replace(text, str(ROOT/'payload-region-synthesis-r1'), str(ROOT/'fp-wide-context-synthesis-r1'))
            text = replace(text, 'cb4d787acf141663525776e7865af81e80bc585fbbcf9885efaa72ea65e828fd', PARENT_DCP)
        guarded(text, original[name])
        result['prime-coherence-'+phase+'-r1/run.py'] = text
    text = original['fp-wide-context-synthesis-r1/audit_closed.py'].replace('fp-wide-context-', 'prime-coherence-')
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/('payload-region-'+suffix)), str(ROOT/('fp-wide-context-'+suffix)))
    text = replace(text, '5e5bdf083c4d2ba7f678a2fd46f9dab794d15fd1a286cc904497fdc6eb503603', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, 'Audit the four tested FP contextual files', 'Audit the three tested commit-cofactor headers')
    result['prime-coherence-synthesis-r1/audit_closed.py'] = text
    text = original['fp-wide-context-clock-r1/audit_closed.py'].replace('fp-wide-context-', 'prime-coherence-')
    result['prime-coherence-clock-r1/audit_closed.py'] = replace(text, '(-4.314)', '(-5.988)')
    result['prime-coherence-clock-r1/audit.tcl'] = original['fp-wide-context-clock-r1/audit.tcl']
    for name, text in result.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    source = root/'prime-coherence-fpga-r1'
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant'] == 'prime_coherence_timing' and manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    pc = root/'prime-coherence-soc-r1'
    closed = json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit'] == 0
    model = sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model == closed['binary_sha256'] == manifest['simulator_sha256']
    changes = {name: sha(source/name) for name in manifest['changed_parent_payloads']}
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = root/name
        assert sha(path) == digest
        original[name] = path.read_text(); pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),
                 Path(native.recipe.local.__file__), Path(native.recipe.hint.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py')):
        pins[str(path)] = sha(path)
    output = derive(original, changes)
    receipt = root/'prime-coherence-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name, text in output.items():
        path = root/name; path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'), model_sha256=model,
            canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
            fmax_mhz=None, gameplay_ipc=None), stream, indent=2)
    print('Prepared guarded commit-cofactor synthesis/timing controllers; nothing launched.', flush=True)


if __name__ == '__main__': main()
