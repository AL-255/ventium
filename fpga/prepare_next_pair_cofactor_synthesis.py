"""Prepare one bounded synthesis of the tested RAW next-read/pair cofactor.

Keep the closed controller's mapper, 40/100 MHz constraints, resource reserves,
exclusive Vivado ownership and cleanup lifecycle unchanged. No tool is launched.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_next_pair_cofactor_soc as native
from prepare_fragment_exact_timing import replace,sha,span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST = 'd6f856259c0cdef90c0ef3f1a97b0a5568bdba13b8eb9d3a8332fc351bc90c20'
TEMPLATES = {
    'backing-payload-synthesis-r1/run.py':'4495387c3fedc64340e3c6d137e7acf83fbc24f66383e30ef7d7b6b252fd2e9e',
    'backing-payload-synthesis-r1/audit_closed.py':'17b200cf86b54588b206bd47d323bfa5ba198f61c72a10d500a9b602332bb6d0',
    'backing-payload-clock-r1/run.py':'3cc123517133f8dcc0a7f154cf4b6850922bac49452422d2f14444bcc8706c76',
    'backing-payload-clock-r1/audit_closed.py':'dd5a513e7a36d5e88a9f80297921137b169a5218861456fde713a3abf4fc6539',
    'backing-payload-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original,changes):
    assert sorted(changes) == ['ventium/'+p for p in native.CHANGES]
    output = {}
    for phase in ('synthesis','clock'):
        name = 'backing-payload-'+phase+'-r1/run.py'
        text = original[name].replace('backing-payload-','next-pair-cofactor-')
        text = replace(text,"manifest['variant'] == 'backing_pair_payload_timing'",
                       "manifest['variant'] == 'next_pair_cofactor_timing'")
        if phase == 'synthesis':
            text = replace(text,"changes=['3rd-party/ao486_MiSTer/rtl/soc/dma.v', 'rtl/mem/ven_l1d.sv']",
                           'changes='+repr(native.CHANGES))
            text = replace(text,'4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15',native.CORE_MODEL)
            text = text.replace('next-pair-cofactor-regressions-r1/replay/','next-pair-cofactor-replay-r1/')
            text = replace(text,'source-matched backing-payload and DMA candidate','source-matched RAW next-read/pair cofactor')
            text = span(text,'    rationale=','    generic_gate=',
                "    rationale='Expose the request-equivalent RAW next-read/U-read-V-store exclusion before late hint qualification. Preserve AGI hints, cache arbitration, all request guards, UV+fast and full P5 caches. Same logic-only mapper and 40/100 MHz constraints. Compare against best MEMDIV-QUERY 30.676729 MHz; source parent BACKING-PAYLOAD is 30.591330 MHz. Canonical remains FAIL; no timing, route or board pass inherited.',\n")
        guarded(text,original[name])
        output['next-pair-cofactor-'+phase+'-r1/run.py'] = text
    text = original['backing-payload-synthesis-r1/audit_closed.py'].replace('backing-payload-','next-pair-cofactor-')
    for suffix in ('synthesis-r1','fpga-r1'):
        text = replace(text,str(ROOT/('fp-high-valid-'+suffix)),str(ROOT/('backing-payload-'+suffix)))
    text = replace(text,'98c7d92a830568b0aa08417b2ad2444df5b14789e92d86e497cae05552d42887',PARENT_MANIFEST)
    text = span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text = replace(text,'Audit two tested RTL deltas','Audit one tested RTL delta')
    # The common core includes core_mem_chain.svh; it is not an independent
    # read_verilog unit. All manifest payloads are hash-checked above.
    old = """assert set(re.findall(dma_pattern,(old_synth/'runme.log').read_text()))=={
    (str(ch),name) for ch in range(4) for name in ('reset','flip_flop')}"""
    text = replace(text,old,"assert not re.search(dma_pattern,(old_synth/'runme.log').read_text())")
    output['next-pair-cofactor-synthesis-r1/audit_closed.py'] = text
    output['next-pair-cofactor-clock-r1/audit_closed.py'] = original['backing-payload-clock-r1/audit_closed.py'].replace('backing-payload-','next-pair-cofactor-')
    output['next-pair-cofactor-clock-r1/audit.tcl'] = original['backing-payload-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'): ast.parse(text,filename=name)
    return output


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root = ap.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    source = root/'next-pair-cofactor-fpga-r1'
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant'] == 'next_pair_cofactor_timing' and manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    pc = root/'next-pair-cofactor-soc-r1'; closed = json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit'] == 0
    model = sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model == closed['binary_sha256'] == manifest['simulator_sha256']
    changes = {name:sha(source/name) for name in manifest['changed_parent_payloads']}
    assert sorted(changes) == ['ventium/'+name for name in native.CHANGES]
    original,pins = {},{}
    for name,digest in TEMPLATES.items():
        p = root/name; assert sha(p) == digest; original[name] = p.read_text(); pins[str(p)] = digest
    for name in ('prepare_next_pair_cofactor_synthesis.py','prepare_fragment_exact_timing.py',
                 'prepare_payload_current_synthesis.py','build_next_pair_cofactor_soc.py'):
        p = Path(__file__).with_name(name); pins[str(p)] = sha(p)
    output = derive(original,changes); receipt = root/'next-pair-cofactor-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name,text in output.items():
        p = root/name; p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('x') as f: f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'),model_sha256=model,
            canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
            fmax_mhz=None,gameplay_ipc=None),f,indent=2)
    print('Prepared bounded next-pair synthesis/timing controllers; nothing launched.',flush=True)


if __name__ == '__main__': main()
