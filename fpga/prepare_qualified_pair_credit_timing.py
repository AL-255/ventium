"""Prepare matched diagnostic synthesis/clock controllers; launch nothing.

The old native process/resource guards, mapper, timing Tcl and clocks remain
exact. The fresh functional gate is green but cycle bands remain failed; this
measurement cannot grant routing, deployment or standard-suite acceptance.
"""
import ast
import json
import os
from pathlib import Path

import qualified_pair_credit_timing_evidence as evidence
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded as synth_guarded
from prepare_v_result_carry_clock import guarded as clock_guarded
from prepare_system_read_ack_timing import TEMPLATES

ROOT=evidence.ROOT
SOURCE,SYNTH,CLOCK=('qualified-pair-credit-fpga-r1','qualified-pair-credit-synthesis-r1',
                    'qualified-pair-credit-clock-r1')
RECEIPT='qualified-pair-credit-timing-prepared-r1.json'
PARENT_DCP='2af6ae8a36eb11fd122f9519b4c2400f66603694f21ce08387fce06a30a2db60'
GATE=('Explicit qualified-reference make verify: 108/108 functional, nine cycle-band failures, '
      'native exit2 retained. All 20 same-model cycle streams unchanged. Strict CPU lint only; '
      'not full SoC, standard suite, routed timing or physical acceptance.')


def common(text):
    for before,after in (
        ('raw-prime-storage-','qualified-pair-credit-'),
        ('raw_prime_storage_','qualified_pair_credit_'),
        (evidence.export.PARENT,evidence.MANIFEST),
        (evidence.export.native.PARENT_MODEL,evidence.MODEL),
        ('baseline_gameplay_ipc=0.50229051,baseline_window=[1400065247,1500065247]',
         'baseline_gameplay_ipc=0.497040387,baseline_window=[1100065247,2100065247]'),
    ):text=text.replace(before,after)
    return text.replace('Canonical native exit2 retained; fresh private-reference 108/108 under existing masks, 105 unmasked, all 20 parent cycle streams identical. Strict CPU lint only, not full SoC or standard suite.',GATE)


def proof(phase):
    leaf='launch_checked.tcl' if phase=='synthesis' else 'audit.tcl'
    return f'''import sys
sys.path.insert(0,str(repo/'fpga'))
import qualified_pair_credit_timing_evidence as evidence
assert manifest_sha==evidence.MANIFEST and model==evidence.MODEL
pins=evidence.check(source)
prepared_path=root.parent/{RECEIPT!r}
prepared=json.loads(prepared_path.read_text())
assert prepared['unchanged_guard_lifecycle'] and prepared['controllers_generated_not_launched']
assert prepared['source_manifest_sha256']==manifest_sha and prepared['model_sha256']==model
pins.update(prepared['template_pins']);pins.update(prepared['outputs'])
for path in (prepared_path,Path(__file__).resolve(),root/{leaf!r},lint_file,
             repo/'fpga/run_vivado_exclusive.sh',repo/'tools/build_scope.sh'):
    pins[str(path)]=sha(path)
assert all(sha(p)==h for p,h in pins.items())
'''


