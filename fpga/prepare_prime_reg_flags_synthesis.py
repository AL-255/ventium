"""Prepare a matched register-only branch-flag timing experiment; launch nothing.

Retain the closed parent's source/profile checks and resource lifecycle. The
parent estimates 33.958163543 MHz; no improvement or acceptance is presumed.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_prime_reg_flags_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST='fd6a1b36862845a096981b2028b4df479b00a9da447c35300834eba8f720cd15'
PARENT_DCP='097b4be822a4d63488de234395636255f43788154e9e60482419b6b6a66f56d5'
CHANGES={'ventium/rtl/core/core_mem_chain.svh':'1f677f3cc7cd43ccea0d05edb564296865e58bd354795810383794b8ab0f077a'}
TEMPLATES={
    'prime-cs-synthesis-r1/run.py':'a2fddf86032a524743a2f695c92e0eaedc76a4ff51be74c33cd41fff9b17447f',
    'prime-cs-synthesis-r1/audit_closed.py':'eeddf1ba84a5fb421526787345d980f6ef5932f63cd57ba8c569dc1303df658d',
    'prime-cs-clock-swap4-r1/run.py':'8f42c92b5dc994e36f7f073fd34ea98d537da1eae4360906c7b4f93894a73cdd',
    'prime-cs-clock-swap4-r1/audit_closed.py':'fa222d434dae7e06db8107a7541fa5b81679b55c77e5bc232586b8f145b1baee',
    'prime-cs-clock-swap4-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def clock_guarded(text,original):
    """The closed read-only audit has a smaller swap cap than synthesis."""
    boundary='owner = None\n'
    assert text[text.index(boundary):]==original[original.index(boundary):]
    for invariant in ("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G'",
                      'memory+swap > 11*gib', 'if free < 4*gib:', 'min(host.values()) < 2*gib',
                      "VEN_FPGA_CORE_MHZ='40'", "VEN_FPGA_BUILD_PROFILE='logic_only'",
                      "host['MemAvailable'] > 10*gib and host['SwapFree'] > 8*gib"):
        assert invariant in text


def derive(original,changes):
    assert changes==CHANGES
    result={}
    for phase in ('synthesis','clock'):
        folder='prime-cs-synthesis-r1' if phase=='synthesis' else 'prime-cs-clock-swap4-r1'
        old=original[folder+'/run.py']
        text=old.replace('prime-cs-','prime-reg-')
        text=replace(text,"manifest['variant'] == 'prime_cs_timing'",
                     "manifest['variant'] == 'prime_reg_flags_timing'")
        if phase=='synthesis':
            text=replace(text,'73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca',native.CORE_MODEL)
            text=replace(text,"changes=['rtl/core/core.sv']",'changes='+repr(native.CHANGES))
            text=replace(text,'source-matched new-memory CS-extent cofactor',
                         'source-matched register-only branch-hint flags')
            text=span(text,'    rationale=','    generic_gate=',
                "    rationale='Remove memory-response operands from the non-memory branch-hint flag decision only. Architectural execution, offers and ownership are unchanged. Same logic-only mapper, UV+fast/full P5 caches and 40/100 MHz clocks. Matched PRIME-CS control estimates 33.958163543 MHz. Measure the additional flag logic area; canonical remains FAIL and no timing or hardware pass is inherited.',\n")
            guarded(text,old)
        else:
            text=replace(text,'ventium-prime-reg-clock-swap4-oct13.service',
                         'ventium-prime-reg-clock-oct13.service')
            text=replace(text,str(ROOT/'prime-coherence-synthesis-r1'),str(ROOT/'prime-cs-synthesis-r1'))
            text=replace(text,'34c3e5383522f0c15a349887f89a94a2cf28778f8320d63866d8fcf3e8a59008',PARENT_DCP)
            clock_guarded(text,old)
        result['prime-reg-'+phase+'-r1/run.py']=text
    text=original['prime-cs-synthesis-r1/audit_closed.py'].replace('prime-cs-','prime-reg-')
    for suffix in ('synthesis-r1','fpga-r1'):
        text=replace(text,str(ROOT/('prime-coherence-'+suffix)),str(ROOT/('prime-cs-'+suffix)))
    text=replace(text,'e04980eab0ad9131f4434a8804e71f2627b62cb66214b45a5f6f7aed8bb886d2',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'single tested CS-request cofactor','single tested register branch-flag cofactor')
    result['prime-reg-synthesis-r1/audit_closed.py']=text
    text=original['prime-cs-clock-swap4-r1/audit_closed.py']
    text=replace(text,'ventium-prime-cs-clock-swap4-oct13.service','ventium-prime-reg-clock-oct13.service')
    result['prime-reg-clock-r1/audit_closed.py']=replace(text,'(-5.344)','(-4.448)')
    result['prime-reg-clock-r1/audit.tcl']=original['prime-cs-clock-swap4-r1/audit.tcl']
    for name,text in result.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root==ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    source=root/'prime-reg-fpga-r1'
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant']=='prime_reg_flags_timing' and manifest['parent_manifest_sha256']==PARENT_MANIFEST
    pc=root/'prime-reg-soc-r1'; closed=json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    model=sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model==closed['binary_sha256']==manifest['simulator_sha256']
    changes={name:sha(source/name) for name in manifest['changed_parent_payloads']}
    original,pins={},{}
    for name,digest in TEMPLATES.items():
        path=root/name; assert sha(path)==digest
        original[name]=path.read_text(); pins[str(path)]=digest
    for path in (Path(__file__),Path(native.__file__),native.original,Path(native.recipe.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py')):
        pins[str(path)]=sha(path)
    output=derive(original,changes); receipt=root/'prime-reg-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name,text in output.items():
        path=root/name; path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as f:f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'),model_sha256=model,
            canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
            fmax_mhz=None,gameplay_ipc=None),f,indent=2)
    print('Prepared guarded register-flag synthesis/timing controllers; nothing launched.',flush=True)


if __name__=='__main__':main()
