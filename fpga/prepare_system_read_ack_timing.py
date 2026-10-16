"""Prepare matched timing measurement of the nine-file system ACK cut.

Keep the native mapper, clocks, resource admission and process lifecycle exact.
Only the candidate identity, closed proof admission and immediate parent change.
Preparation launches no CAD; canonical, guest and hardware acceptance stay false.
"""
import ast
import json
import os
from pathlib import Path

import system_read_ack_evidence as evidence
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded as synth_guarded
from prepare_v_result_carry_clock import guarded as clock_guarded

ROOT=evidence.native.ROOT
SOURCE,SYNTH,CLOCK=('system-read-ack-fpga-r1','system-read-ack-synthesis-r1','system-read-ack-clock-r1')
RECEIPT='system-read-ack-timing-prepared-r1.json'
PARENT_DCP='2af6ae8a36eb11fd122f9519b4c2400f66603694f21ce08387fce06a30a2db60'
TEMPLATES={
    'raw-prime-storage-synthesis-r1/run.py':'6c1c1f3841cfa1eb9fce105cce6e1bc682526035edd2bf0e6521303119760fda',
    'raw-prime-storage-synthesis-r1/audit_closed.py':'961800f9ed1621f7ef123ac25af5a1c100a7b32dd270bd95b759b402eee56faa',
    'raw-prime-storage-synthesis-r1/launch_checked.tcl':'725abb0abf9758d6bcec583ef1209b9213797eb371efcf8733d91a0518c200e7',
    'raw-prime-storage-clock-r1/run.py':'fcc50adf900a62184c28a462e116f5d897919aee3c0efce5c4df807c55b879f1',
    'raw-prime-storage-clock-r1/audit_closed.py':'25e494a2159555f22d5f209685d8e0d5f30c251a694062f70c1f7d7722bc9f09',
    'raw-prime-storage-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
GATE='Canonical native exit 2 retained. All 108 same-input functional streams and all 20 cycle streams parent-identical without new masks. Strict CPU lint only, not full SoC or standard suite.'


def common(text):
    for before,after in (
        ('raw-prime-storage-','system-read-ack-'),
        ('raw_prime_storage_','system_read_ack_'),
        (evidence.export.PARENT,evidence.MANIFEST),
        (evidence.native.PARENT_MODEL,evidence.MODEL),
    ):text=text.replace(before,after)
    return text.replace('Canonical native exit2 retained; fresh private-reference 108/108 under existing masks, 105 unmasked, all 20 parent cycle streams identical. Strict CPU lint only, not full SoC or standard suite.',GATE)


def derive(original):
    output={}
    old=original['raw-prime-storage-synthesis-r1/run.py'];text=common(old)
    text=replace(text,'Measure RAW retained-storage removal plus input repairs; no route or deployment.',
                 'Measure only the system read ACK cut; no route or deployment.')
    text=replace(text,"prepared['changes']==[native.recipe.FILE]","prepared['changes']==native.CHANGES")
    text=replace(text,'native.recipe.transform(before)',
                 'native.recipe.transform(before,name.removeprefix(native.recipe.PREFIX))')
    text=span(text,"functional=load_proof('system-read-ack-func-r1/audit.json')",'pc=load_proof(',
        "functional=load_proof('system-read-ack-canonical-audit-r1.json')\n"
        "assert functional['parent_identical'] and functional['same_input_parent_replay']\n"
        "assert functional['native_gate_exit']==2 and not functional['canonical_gate_passed']\n"
        "assert len(functional['rows'])==128 and all(r['same_records'] for r in functional['rows'])\n"
        "assert sum(r['records'] for r in functional['rows'] if r['mode']=='func')==80800\n"
        "pins.update(functional['pins'])\n")
    rationale=('Cut write-admission feedback only from read owners. All 19 cold system cases, '
        '108 same-input functional streams and 20 cycle streams are parent-identical. '
        'Exact nine-file delta; unchanged 159 defines, input devices, posted mouse wrapper, '
        'mapper and 40/100 MHz constraints. Cold keyboard and both short CoreMark CRC controls pass '
        'with unchanged clocks. Canonical gates remain failed; no route, score, guest or physical acceptance.')
    text=span(text,'    rationale=','    generic_gate=','    rationale='+repr(rationale)+',\n')
    synth_guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    output[SYNTH+'/run.py']=text

    audit=common(original['raw-prime-storage-synthesis-r1/audit_closed.py'])
    for before,after in (
        ('sfetch-boundary-synthesis-r1','raw-prime-storage-synthesis-r1'),
        ('sfetch-boundary-fpga-r1','raw-prime-storage-fpga-r1'),
        ('34b2d154d926cd8731443576b7e786cabf2c70bd193d2d05c8e5b0505b37bafc',evidence.export.PARENT),
        ('RAW-storage and retained-input composition','nine-file system read ACK cut'),
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
    clock_guarded(text,old)
    output[CLOCK+'/run.py']=text
    audit=common(original['raw-prime-storage-clock-r1/audit_closed.py'])
    audit=replace(audit,'parent_worst - (-2.050)','parent_worst - (-3.269)')
    audit=replace(audit,
        'RAW retained-storage removal plus retained controller and keyboard retry; boundary-stage and posted mouse wrapper unchanged',
        'Only nine-file system read ACK cut; RAW storage, boundary-stage, retained input devices and posted mouse wrapper unchanged')
    output[CLOCK+'/audit_closed.py']=audit
    output[CLOCK+'/audit.tcl']=original['raw-prime-storage-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    pins=evidence.check(ROOT/SOURCE);original={}
    for name,digest in TEMPLATES.items():
        p=ROOT/name;assert sha(p)==digest;original[name]=p.read_text();pins[str(p)]=digest
    for p in (Path(__file__).resolve(),Path(evidence.__file__).resolve(),
              Path(evidence.export.__file__).resolve(),Path(evidence.native.__file__).resolve(),
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
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (ROOT/RECEIPT).open('x') as f:json.dump(result,f,indent=2)
    print('Matched system ACK synthesis and clock controllers prepared; not launched.')


if __name__=='__main__':main()