def derive(original):
    output={}
    old=original['raw-prime-storage-synthesis-r1/run.py'];text=common(old)
    text=replace(text,'Measure RAW retained-storage removal plus input repairs; no route or deployment.',
                 'Measure qualified paired-store enqueue only; no route or deployment.')
    text=span(text,"pins = dict(freeze['input_pins'])",'host = available()\n',proof('synthesis'))
    text=span(text,'    rationale=','    generic_gate=',
        '    rationale='+repr('Measure the exact two-file enqueue cofactor against the RAW/input parent. '
        'Fresh actual make verify is functional-green with nine unchanged failed cycle bands; '
        'all 20 same-model cycle streams identical. Directed faults, same-edge boundaries, '
        'generic/CDC exclusions, cold input and unchanged short CoreMark checks retained. '
        'No reference/mask/timing waiver, extra pipeline stage or mode change. '
        'Same 159 defines, mapper and 40/100 MHz constraints. Diagnostic synthesis only.')+',\n')
    synth_guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    output[SYNTH+'/run.py']=text
    audit=common(original['raw-prime-storage-synthesis-r1/audit_closed.py'])
    for before,after in (
        ('sfetch-boundary-synthesis-r1','raw-prime-storage-synthesis-r1'),
        ('sfetch-boundary-fpga-r1','raw-prime-storage-fpga-r1'),
        ('34b2d154d926cd8731443576b7e786cabf2c70bd193d2d05c8e5b0505b37bafc',evidence.export.PARENT),
        ('RAW-storage and retained-input composition','qualified paired-store enqueue cofactor'),
    ):audit=replace(audit,before,after)
    manifest=json.loads((ROOT/SOURCE/'input-manifest.json').read_text())
    changes={r['frozen']:r['sha256'] for r in manifest['files'] if r['frozen'] in evidence.export.CHANGES}
    assert sorted(changes)==evidence.export.CHANGES
    audit=span(audit,'expected_changes=','assert set(changed)',f'expected_changes={changes!r}\n')
    output[SYNTH+'/audit_closed.py']=audit
    output[SYNTH+'/launch_checked.tcl']=original['raw-prime-storage-synthesis-r1/launch_checked.tcl']
    old=original['raw-prime-storage-clock-r1/run.py'];text=common(old)
    text=replace(text,'sfetch-boundary-synthesis-r1','raw-prime-storage-synthesis-r1')
    text=replace(text,'cdfd1aebe93772078decc21741296b136908179f316b23393419e2971db5119c',PARENT_DCP)
    text=span(text,"pins = dict(freeze['input_pins'])",'prior_closed =',proof('clock'))
    clock_guarded(text,old)
    output[CLOCK+'/run.py']=text
    audit=common(original['raw-prime-storage-clock-r1/audit_closed.py'])
    audit=replace(audit,'parent_worst - (-2.050)','parent_worst - (-3.269)')
    audit=replace(audit,
        'RAW retained-storage removal plus retained controller and keyboard retry; boundary-stage and posted mouse wrapper unchanged',
        'Only the qualified paired-store enqueue cofactor; RAW/input parent, mapper, clocks and all definitions unchanged')
    output[CLOCK+'/audit_closed.py']=audit
    output[CLOCK+'/audit.tcl']=original['raw-prime-storage-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    pins=evidence.check();original={}
    for name,digest in TEMPLATES.items():
        p=ROOT/name;assert sha(p)==digest;original[name]=p.read_text();pins[str(p)]=digest
    for p in (Path(__file__).resolve(),Path(evidence.__file__).resolve(),
              Path(evidence.export.__file__).resolve(),
              Path(__file__).with_name('prepare_system_read_ack_timing.py'),
              Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py'),
              Path(__file__).with_name('prepare_v_result_carry_clock.py')):
        pins[str(p)]=sha(p)
    output=derive(original)
    assert not (ROOT/RECEIPT).exists() and all(not (ROOT/n).exists() for n in output)
    for name,text in output.items():
        p=ROOT/name;p.parent.mkdir(exist_ok=True)
        with p.open('x') as f:f.write(text)
    result=dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
        template_pins=pins,outputs={str(ROOT/n):sha(ROOT/n) for n in output},
        source_manifest_sha256=evidence.MANIFEST,model_sha256=evidence.MODEL,
        historical_source_aliases={n:dict(sha256=v[0],archive=str(v[1])) for n,v in evidence.ALIASES.items()},
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (ROOT/RECEIPT).open('x') as f:json.dump(result,f,indent=2)
    print('Matched pair-credit synthesis/clock controllers prepared; not launched.')


if __name__=='__main__':main()
