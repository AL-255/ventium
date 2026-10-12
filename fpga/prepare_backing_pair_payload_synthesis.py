"""Prepare one bounded backing-payload synthesis and best-parent timing audit.

The closed FP-HIGH-VALID controllers provide the unchanged resource/process
lifecycle. Only checked input identities, two source deltas and DMA diagnostics
change. This helper does not launch Vivado or authorize routing/deployment.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_backing_pair_payload_soc as native
from prepare_fragment_exact_timing import replace,sha,span
from prepare_payload_current_synthesis import guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST='98c7d92a830568b0aa08417b2ad2444df5b14789e92d86e497cae05552d42887'
TEMPLATES={
    'fp-high-valid-synthesis-r1/run.py':'654614f2db5fa7e0d3e350e347078aaf21f8c79a9ac08c8b1d79a0f008bd744a',
    'fp-high-valid-synthesis-r1/audit_closed.py':'4e9801dedf0e6ee3ebef530ed7a29cae8a450b9a4c2938277104630f6f7f38e7',
    'fp-high-valid-clock-r1/run.py':'fb04f314ad268d92041b617488a801db2a8c55426362bd0d015d009a1c365216',
    'fp-high-valid-clock-r1/audit_closed.py':'576abac8735553a897ba966224f1e6ccab0dc028c07fad380cc0725d98b67e05',
    'fp-high-valid-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original,changes):
    assert sorted(changes)==['ventium/'+p for p in native.CHANGES]
    output={}
    for phase in ('synthesis','clock'):
        name='fp-high-valid-'+phase+'-r1/run.py'
        text=original[name].replace('fp-high-valid-','backing-payload-')
        text=replace(text,"manifest['variant'] == 'fp_high_valid_timing'",
                     "manifest['variant'] == 'backing_pair_payload_timing'")
        if phase=='synthesis':
            text=replace(text,"changes=['rtl/core/core.sv', 'rtl/mem/ven_l1d.sv', 'rtl/mem/ventium_l1_axi.sv']",
                         'changes='+repr(native.CHANGES))
            text=replace(text,'ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c',native.CORE_MODEL)
            text=text.replace('backing-payload-regressions-r2/','backing-payload-regressions-r1/')
            text=replace(text,'source-matched wide FP response timing candidate','source-matched backing-payload and DMA candidate')
            text=span(text,'    rationale=','    generic_gate=',
                "    rationale='Prepare U/V backing payload before late request admission, retaining every request guard. Also carry the verified DMA declaration-order repair. Same logic-only mapper, 40/100 MHz constraints, UV+fast and full P5 caches. Compare timing against best MEMDIV-QUERY 30.676729 MHz, not source parent FP-HIGH-VALID 30.556744 MHz. Canonical remains FAIL; no route, board or timing pass inherited.',\n")
        guarded(text,original[name])
        output['backing-payload-'+phase+'-r1/run.py']=text
    text=original['fp-high-valid-synthesis-r1/audit_closed.py'].replace('fp-high-valid-','backing-payload-')
    for suffix in ('synthesis-r1','fpga-r1'):
        text=replace(text,str(ROOT/('pair-now-read-'+suffix)),str(ROOT/('fp-high-valid-'+suffix)))
    text=replace(text,'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'Audit three tested RTL deltas','Audit two tested RTL deltas')
    text=replace(text,"for name in ('ventium/rtl/core/core.sv',", "for name in ('ventium/3rd-party/ao486_MiSTer/rtl/soc/dma.v', 'ventium/rtl/core/core.sv',")
    text=replace(text,"assert not re.search(r'^ERROR:', log, re.M)",'''assert not re.search(r'^ERROR:', log, re.M)
# The repaired shared controls must not become eight undriven generate locals.
dma_pattern=r'Net chan\\[([0-3])\\]\\.(reset|flip_flop) in module/entity i8237 does not have driver'
assert set(re.findall(dma_pattern,(old_synth/'runme.log').read_text()))=={
    (str(ch),name) for ch in range(4) for name in ('reset','flip_flop')}
assert not re.search(dma_pattern,log), 'DMA generated controls still undriven' ''')
    text=replace(text,'no_oom=True, peak_memory=', 'dma_undriven_diagnostics_absent=True, no_oom=True, peak_memory=')
    output['backing-payload-synthesis-r1/audit_closed.py']=text
    output['backing-payload-clock-r1/audit_closed.py']=original['fp-high-valid-clock-r1/audit_closed.py'].replace('fp-high-valid-','backing-payload-')
    output['backing-payload-clock-r1/audit.tcl']=original['fp-high-valid-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return output


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root==ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    source=root/'backing-payload-fpga-r1';manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant']=='backing_pair_payload_timing' and manifest['parent_manifest_sha256']==PARENT_MANIFEST
    pc=root/'backing-payload-soc-r1';closed=json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    model=sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model==closed['binary_sha256']==manifest['simulator_sha256']
    changes={name:sha(source/name) for name in manifest['changed_parent_payloads']}
    assert sorted(changes)==['ventium/'+name for name in native.CHANGES]
    original,pins={},{}
    for name,digest in TEMPLATES.items():
        p=root/name;assert sha(p)==digest;original[name]=p.read_text();pins[str(p)]=digest
    for name in ('prepare_backing_pair_payload_synthesis.py','prepare_fragment_exact_timing.py',
                 'prepare_payload_current_synthesis.py','build_backing_pair_payload_soc.py'):
        p=Path(__file__).with_name(name);pins[str(p)]=sha(p)
    output=derive(original,changes);receipt=root/'backing-payload-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name,text in output.items():
        p=root/name;p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('x') as f:f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'),model_sha256=model,
            canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
            fmax_mhz=None,gameplay_ipc=None),f,indent=2)
    print('Prepared bounded backing-payload synthesis/timing controllers; nothing launched.',flush=True)


if __name__=='__main__':main()
