"""Prepare the isolated CS-request timing experiment; launch nothing.

Preserve the matched mapper, original 40/100 MHz clocks, resource watchdogs,
and native correctness evidence. Parent synthesized estimate: 32.955444239 MHz.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_prime_cs_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST='e04980eab0ad9131f4434a8804e71f2627b62cb66214b45a5f6f7aed8bb886d2'
PARENT_DCP='34c3e5383522f0c15a349887f89a94a2cf28778f8320d63866d8fcf3e8a59008'
CHANGES={'ventium/rtl/core/core.sv':'8dc1180b154b99b7fdf586071ca53d72427f09648403cf8f0120a4f570e3ed8d'}
TEMPLATES={
    'prime-coherence-synthesis-r1/run.py':'540c25e1dc7b904ab1f4e08822c6f4ca155f5d3b2cda706aab12fa6d8707fce4',
    'prime-coherence-clock-r1/run.py':'934db973eac977621ad41645168b565ee895e3e7e3001562aa39e6dbb2e257c1',
    'prime-coherence-synthesis-r1/audit_closed.py':'9339d1ea51f47eaa293c152573af08e533c595127bf9afa4f0cabd2c5217412a',
    'prime-coherence-clock-r1/audit_closed.py':'d51d7823d140e14f0b1ee92270fdc00bad3698ebdfe04d184aa607e98b1b04a0',
    'prime-coherence-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original, changes):
    assert changes==CHANGES
    result={}
    for phase in ('synthesis','clock'):
        name='prime-coherence-'+phase+'-r1/run.py'
        text=original[name].replace('prime-coherence-','prime-cs-')
        text=replace(text,"manifest['variant'] == 'prime_coherence_timing'",
                     "manifest['variant'] == 'prime_cs_timing'")
        if phase=='synthesis':
            text=replace(text,'ea3cde2721fd7af43bd4efdeaf8cbe154b803ff74a989a5660588233966b9c6b',native.CORE_MODEL)
            text=span(text,'\nchanges=','\nbuild=load_proof',
                      '\nchanges='+repr(native.CHANGES)+
                      "\nassert core['changes']==changes and len(core['definitions'])==152")
            text=replace(text,'source-matched local commit and no-memory hint cofactors',
                         'source-matched new-memory CS-extent cofactor')
            text=span(text,'    rationale=','    generic_gate=',
                "    rationale='Remove the unrelated S_DECODE length/fault cone from new integer memory admission. Global exception priority and held packets remain unchanged. Same logic-only mapper, UV+fast/full P5 caches and original 40/100 MHz clocks. Matched PRIME-COHERENCE control is 32.955444239 MHz. Canonical remains FAIL; no route, board or timing pass inherited.',\n")
        else:
            text=replace(text,str(ROOT/'fp-wide-context-synthesis-r1'),str(ROOT/'prime-coherence-synthesis-r1'))
            text=replace(text,'7e479811aac60c6c900c62f2d519fc36c010c25844a2cb130a259acdcb97c86e',PARENT_DCP)
        guarded(text,original[name])
        result['prime-cs-'+phase+'-r1/run.py']=text
    text=original['prime-coherence-synthesis-r1/audit_closed.py'].replace('prime-coherence-','prime-cs-')
    for suffix in ('synthesis-r1','fpga-r1'):
        text=replace(text,str(ROOT/('fp-wide-context-'+suffix)),str(ROOT/('prime-coherence-'+suffix)))
    text=replace(text,'6c60993a794d840af5e97398f7379754a8a4a2a2dc0aeff8ef6f0f582cc18e06',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'Audit the three tested commit-cofactor headers','Audit the single tested CS-request cofactor')
    result['prime-cs-synthesis-r1/audit_closed.py']=text
    text=original['prime-coherence-clock-r1/audit_closed.py'].replace('prime-coherence-','prime-cs-')
    result['prime-cs-clock-r1/audit_closed.py']=replace(text,'(-5.988)','(-5.344)')
    result['prime-cs-clock-r1/audit.tcl']=original['prime-coherence-clock-r1/audit.tcl']
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
    source=root/'prime-cs-fpga-r1'
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant']=='prime_cs_timing' and manifest['parent_manifest_sha256']==PARENT_MANIFEST
    pc=root/'prime-cs-soc-r1'; closed=json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    model=sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model==closed['binary_sha256']==manifest['simulator_sha256']
    changes={name:sha(source/name) for name in manifest['changed_parent_payloads']}
    original,pins={},{}
    for name,digest in TEMPLATES.items():
        path=root/name; assert sha(path)==digest
        original[name]=path.read_text(); pins[str(path)]=digest
    for path in (Path(__file__),Path(native.__file__),native.original,Path(native.recipe.__file__),
                 Path(native.recipe.cofactor.__file__),Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py')):
        pins[str(path)]=sha(path)
    output=derive(original,changes); receipt=root/'prime-cs-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name,text in output.items():
        path=root/name; path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as f: f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'),model_sha256=model,
            canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
            fmax_mhz=None,gameplay_ipc=None),f,indent=2)
    print('Prepared guarded CS-cofactor synthesis/timing controllers; nothing launched.',flush=True)


if __name__=='__main__': main()
