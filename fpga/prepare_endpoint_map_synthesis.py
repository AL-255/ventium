"""Prepare, but do not launch, matched SMSW/endpoint-map timing controllers.

Preserve the closed PRIME-REG mapper, clocks and complete resource lifecycle.
Admit this candidate using its own directed/map/replay audit and short PC
checks, not inherited FP/branch test results. Canonical acceptance stays red.
The timing delta includes both SMSW and endpoint-map changes.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_endpoint_map_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
MANIFEST='c45c29a6b2ae32fdd34defe85a6922e8560b2ccb9054b5d1563ae773a9040bd1'
MODEL='d8f72e2ca622b46c1ee8b0ec92197d4a6b9cd682411ed91c09ecb5488e7c052c'
PARENT_MANIFEST='3725586f494f96210da1c1f15ef56c614bcd8a3b41dbd042b02ffded7d964cd0'
PARENT_DCP='66ff1ad84d0b4f64926b0cec6df965a0a54bbca60c49185b9799c69f454eb1da'
CHANGES={
    'ventium/rtl/core/core.sv':'08533031d86005383751f9f55807a9fcaa01dbd67d1476dc6569598e2e05b510',
    'ventium/rtl/core/core_fetch_decode.svh':'a6d6e78db60da34982accd9a43a83385f127c14c454c4b05548d0a86978e82be',
    'ventium/rtl/core/decode_stages.sv':'c156a3e2801c9d27bd83f002112c31dc30f513f1ca0849ec4186919511114f0b',
    'ventium/rtl/mem/ventium_l1_axi.sv':'4e923bc360a388c113c0ee9936e5f39e90411707aeb2c59806683398e3a610ec',
}
TEMPLATES={
    'prime-reg-synthesis-r1/run.py':'bc2392fb15138104ec2278b9ff3e66de7c5aef39c5dd8b1492eba4ff9d293f39',
    'prime-reg-synthesis-r1/audit_closed.py':'e6a5d7e23d97f142492cfb21eb3970c9d1b5b97cf9affa06cd9c8d758dea487d',
    'prime-reg-clock-r1/run.py':'ff8677952acce1e5122c9065ad6002aa3f6139da732983ece45be86d466c5b1a',
    'prime-reg-clock-r1/audit_closed.py':'428ceecdccf13ca6a4904b694f607beca7d4abf867a5e0077a1145d9a1a5262e',
    'prime-reg-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
PROOF='''import sys
sys.path.insert(0,str(repo/'fpga'))
import build_endpoint_map_soc as endpoint_native
pins.update(endpoint_native.admit(proof/'endpoint-map-core-r1',proof/'endpoint-map-audit-r1.json'))
verify=load_proof('endpoint-map-core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
core=load_proof('endpoint-map-core-r1/build-started.json')
assert core['changes']==[endpoint_native.recipe.endpoint.FILE] and len(core['definitions'])==152
build=load_proof('endpoint-map-core-r1/build-closed.json')
assert build['passed'] and build['native_exit']==0 and build['pins_unchanged'] and not build['errors']
assert build['binary_sha256']==endpoint_native.CORE_MODEL
pins.update(core['pins'])
prepared=load_proof('endpoint-map-soc-r1/prepared.json')
assert len(prepared['intersecting_rtl_sources'])==102 and prepared['changes']==endpoint_native.CHANGES
assert prepared['added_defines']==[] and prepared['directed_model']==build['binary_sha256']
pins.update(prepared['pins'])
pc=load_proof('endpoint-map-soc-r1/build-closed.json')
assert pc['passed'] and pc['native_exit']==0 and pc['inputs_unchanged'] and not pc['errors']
assert pc['binary_sha256']==model and pc['structural_warnings_unchanged'] and pc['structural_debt_count']==98
timing=load_proof('endpoint-map-timing-prepared.json')
assert timing['unchanged_guard_lifecycle'] and timing['controllers_generated_not_launched']
assert timing['source_manifest_sha256']==manifest_sha and timing['model_sha256']==model
pins.update(timing['template_pins']); pins.update(timing['outputs'])
assert all(sha(p)==h for p,h in pins.items())
'''


def derive(original,changes):
    assert changes==CHANGES
    result={}
    for phase in ('synthesis','clock'):
        old=original['prime-reg-'+phase+'-r1/run.py']
        text=old.replace('prime-reg-','endpoint-map-')
        text=replace(text,"manifest['variant'] == 'prime_reg_flags_timing'",
                     "manifest['variant'] == 'endpoint_map_timing'")
        if phase=='synthesis':
            text=span(text,"verify=load_proof('endpoint-map-core-r1/verify-closed.json')",
                      "cmroot=root.parent/'endpoint-map-soc-r1/coremark'",PROOF)
            text=replace(text,'source-matched register-only branch-hint flags',
                         'source-matched SMSW repair plus parallel endpoint map')
            text=span(text,'    rationale=','    generic_gate=',
                "    rationale='Measure the general SMSW repair and parallel endpoint-map transfer together. "
                "Same logic-only mapper, UV-fast/full P5 caches, 40/100 MHz clocks and resource limits. "
                "Matched SMSW-free PRIME-REG control estimates 35.023816195 MHz. The delta is composite, "
                "not an isolated endpoint-map gain. Candidate directed/map/replay checks and short PC "
                "CRC checks only; canonical and complete fault differential gates remain red. "
                "No standard-suite or hardware pass inherited.',\n")
            guarded(text,old)
        else:
            text=replace(text,str(ROOT/'prime-cs-synthesis-r1'),str(ROOT/'prime-reg-synthesis-r1'))
            text=replace(text,'097b4be822a4d63488de234395636255f43788154e9e60482419b6b6a66f56d5',PARENT_DCP)
            clock_guarded(text,old)
        result['endpoint-map-'+phase+'-r1/run.py']=text
    text=original['prime-reg-synthesis-r1/audit_closed.py'].replace('prime-reg-','endpoint-map-')
    for suffix in ('synthesis-r1','fpga-r1'):
        text=replace(text,str(ROOT/('prime-cs-'+suffix)),str(ROOT/('prime-reg-'+suffix)))
    text=replace(text,'fd6a1b36862845a096981b2028b4df479b00a9da447c35300834eba8f720cd15',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'single tested register branch-flag cofactor','four-file SMSW and endpoint-map transfer')
    result['endpoint-map-synthesis-r1/audit_closed.py']=text
    text=original['prime-reg-clock-r1/audit_closed.py'].replace('prime-reg-','endpoint-map-')
    result['endpoint-map-clock-r1/audit_closed.py']=replace(text,'(-4.448)','(-3.552)')
    result['endpoint-map-clock-r1/audit.tcl']=original['prime-reg-clock-r1/audit.tcl']
    for name,text in result.items():
        if name.endswith('.py'): ast.parse(text,filename=name)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root==ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    source=root/'endpoint-map-fpga-r1'
    assert sha(source/'input-manifest.json')==MANIFEST
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant']=='endpoint_map_timing' and manifest['parent_manifest_sha256']==PARENT_MANIFEST
    pc=root/'endpoint-map-soc-r1'; closed=json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==MODEL
    assert manifest['simulator_sha256']==MODEL
    changes={name:sha(source/name) for name in manifest['changed_parent_payloads']}
    original,pins={},{}
    for name,digest in TEMPLATES.items():
        path=root/name; assert sha(path)==digest
        original[name]=path.read_text(); pins[str(path)]=digest
    for path in (Path(__file__),Path(native.__file__),Path(native.recipe.__file__),
                 Path(native.recipe.endpoint.__file__),Path(native.recipe.smsw.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path)]=sha(path)
    output=derive(original,changes); receipt=root/'endpoint-map-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name,text in output.items():
        path=root/name; path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as f:f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=MANIFEST,model_sha256=MODEL,
            canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
            fmax_mhz=None,gameplay_ipc=None),f,indent=2)
    print('Prepared guarded four-file timing controllers; nothing launched.',flush=True)


if __name__=='__main__':main()
