#!/usr/bin/env python3
"""Recheck closed carry-payload evidence without promoting the failed gate."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import compare
import tracefmt
from run_v_carry_system_r2 import check_pair_witness, PATTERNS, PAIR_REQUIRED, PAIR_FORBIDDEN


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def load(p):
    return json.loads(p.read_text())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    core, matrix, leaf = root/'core', root/'system-r2', root/'leaf-r1'
    pins = load(leaf/'pins.json')
    for p in (core/'build-started.json', core/'verify-started.json', matrix/'started.json'):
        pins.update(load(p)['pins'])
        pins[str(p)] = sha(p)
    built, canonical = load(core/'build-closed.json'), load(core/'verify-closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert sha(core/'obj/tb_ventium') == built['binary_sha256']
    assert canonical['canonical_gate_native_exit'] == 2 and not canonical['canonical_gate_passed']
    assert canonical['pins_unchanged'] and not canonical['masks_or_goldens_or_bands_changed']
    assert len(canonical['deltas']) == 20 and all(x['same_records'] for x in canonical['deltas'])
    prior = Path('/home/yukidama/external/tmp/ventium-fp-exec-cut.MNkzxfBO/core').resolve()
    for p in sorted((core/'generic-work').glob('*.cycle_rtl.vtrace')):
        assert tracefmt.read_trace(str(p)).records == tracefmt.read_trace(str(prior/'generic-work'/p.name)).records
        pins[str(p)] = sha(p)
    checked = load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged']
    assert [(x['native_exit'], x['expected_negative']) for x in checked['runs']] == [(0,False),(1,True),(1,True)]
    closed = load(matrix/'closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert len(closed['measurements']) == 576
    count, paired = 0, 0
    for pattern, _, _ in PATTERNS:
        for reloc in (0, 1):
            for offset in (0,1,7,15,28,31):
                work = matrix/f'{pattern}-r{reloc}-o{offset}'
                assert load(work/'closed.json')['passed']
                assert sha(work/'fixture.bin') == load(work/'closed.json')['image_sha256']
                symbols = {s[2]: int(s[0],16) for line in subprocess.check_output(['nm','-n',work/'fixture.elf'],text=True).splitlines()
                           if len(s := line.split()) == 3 and s[0] != 'U'}
                gold = tracefmt.read_trace(str(work/'golden.vtrace'))
                for latency in (0,7):
                    for mode in ('cycle-func','cycle'):
                        traces = []
                        for model in ('control','candidate'):
                            stem = f'{model}-lat{latency}-{mode}'
                            assert load(work/(stem+'.exit.json'))['native_exit'] == 133
                            argv = load(work/(stem+'.command.json'))
                            assert all(arg in argv for arg in ('--system','--l1-axi','--'+mode))
                            tr = tracefmt.read_trace(str(work/(stem+'.vtrace')))
                            traces.append(tr.records)
                            if mode == 'cycle-func':
                                log = io.StringIO()
                                assert compare.compare_func(gold,tr,False,0xffffffff,False,20,log,sys_both=True) == 0, log.getvalue()
                            elif model == 'candidate':
                                subjects = [(i,r) for i,r in enumerate(tr.records) if int(r['pc'],0) == symbols['hot_load']]
                                assert len(subjects) == 16
                                v = [(i,r) for i,r in subjects if r.get('pipe') == 'V' and r.get('paired')]
                                if pattern in PAIR_REQUIRED: assert v
                                if pattern in PAIR_FORBIDDEN: assert not v
                                for i,r in v: check_pair_witness(tr.records[i-1],r,symbols['carry_u'])
                                paired += len(v)
                        assert traces[0] == traces[1]
                        if mode == 'cycle-func': count += len(traces[1])
                for p in work.iterdir():
                    if p.is_file(): pins[str(p)] = sha(p)
    assert paired == closed['subject_v_retirements'] == 3840
    owners = {}
    for label, unit, invocation, status in (
        ('leaf','ventium-v-carry-leaf-oct10.service','679b19427f0f42d086f4dfec8c0ca9f8',0),
        ('core','ventium-v-carry-core-oct10.service','a864824561094e7abc410da900a6558e',0),
        ('system','ventium-v-carry-system-r2-oct10.service','24a25508dd40493b8c0d5f540e47c1f5',0),
        ('verify','ventium-v-carry-verify-oct10.service','7e6cee22f5bd4965bace4b6070c3a012',1),
    ):
        props = dict(x.split('=',1) for x in subprocess.check_output(['systemctl','--user','show',unit,
            '-pMainPID','-pSubState','-pInvocationID','-pExecMainStatus'],text=True).splitlines())
        assert props == dict(MainPID='0',SubState='failed' if status else 'exited',InvocationID=invocation,ExecMainStatus=str(status))
        owners[label] = props
    for p in (Path(__file__),core/'build-closed.json',core/'verify-closed.json',leaf/'closed.json',matrix/'closed.json'):
        pins[str(p)] = sha(p)
    assert all(sha(p) == h for p,h in pins.items())
    result = dict(audit_complete=True,pins=pins,checked_input_pins=len(pins),owners=owners,
        model_sha256=built['binary_sha256'],directed_system_cases=144,identical_architectural_records=count,
        actual_subject_v_retirements=paired,all_20_canonical_cycle_streams_identical=True,
        canonical_gate_passed=False,gameplay_ipc=None,standard_suite=False,hardware_acceptance=False)
    with (root/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k != 'pins'}))


if __name__ == '__main__': main()
