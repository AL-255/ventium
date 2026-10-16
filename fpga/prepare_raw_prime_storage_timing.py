"""Prepare one matched RAW-storage/input synthesis and read-only clock audit.

The baseline is the faster boundary-stage parent. All native resource guards,
mapper, 40/100 MHz clocks, owner checks and cleanup stay unchanged. Three
reviewed deltas are measured together; no isolated area/timing gain is claimed.
"""
import ast
import json
import os
from pathlib import Path

import raw_prime_storage_evidence as evidence
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded as synth_guarded
from prepare_v_result_carry_clock import guarded as clock_guarded

ROOT = evidence.native.ROOT
SOURCE, SYNTH, CLOCK = ('raw-prime-storage-fpga-r1','raw-prime-storage-synthesis-r1','raw-prime-storage-clock-r1')
RECEIPT = 'raw-prime-storage-timing-prepared-r1.json'
TEMPLATES = {
    'prime-width-synthesis-r1/run.py':'d7a62d2daf590036bf495755e48d0537b58a95a2e1982de84b6bc8eb36445ba4',
    'prime-width-synthesis-r1/audit_closed.py':'6cee3373441b92454c412622dc2f5b5f59a6ba1a5b6894296cd78df27b20b49c',
    'prime-width-synthesis-r1/launch_checked.tcl':'725abb0abf9758d6bcec583ef1209b9213797eb371efcf8733d91a0518c200e7',
    'prime-width-clock-r1/run.py':'bc2fed0e6d0aadd8812ecbea457a366844018db8d8b884cd301b228e98aa12ee',
    'prime-width-clock-r1/audit_closed.py':'50a212c2b34fd5a3821bd41ab4e7eb7b36d6cb7f3d0d1f9e3c284ba8b5c3be77',
    'prime-width-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def common(text):
    for old,new in (
        ('prime-width-', 'raw-prime-storage-'),
        ('prime_width_', 'raw_prime_storage_'),
        ('raw_prime_storage_posted_mouse_unqualified', evidence.VARIANT),
        ('dd8d91cba48f87f9d780f82c5c5f6d660761b7c204f42b59e35bd75b5045a5ae', evidence.MANIFEST),
        ('cabf2f1198f476de7ec64fd18e179e6a1c2f57dc9ceeee6883a7f14ee3f9096d', evidence.MODEL),
        ('baseline_gameplay_ipc=0.51045343,baseline_window=[1200065247,1300065247]',
         'baseline_gameplay_ipc=0.50229051,baseline_window=[1400065247,1500065247]'),
    ):
        text = text.replace(old,new)
    return text


def derive(original):
    output = {}
    old = original['prime-width-synthesis-r1/run.py']; text = common(old)
    for a,b in (
        ('Measure early prime-width payload; no route or deployment.',
         'Measure RAW retained-storage removal plus input repairs; no route or deployment.'),
        ('prepared[\'changes\']==native.CHANGES', 'prepared[\'changes\']==[native.recipe.FILE]'),
        ('pins.update(native.evidence(proof,core))','pins.update(native.evidence())'),
        ('raw-prime-storage-func-r2/audit.json','raw-prime-storage-func-r1/audit.json'),
        ("raw-prime-storage-soc-r1/coremark-r1", "raw-prime-storage-soc-r1/coremark-ui-disabled-r1"),
    ):
        text = replace(text,a,b)
    text = span(text,'    rationale=','    generic_gate=',
        "    rationale='Specialize unreachable retained state in existing RAW mode; exact zero-state source proof and 4240 full parent-identical trace pairs. Compose retained 8042 and tested keyboard retry. Same 159 defines, complete source closure, posted mouse wrapper, mapper and 40/100 MHz constraints. Cold input and unchanged short CoreMark clocks pass. Canonical and historical aggregate gates remain failed. Three deltas measured together, no isolated gain or routing/guest/physical acceptance claimed.',\n")
    synth_guarded(text,old)
    a,b = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)] == old[old.index(a):old.index(b)]
    output[SYNTH+'/run.py'] = text
    audit = common(original['prime-width-synthesis-r1/audit_closed.py'])
    manifest = json.loads((ROOT/SOURCE/'input-manifest.json').read_text())
    changes = {r['frozen']:r['sha256'] for r in manifest['files'] if r['frozen'] in evidence.export.CHANGES}
    assert sorted(changes) == evidence.export.CHANGES
    audit = span(audit,'expected_changes=','assert set(changed)',f'expected_changes={changes!r}\n')
    audit = replace(audit,'single-header early prime-width payload','RAW-storage and retained-input composition')
    # Explicitly require both repaired keyboard blocks in the native input list.
    audit = replace(audit,"'flow/src/ven_ps2_mailbox.sv', 'flow/src/ven_ps2_device.sv'):",
        "'flow/src/ven_ps2_mailbox.sv', 'flow/src/ven_ps2_device.sv',\n"
        "             'flow/src/ven_ps2_kbd_inject.v', 'ventium/3rd-party/ao486_MiSTer/rtl/soc/ps2.v'):")
    output[SYNTH+'/audit_closed.py'] = audit
    output[SYNTH+'/launch_checked.tcl'] = original['prime-width-synthesis-r1/launch_checked.tcl']
    old = original['prime-width-clock-r1/run.py']; text = common(old)
    clock_guarded(text,old)
    assert text[text.index(a):text.index(b)] == old[old.index(a):old.index(b)]
    output[CLOCK+'/run.py'] = text
    audit = common(original['prime-width-clock-r1/audit_closed.py'])
    audit = replace(audit,'Only early prime-width payload; boundary-stage and corrected wrapper unchanged',
                    'RAW retained-storage removal plus retained controller and keyboard retry; boundary-stage and posted mouse wrapper unchanged')
    output[CLOCK+'/audit_closed.py'] = audit
    output[CLOCK+'/audit.tcl'] = original['prime-width-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'): ast.parse(text,filename=name)
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    pins = evidence.check(ROOT/SOURCE); original = {}
    for name,digest in TEMPLATES.items():
        p = ROOT/name; assert sha(p) == digest; original[name] = p.read_text(); pins[str(p)] = digest
    for p in (Path(__file__).resolve(),Path(evidence.__file__).resolve(),
              Path(evidence.export.__file__).resolve(),Path(evidence.native.__file__).resolve(),
              Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py'),
              Path(__file__).with_name('prepare_v_result_carry_clock.py')):
        pins[str(p)] = sha(p)
    output = derive(original)
    assert not (ROOT/RECEIPT).exists() and all(not (ROOT/n).exists() for n in output)
    for name,text in output.items():
        p = ROOT/name; p.parent.mkdir(exist_ok=True)
        with p.open('x') as f: f.write(text)
    result = dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
        template_pins=pins,outputs={str(ROOT/n):sha(ROOT/n) for n in output},
        source_manifest_sha256=evidence.MANIFEST,model_sha256=evidence.MODEL,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (ROOT/RECEIPT).open('x') as f: json.dump(result,f,indent=2)
    print('Matched RAW-storage/input synthesis and clock controllers prepared; not launched.')


if __name__ == '__main__': main()
