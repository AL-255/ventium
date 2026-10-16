#!/usr/bin/env python3
"""Repair mouse elaboration in a NEW frozen export; never alter old evidence.

The earlier overlay inserted both devices before the legacy DDR instance,
inside VEN_DDR_POSTED's `else. The posted production profile compiled them out.
Move exactly that block before the conditional; no processor or timing change.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from freeze_rk_candidate import frozen_path, write_new

REPO = Path(__file__).resolve().parents[1]
PARENT_SHA = '716dab7ee8801e5f865699f2b8619ae881b9d442feb4d59b42399abea758c77e'
WRAPPER = 'flow/src/rk_ao486_system_pl.v'
WRAPPER_SHA = 'e9ece658db4ade74476dbc9a15f6887f1a5a643375d2251ef8af53b258922db5'
BEGIN = '    // Management ownership survives guest reset long enough to expose its\n'
END = '    ven_ddram_axi #(.MEM_BASE(MEM_BASE)) u_ddr ('
BRANCH = '`ifdef VEN_DDR_POSTED\n    ven_ddram_axi_posted #(.MEM_BASE(MEM_BASE), .WRITE_SLOTS(16)) u_ddr ('


def sha(data):
    return hashlib.sha256(data).hexdigest()


def repair(text):
    if sha(text.encode()) != WRAPPER_SHA:
        raise ValueError('wrong/already-repaired frozen wrapper')
    if any(text.count(anchor) != 1 for anchor in (BEGIN, END, BRANCH)):
        raise ValueError('ambiguous wrapper anchor')
    start, end, branch = text.index(BEGIN), text.index(END), text.index(BRANCH)
    if not branch < start < end:
        raise ValueError('unexpected conditional layout')
    block = text[start:end]
    if block.count('ven_ps2_mailbox u_mouse_mailbox') != 1 or block.count(
            'ven_ps2_device #(.CLK_HZ(CLK_HZ)) u_ps2_mouse_device') != 1:
        raise ValueError('missing or duplicate device')
    result = text[:start] + text[end:]
    return result[:branch] + block + result[branch:]


def preprocess(path, definitions):
    command = ['/usr/bin/iverilog', '-g2012', '-E', '-o', '-']
    command += ['-D' + name for name in definitions]
    run = subprocess.run(command + [str(path)], capture_output=True, text=True,
                         timeout=15, check=True)
    return run.stdout


def check_devices(text):
    for instance in ('ven_ps2_mailbox u_mouse_mailbox',
                     'ven_ps2_device #(.CLK_HZ(CLK_HZ)) u_ps2_mouse_device'):
        if text.count(instance) != 1:
            raise ValueError('mouse missing/duplicated after preprocessing: ' + instance)


def prepare(parent, out):
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and os.access(scratch, os.W_OK)
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert not out.exists() and out != scratch and out.is_relative_to(scratch)
    assert not out.is_relative_to(parent) and not parent.is_relative_to(out)
    manifest_bytes = (parent/'input-manifest.json').read_bytes()
    assert sha(manifest_bytes) == PARENT_SHA
    old = json.loads(manifest_bytes)
    assert old['qualification'] == 'UNQUALIFIED' and len(old['files']) == 192
    assert old['core_mhz'] == 40 and old['write_slots'] == 16
    assert len(old['hardware_defines']) == 159 and 'VEN_DDR_POSTED' in old['hardware_defines']
    prior = json.loads((parent/'freeze-receipt.json').read_text())
    pins = dict(prior['input_pins'])
    for row in old['files']:
        pins[str(parent/frozen_path(row['frozen']))] = row['sha256']
    for path in (parent/'input-manifest.json', parent/'freeze-receipt.json',
                 parent/'defines.txt', Path(__file__), Path('/usr/bin/iverilog')):
        pins[str(path)] = sha(path.read_bytes())
    def stable():
        for name, digest in pins.items():
            if sha(Path(name).read_bytes()) != digest:
                raise ValueError('input drift: ' + name)
    stable()
    fixed = repair((parent/WRAPPER).read_text()).encode()
    out.mkdir(mode=0o700)
    rows = []
    for row in old['files']:
        name = frozen_path(row['frozen'])
        data = fixed if name == WRAPPER else (parent/name).read_bytes()
        write_new(out/name, data)
        rows.append(dict(frozen=name, source=str(parent/name), sha256=sha(data),
                         bytes=len(data), parent_sha256=row['sha256']))
    write_new(out/'defines.txt', (parent/'defines.txt').read_bytes())
    checks = []
    for label, defines in (
            ('posted_exact159', old['hardware_defines']),
            ('nonposted_control', [n for n in old['hardware_defines'] if n != 'VEN_DDR_POSTED'])):
        text = preprocess(out/WRAPPER, defines)
        check_devices(text)
        write_new(out/(label+'.preprocessed.v'), text.encode())
        checks.append(dict(profile=label, defines=defines, both_devices_present=True,
                           preprocessed_sha256=sha(text.encode()), elaborated=False))
    # Preserve the actual failed profile as a required red control, not a pass.
    bad = preprocess(parent/WRAPPER, old['hardware_defines'])
    try:
        check_devices(bad)
    except ValueError:
        pass
    else:
        raise ValueError('old posted wrapper no longer reproduces missing devices')
    stable()
    for row in rows:
        assert sha((out/row['frozen']).read_bytes()) == row['sha256']
    manifest = dict(old, variant='v_result_carry_posted_mouse_repaired_unqualified',
        files=rows, parent_manifest_sha256=PARENT_SHA,
        changed_parent_payloads=[WRAPPER], changed_flow_payloads=[WRAPPER], added_payloads=[],
        full_wrapper_elaborated=False, full_soc_lint=False, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None,
        note='Only move the exact mouse block outside DDR conditional. Old synthesis excluded it; '
             'no native synthesis, timing, complete-wrapper simulation or acceptance inherited.')
    write_new(out/'input-manifest.json', (json.dumps(manifest, indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED', source_contract_passed=False,
        preprocessing_passed=True, old_posted_negative_control_rejected=True,
        payloads=len(rows), changed_payloads=[WRAPPER], manifest_sha256=sha(
            (out/'input-manifest.json').read_bytes()), input_pins=pins, checks=checks,
        full_wrapper_elaborated=False, complete_wrapper_or_board_qualified=False,
        synthesis_launched=False)
    write_new(out/'freeze-receipt.json', (json.dumps(receipt, indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','payloads','changed_payloads',
                                 'manifest_sha256','preprocessing_passed','synthesis_launched')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.parent.resolve(strict=True), args.out.resolve()), indent=2))
