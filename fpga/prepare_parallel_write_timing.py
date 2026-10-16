"""Prepare matched synthesis/clock controllers with unchanged resource guards.

Only source/proof identities and the reported experiment rationale change.
No mapper, clock, timing waiver, process-lifecycle or admission-floor change.
Preparation does not launch CAD and cannot grant routed or guest acceptance.
"""
import inspect
import json
import os
from pathlib import Path

import parallel_write_timing_evidence as evidence
import prepare_qualified_pair_credit_timing as template

ROOT = evidence.ROOT
SOURCE, SYNTH, CLOCK = ('parallel-write-fpga-r1', 'parallel-write-synthesis-r1',
                        'parallel-write-clock-r1')
RECEIPT = 'parallel-write-timing-prepared-r1.json'
TEMPLATES, PARENT_DCP = template.TEMPLATES, template.PARENT_DCP
sha, replace, span = template.sha, template.replace, template.span
GATE = ('Canonical make verify remains failed: native exit2, 7/108 functional, nine failed cycle bands. '
        'Private qualified-reference 108/108 under unchanged masks, 105 unmasked. All 108 same-input '
        'functional streams and 20 cycle streams parent-identical. Strict CPU lint only; '
        'not full SoC, standard suite, routed timing or physical acceptance.')


def common(text):
    for before, after in (
        ('raw-prime-storage-', 'parallel-write-'),
        ('raw_prime_storage_', 'parallel_write_admission_'),
        (evidence.export.PARENT, evidence.MANIFEST),
        (evidence.native.PARENT_MODEL, evidence.MODEL),
        ('baseline_gameplay_ipc=0.50229051,baseline_window=[1400065247,1500065247]',
         'baseline_gameplay_ipc=0.497040387,baseline_window=[1100065247,2100065247]'),
    ):
        text = text.replace(before, after)
    return text.replace('Canonical native exit2 retained; fresh private-reference 108/108 under existing masks, 105 unmasked, all 20 parent cycle streams identical. Strict CPU lint only, not full SoC or standard suite.', GATE)


def proof(phase):
    scope = dict(template.__dict__, ROOT=ROOT, RECEIPT=RECEIPT)
    exec(compile(inspect.getsource(template.proof), __file__, 'exec'), scope)
    return replace(scope['proof'](phase), 'import qualified_pair_credit_timing_evidence as evidence',
                   'import parallel_write_timing_evidence as evidence')


def derive(original):
    assert sha(Path(template.__file__)) == '2da4194547319318f0f59acf674179d88bd397059fc261cb6594192b154e4475'
    scope = dict(template.__dict__, evidence=evidence, ROOT=ROOT, SOURCE=SOURCE,
                 SYNTH=SYNTH, CLOCK=CLOCK, PARENT_DCP=PARENT_DCP, GATE=GATE,
                 common=common, proof=proof)
    exec(compile(inspect.getsource(template.derive), __file__, 'exec'), scope)
    output = scope['derive'](original)
    # Correct descriptive text only; the complete resource/lifecycle block and
    # Tcl must still equal the measured RAW/input parent's native controllers.
    name = SYNTH+'/run.py'
    output[name] = replace(output[name], 'Measure qualified paired-store enqueue only; no route or deployment.',
                           'Measure parallel write admission only; no route or deployment.')
    rationale = ('Measure independent payload-only single/pair admission selected by late request controls. '
        'Exact two-file RAW/input derivative, unchanged generic credit and cycle latency. '
        '180 native system runs, 108 same-input functional streams, 20 cycle streams, cold input and '
        'both short CoreMark CRC controls are parent-identical. Canonical make verify remains failed. '
        'Same 159 defines, mapper and 40/100 MHz clocks. No route, score or hardware acceptance.')
    output[name] = span(output[name], '    rationale=', '    generic_gate=',
                        '    rationale='+repr(rationale)+',\n')
    for name in (SYNTH+'/audit_closed.py', CLOCK+'/audit_closed.py'):
        output[name] = output[name].replace('qualified paired-store enqueue cofactor', 'parallel write-admission cut')
    template.synth_guarded(output[SYNTH+'/run.py'], original['raw-prime-storage-synthesis-r1/run.py'])
    template.clock_guarded(output[CLOCK+'/run.py'], original['raw-prime-storage-clock-r1/run.py'])
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    pins = evidence.check(); original = {}
    for name, digest in TEMPLATES.items():
        path = ROOT/name
        assert sha(path) == digest
        original[name] = path.read_text(); pins[str(path)] = digest
    for path in (Path(__file__).resolve(), Path(evidence.__file__).resolve(),
                 Path(evidence.export.__file__).resolve(), Path(template.__file__).resolve(),
                 Path(__file__).with_name('prepare_system_read_ack_timing.py'),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_v_result_carry_clock.py')):
        pins[str(path)] = sha(path)
    output = derive(original)
    assert not (ROOT/RECEIPT).exists() and all(not (ROOT/name).exists() for name in output)
    for name, text in output.items():
        path = ROOT/name; path.parent.mkdir(exist_ok=True)
        with path.open('x') as stream: stream.write(text)
    result = dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
        template_pins=pins, outputs={str(ROOT/name):sha(ROOT/name) for name in output},
        source_manifest_sha256=evidence.MANIFEST, model_sha256=evidence.MODEL,
        historical_source_aliases={n:dict(sha256=v[0],archive=str(v[1])) for n,v in evidence.ALIASES.items()},
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    with (ROOT/RECEIPT).open('x') as stream: json.dump(result, stream, indent=2)
    print('Matched parallel-admission synthesis/clock controllers prepared; not launched.')


if __name__ == '__main__': main()
