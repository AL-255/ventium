"""Prepare new CAD owners for the corrected posted-mouse wrapper; launch none."""
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace,sha
from prepare_payload_current_synthesis import guarded as synth_guarded
from prepare_v_result_carry_clock import guarded as clock_guarded
import posted_mouse_evidence as evidence

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
SOURCE='v-result-carry-posted-mouse-fpga-r1'
SYNTH='posted-mouse-synthesis-r1'
CLOCK='posted-mouse-clock-r1'
RECEIPT='posted-mouse-timing-prepared-r1.json'
TEMPLATES={
    'v-result-carry-synthesis-r3/run.py':'7d17fca59f2ff53141b87f59468cabc86f747ec3569beeed2b5e4894482a22cc',
    'v-result-carry-synthesis-r3/audit_closed.py':'e7c61eb53aa0c743d95824570b4790b2975a8fc2f2ef7c59703e854f809e060b',
    'v-result-carry-clock-r1/run.py':'ff454a85d4fc0a460f398a0e8cd1a13882444f1ba042a5add067d93e034ef72b',
    'v-result-carry-clock-r1/audit_closed.py':'642d616ab1b294598f02104933c71e7afdf7b72cc591b9d0a5a4331ad528bfe3',
    'v-result-carry-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def common(text):
    text=text.replace("source = root.parent/'v-result-carry-fpga-r1'",f"source = root.parent/'{SOURCE}'")
    text=text.replace('ventium-v-result-carry-synth-oct15-r3.service','ventium-posted-mouse-synth-oct16-r1.service')
    text=text.replace('ventium-v-result-carry-clock-oct15-r1.service','ventium-posted-mouse-clock-oct16-r1.service')
    text=replace(text,"freeze['manifest_sha256'] == manifest_sha and freeze['source_contract_passed']",
        "freeze['manifest_sha256'] == manifest_sha and freeze['preprocessing_passed']\n"
        "assert not freeze['source_contract_passed'] and not freeze['full_wrapper_elaborated']")
    text=replace(text,"manifest['variant'] == 'v_result_carry_aux_mouse_unqualified'",
                 f"manifest['variant'] == '{evidence.VARIANT}'")
    # CPU lint applies to byte-identical CPU sources, NOT to the changed wrapper.
    text=replace(text,"lint['source_manifest_sha256'] == manifest_sha",
                 "lint['source_manifest_sha256'] == '"+evidence.repair.PARENT_SHA+"'")
    text=replace(text,"pins = dict(freeze['input_pins'])", """pins = dict(freeze['input_pins'])
import sys
sys.path.insert(0,str(repo/'fpga'))
import posted_mouse_evidence as mouse_evidence
assert manifest_sha==mouse_evidence.MANIFEST and model==mouse_evidence.MODEL
pins.update(mouse_evidence.check(source))""")
    return text


def derive(original):
    output={}
    old=original['v-result-carry-synthesis-r3/run.py'];text=common(old)
    text=replace(text,"load_proof('v-result-carry-timing-prepared-r3.json')",f"load_proof('{RECEIPT}')")
    text=replace(text,"wrapper = str(source/'ventium/fpga/create_project_3mhz_wrapper.tcl')",
                 "wrapper = str(root/'launch_checked.tcl')")
    # The entry-point Tcl is an extra pinned controller, not a hidden RTL edit.
    text=replace(text,"source/'defines.txt',lint_file,repo/'fpga/run_vivado_exclusive.sh'",
                 "source/'defines.txt',root/'launch_checked.tcl',lint_file,repo/'fpga/run_vivado_exclusive.sh'")
    text=replace(text,"rationale='Remove only the unused carry input from V arithmetic results; flag CF and all execution authority unchanged. Retain AUX ownership and mouse wrapper. Exact 159 hardware defines and 40/100 MHz constraints, complete same-input A-B, cold held/mixed/FP/integer tests and short CoreMark controls. Parent also lacks AUX/mouse, so no isolated timing-gain claim. Canonical still FAIL; no suite, route or board acceptance.'",
        "rationale='Correct actual posted-DDR mouse integration by moving the exact peripheral block outside the DDR conditional. All processor sources/159 defines/40 and 100 MHz clocks are unchanged. Six native wrapper micro positives and two old-bug negatives; CPU/DDR black boxes explicitly excluded from that microgate. Native compile-order admission and full synthesis source audit required. Canonical FAIL and all suite/physical gates remain open.'")
    synth_guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    output[SYNTH+'/run.py']=text
    audit=original['v-result-carry-synthesis-r3/audit_closed.py']
    audit=replace(audit,"source = root.parent / 'v-result-carry-fpga-r1'",f"source = root.parent / '{SOURCE}'")
    audit=replace(audit,'ventium-v-result-carry-synth-oct15-r3.service','ventium-posted-mouse-synth-oct16-r1.service')
    audit=replace(audit,'e9ece658db4ade74476dbc9a15f6887f1a5a643375d2251ef8af53b258922db5',evidence.WRAPPER_SHA)
    audit=replace(audit,"log = (synth/'runme.log').read_text()", """log = (synth/'runme.log').read_text()
assert (root/'native.log').read_text().count('MOUSE_POSTED_PREFLIGHT_OK exact_sources=3') >= 1
for module in ('ven_ps2_mailbox','ven_ps2_device'):
    assert "synthesizing module '"+module+"'" in log, module
assert not re.search(r'Net (mouse_csr_rdata|ps2_mouseclk_dev|ps2_mousedat_dev).*does not have driver',log)
""")
    output[SYNTH+'/audit_closed.py']=audit
    output[SYNTH+'/launch_checked.tcl']=Path(__file__).with_name('launch_posted_mouse_checked.tcl').read_text()
    old=original['v-result-carry-clock-r1/run.py'];text=common(old)
    text=replace(text,"synthesis = root.parent/'v-result-carry-synthesis-r3'",f"synthesis = root.parent/'{SYNTH}'")
    # Change only the FPGA manifest identity, leaving the CPU-only lint identity.
    text=replace(text,"assert manifest_sha == '"+evidence.repair.PARENT_SHA+"'",
                 "assert manifest_sha == '"+evidence.MANIFEST+"'")
    text=replace(text,"root.parent/'v-result-carry-clock-prepared-r1.json'",f"root.parent/'{RECEIPT}'")
    clock_guarded(text,old)
    output[CLOCK+'/run.py']=text
    output[CLOCK+'/audit_closed.py']=replace(original['v-result-carry-clock-r1/audit_closed.py'],
        'ventium-v-result-carry-clock-oct15-r1.service','ventium-posted-mouse-clock-oct16-r1.service')
    output[CLOCK+'/audit.tcl']=original['v-result-carry-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    pins=evidence.check(ROOT/SOURCE)
    original={}
    for name,h in TEMPLATES.items():
        path=ROOT/name;assert sha(path)==h;original[name]=path.read_text();pins[str(path)]=h
    for name in ('prepare_posted_mouse_timing.py','launch_posted_mouse_checked.tcl',
                 'prepare_fragment_exact_timing.py','prepare_payload_current_synthesis.py',
                 'prepare_v_result_carry_clock.py'):
        path=Path(__file__).with_name(name).resolve();pins[str(path)]=sha(path)
    outputs=derive(original)
    assert not (ROOT/RECEIPT).exists() and all(not (ROOT/n).exists() for n in outputs)
    for name,text in outputs.items():
        path=ROOT/name;path.parent.mkdir(exist_ok=True)
        with path.open('x') as f:f.write(text)
    receipt=dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
        template_pins=pins,outputs={str(ROOT/n):sha(ROOT/n) for n in outputs},
        source_manifest_sha256=evidence.MANIFEST,model_sha256=evidence.MODEL,
        full_wrapper_micro_scope='CPU/DDR and unrelated modules blackboxed',
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (ROOT/RECEIPT).open('x') as f:json.dump(receipt,f,indent=2)
    print('Corrected-wrapper synthesis and read-only timing prepared; not launched.')


if __name__=='__main__':main()
