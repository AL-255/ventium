#!/usr/bin/env python3
"""Carry current compiled processor fixes, AUX ownership and mouse onto the RK.

Export only. All 170 shared HDL inputs must match a closed AUX-corrected PC
build. The complete new wrapper still requires lint, synthesis, timing and
physical acceptance; no older mouse export or simulator pass is inherited.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

import build_aux_status_soc as native
import freeze_prime_noack_rk_candidate as base
import freeze_ps2_mouse_rk_candidate as mouse
from freeze_rk_candidate import (directory, frozen_path, overlaps, publish_new,
    sha256, snapshot, unchanged, write_new)

REPO, require = base.REPO, base.require
PARENT = 'd655cc8bf1dcea77cc82996c7ebade06387b3da07d7e83a65c84a0ed0a6feefc'
PROOF = '04dbed0d6e95ebe96d2c22ee9cc099480840bfddb1a3ce4986809d6c1af80b33'
PROOF_UNIT = 'ventium-ps2-aux-adapter-oct15-r1.service'
PROOF_INVOCATION = 'e101a954d6b848589d4798a8d2e35fa4'
AUX = 'ventium/'+native.FILE


def check_delta(name, before, after):
    if name == AUX:
        require(after == native.recipe.transform(before.decode()).encode(), 'wrong AUX repair')
        return True
    require(before == after, 'unreviewed processor/platform change: '+name)
    return False


def check_profile(old, started, closed, definitions):
    require(old['variant'] == 'pipe_wait_read_ack_timing' and old['qualification'] == 'UNQUALIFIED'
            and old['core_mhz'] == 40 and old['write_slots'] == 16 and old['l2_sets'] == 1024,
            'wrong FPGA predecessor')
    pc, core = native.PROFILES['pipe-wait']
    require(started['parent_profile'] == 'pipe-wait' and started['parent_model'] == pc
            and started['directed_model'] == core and started['changes'] == [native.FILE]
            and started['added_defines'] == [], 'wrong AUX/core provenance')
    require(closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged'],
            'AUX PC build not closed successfully')
    hw = old['hardware_defines']
    require(len(hw) == len(set(hw)) == 159 and len(definitions) == len(set(definitions)) == 157,
            'profile count drift')
    require(set(hw)-{'SYNTHESIS', 'VTM_NO_DPI'} == set(definitions), 'hardware/simulator profile differs')
    required = {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_X87_MF_STRICT', 'VEN_KBC_FAST', 'VEN_KBD_AUTOACK'}
    require(required <= set(definitions), 'required acceptance mode absent')
    actual = [s[2:] for s in started['command'] if s.startswith('-D')]+[
        s[8:] for s in started['command'] if s.startswith('+define+')]
    require(len(actual) == len(definitions) and set(actual) == set(definitions), 'native define drift')
    require('-GBOARD_POSTED=1' in started['command'] and '-GBOARD_WRITE_SLOTS=16' in started['command'],
            'posted transport drift')


def closed_owner(unit, invocation):
    keys = ('SubState', 'MainPID', 'ExecMainStatus', 'Result', 'InvocationID')
    props = dict(s.split('=', 1) for s in subprocess.check_output([
        'systemctl', '--user', 'show', unit, *['-p'+k for k in keys]], text=True, timeout=10).splitlines())
    require(props == dict(SubState='exited', MainPID='0', ExecMainStatus='0', Result='success',
                          InvocationID=invocation), 'native owner not successfully closed: '+unit)
    return props


def freeze(parent, sim, overlay, proof, build_unit, out):
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    require(__debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
            and scratch.stat().st_dev != REPO.stat().st_dev
            and shutil.disk_usage(scratch).free > 4*1024**3, 'external scratch admission failed')
    require(out.is_relative_to(scratch) and out != scratch and not out.exists(), 'fresh output required')
    require(not any(overlaps(out, p) for p in (parent, sim, overlay, proof, REPO)), 'overlapping output')
    observed, aliases = {}, {}
    def read(p, digest=None, size=None):
        actual = p.resolve(strict=True); aliases[p] = actual
        return base.read_observed(observed, actual, digest, size)['data']
    def js(p, digest=None): return json.loads(read(p, digest))
    old = js(parent/'input-manifest.json', PARENT)
    started, closed = js(sim/'build-started.json'), js(sim/'build-closed.json')
    definitions = read(sim/'defines.txt').decode().splitlines()
    check_profile(old, started, closed, definitions)
    owner = closed_owner(build_unit, started['invocation'])
    model = closed['binary_sha256']
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', model)
    read(sim/'build.log')
    for p, h in started['pins'].items(): read(Path(p), h)
    base.check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat').decode(),
                              started['command'])
    hw = read(parent/'defines.txt')
    require(hw == ('\n'.join(old['hardware_defines'])+'\n').encode(), 'parent defines changed')
    payload, origins, original, changed, compiled = {}, {}, {}, [], 0
    for row in old['files']:
        name = frozen_path(row['frozen']); require(name not in original, 'duplicate payload')
        prior = read(parent/name, row['sha256'], row['bytes'])
        original[name] = data = prior; source = parent/name
        if name.startswith('ventium/') and Path(name).suffix in base.SUFFIXES:
            source = sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'], 'source not compiled: '+name)
            data = read(source, started['pins'][str(source)])
            if name == base.SYSTEM: data = base.projection(prior, data)
            else: compiled += 1
        if check_delta(name, prior, data): changed.append(name)
        payload[name], origins[name] = data, source
    require(changed == [AUX] and compiled == 170 and len(payload) == 190, 'incomplete source match')
    prepared = js(overlay/'prepared.json')
    require(prepared['kind'] == 'PS2_MOUSE_CSR_SOURCE_OVERLAY' and not prepared['integrated_candidate'],
            'wrong overlay')
    extension = {frozen_path(n): read(overlay/n, h) for n, h in prepared['files'].items()}
    for p, h in prepared['input_pins'].items(): read(Path(p), h)
    payload = mouse.integrate(payload, extension)
    for name in extension: origins['flow/'+name] = overlay/name
    for name in mouse.ADDED:
        require(read(REPO/'fpga'/Path(name).name) == extension[name], 'peripheral source drift')
    before, done = js(proof/'started.json'), js(proof/'closed.json', PROOF)
    require(done['passed'] and done['pins_unchanged'] and done['error'] is None, 'peripheral proof failed')
    require(before['invocation'] == PROOF_INVOCATION, 'wrong peripheral invocation')
    peripheral_owner = closed_owner(PROOF_UNIT, PROOF_INVOCATION)
    require(not any(done[k] for k in ('physical_board', 'native_mmio', 'processor', 'windows', 'standard_suite')),
            'unexpected evidence scope')
    require(len(done['rows']) == 3 and before['definitions'] == ['VEN_KBC_FAST', 'VEN_KBD_AUTOACK'],
            'peripheral matrix/profile drift')
    for row, hz in zip(done['rows'][:2], (3125000, 40000000)):
        require(row['hz'] == hz and row['native_exit'] == 0 and row['error'] is None
                and row['commands'] == 20 and row['delivered'] == 50, 'peripheral execution incomplete')
    require(done['rows'][2]['native_exit'] == 1
            and 'wire data/parity mismatch bit=9' in done['rows'][2]['error'], 'negative control ineffective')
    for p, h in done['pins'].items(): read(Path(p), h)
    for name in ('soc/ps2.v', 'common/simple_fifo.v'):
        require(payload['ventium/3rd-party/ao486_MiSTer/rtl/'+name] == read(proof/'source'/Path(name).name),
                'tested peripheral does not match export')
    for name in (*mouse.ADDED, 'src/ven_mgmt_axil.v'):
        require(extension[name] == read(proof/'source'/Path(name).name), 'untested peripheral source: '+name)
    require(base.source_closure({n: dict(data=b) for n,b in payload.items()}) == old['source_closure']
            == dict(filelist_units=117, include_edges=49), 'filelist/include drift')
    checker = REPO/'fpga/test_aux_mouse_rk_wrapper.tcl'
    for p in (Path(__file__), Path(native.__file__), Path(native.recipe.__file__), Path(mouse.__file__),
              Path(mouse.recipe.__file__), Path(base.__file__), checker,
              REPO/'fpga/test_strict_mf_rk_wrapper.tcl', REPO/'fpga/test_rem_split_rk_wrapper.tcl',
              REPO/'fpga/test_code_payload_rk_wrapper.tcl', REPO/'fpga/freeze_rk_candidate.py',
              REPO/'fpga/freeze_performance_rk_candidate.py', REPO/'fpga/freeze_code_payload_rk_candidate.py',
              REPO/'fpga/freeze_bus_cancel_rk_candidate.py', REPO/'fpga/test_ic_prefix_board_profile.py'):
        read(p)
    def stable():
        for p, info in observed.items(): unchanged(p, info)
        require(all(p.resolve(strict=True) == q for p,q in aliases.items()), 'input alias changed')
    stable(); out.mkdir(); identity = directory(out)
    rows = []
    for name, data in payload.items():
        write_new(out/name, data)
        rows.append(dict(frozen=name, source=str(origins[name]), sha256=sha256(data), bytes=len(data),
                         parent_sha256=sha256(original[name]) if name in original else None))
    write_new(out/'defines.txt', hw)
    command = ['tclsh', str(checker), str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
               str(out/'flow'), str(out/'defines.txt'), str(out/'ventium'), str(out/'template'), 'logic_only']
    run = subprocess.run(command, capture_output=True, text=True, timeout=15)
    write_new(out/'source-contract.log', (run.stdout+run.stderr).encode())
    require(run.returncode == 0 and 'AUX-MOUSE-PROJECT-SOURCE-CONTRACT-OK: exact159defs' in run.stdout,
            'source contract failed: '+run.stdout+run.stderr)
    stable(); require(directory(out) == identity, 'output identity changed')
    for row in rows: snapshot(out/row['frozen'], row['sha256'], row['bytes'])
    changed_flow = ['flow/'+n for n in sorted(mouse.TRANSFORMS)]
    manifest = dict(old, variant='pipe_wait_aux_mouse_unqualified', files=rows, parent_manifest_sha256=PARENT,
        changed_parent_payloads=[AUX]+changed_flow, changed_flow_payloads=changed_flow,
        added_payloads=['flow/'+n for n in mouse.ADDED], simulator_sha256=None,
        processor_platform_simulator_sha256=model, full_wrapper_elaborated=False, full_soc_lint=False,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, fmax_mhz=None,
        gameplay_ipc=None, note='Current compiled core/platform plus tested AUX repair and mouse transport. '
        'The complete mouse wrapper is not modeled by the PC binary; no timing or acceptance inherited.')
    publish_new(out/'input-manifest.json', (json.dumps(manifest, indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED', source_contract_passed=True, payloads=len(rows),
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p): info['sha256'] for p,info in observed.items()},
        input_aliases={str(p): str(q) for p,q in aliases.items()}, build_owner=owner,
        peripheral_native_owner=peripheral_owner, complete_wrapper_or_board_qualified=False)
    publish_new(out/'freeze-receipt.json', (json.dumps(receipt, indent=2)+'\n').encode())
    return {k: receipt[k] for k in ('qualification','source_contract_passed','payloads','manifest_sha256')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','sim','overlay','proof','out'): parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--build-unit', required=True)
    args = parser.parse_args()
    print(json.dumps(freeze(args.parent.resolve(strict=True), args.sim.resolve(strict=True),
        args.overlay.resolve(strict=True), args.proof.resolve(strict=True), args.build_unit, args.out.resolve())))
