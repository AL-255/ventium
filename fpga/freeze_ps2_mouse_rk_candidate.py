#!/usr/bin/env python3
"""Integrate the tested mouse overlay into a separate, unqualified RK export.

The live timing export is never edited. This is source preparation, not whole
wrapper elaboration, synthesis, native MMIO or Windows acceptance. No simulator
or timing result is inherited by the new 192-payload hardware candidate.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

import prepare_ps2_mouse_mailbox as recipe
from freeze_performance_rk_candidate import require, source_closure
from freeze_rk_candidate import (directory, frozen_path, overlaps, publish_new,
    sha256, snapshot, unchanged, write_new)

REPO = Path(__file__).resolve().parents[1]
PARENT = 'd6f856259c0cdef90c0ef3f1a97b0a5568bdba13b8eb9d3a8332fc351bc90c20'
PROOF = '946e16f75e62701c733ca31d5ceaa37281907ac65dda83da37f259273a9a68ed'
TRANSFORMS = {'src/ven_mgmt_axil.v': recipe.management,
              'src/rk_ao486_system_pl.v': recipe.wrapper,
              'hw/create_project.tcl': recipe.project}
ADDED = ('src/ven_ps2_device.sv', 'src/ven_ps2_mailbox.sv')


def integrate(parent, overlay):
    """Pure exact-byte transformation; reject extra overlay or processor edits."""
    require(len(parent) == 190, 'wrong parent payload count')
    require(set(overlay) == set(TRANSFORMS) | set(ADDED), 'incomplete/extra overlay')
    result = dict(parent)
    for name, transform in TRANSFORMS.items():
        before = parent['flow/' + name]
        require(sha256(before) == recipe.BASE[name], 'wrapper predecessor drift: ' + name)
        require(overlay[name] == transform(before.decode()).encode(), 'unreviewed overlay delta: ' + name)
        result['flow/' + name] = overlay[name]
    for name in ADDED:
        require('flow/' + name not in parent, 'already integrated: ' + name)
        result['flow/' + name] = overlay[name]
    require(len(result) == 192, 'wrong integrated payload count')
    require(all(result[n] == b for n, b in parent.items() if not n.startswith('flow/')),
            'processor/template input changed')
    return result


def freeze(parent, overlay, proof, out):
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    require(__debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch, 'wrong scratch')
    require(scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 4*1024**3,
            'external volume/disk admission failed')
    require(out != scratch and out.is_relative_to(scratch) and not out.exists(), 'fresh external output required')
    roots = (parent, overlay, proof, REPO)
    require(not any(overlaps(out, p) for p in roots), 'overlapping source/output')
    identities = {p: directory(p) for p in roots}
    observed = {}
    def read(p, digest=None, size=None):
        data = snapshot(p, digest, size)
        if p in observed:
            require(observed[p]['fingerprint'] == data['fingerprint'], 'input changed during freeze')
        observed[p] = data
        return data['data']
    def js(p, digest=None): return json.loads(read(p, digest))
    old = js(parent/'input-manifest.json', PARENT)
    require(old['variant'] == 'backing_pair_payload_timing' and old['qualification'] == 'UNQUALIFIED',
            'wrong timing parent')
    require(old['core_mhz'] == 40 and old['write_slots'] == 16 and old['l2_sets'] == 1024,
            'clock/transport/cache profile changed')
    definitions = read(parent/'defines.txt')
    require(definitions == ('\n'.join(old['hardware_defines'])+'\n').encode()
            and len(set(old['hardware_defines'])) == len(old['hardware_defines']) == 158, 'define drift')
    original = {}
    for row in old['files']:
        name = frozen_path(row['frozen'])
        require(name not in original, 'duplicate input')
        original[name] = read(parent/name, row['sha256'], row['bytes'])
    prepared = js(overlay/'prepared.json')
    require(prepared['kind'] == 'PS2_MOUSE_CSR_SOURCE_OVERLAY' and not prepared['integrated_candidate'],
            'wrong peripheral overlay')
    extension = {frozen_path(n): read(overlay/n, h) for n, h in prepared['files'].items()}
    payload = integrate(original, extension)
    for name in ADDED:
        require(read(REPO/'fpga'/Path(name).name) == extension[name], 'peripheral source drift')
    for p, h in prepared['input_pins'].items(): read(Path(p), h)

    # Retain actual native peripheral evidence, but never reinterpret it as a
    # processor, native-MMIO, complete-wrapper or board qualification.
    before, done = js(proof/'started.json'), js(proof/'closed.json', PROOF)
    require(done['passed'] and done['pins_unchanged'] and done['error'] is None, 'peripheral run failed')
    require(not any(done[k] for k in ('physical_board', 'native_mmio', 'processor', 'windows', 'standard_suite')),
            'unexpected peripheral proof scope')
    require(len(done['rows']) == 3, 'missing native/mutation run')
    for row, hz in zip(done['rows'][:2], (3125000, 40000000)):
        require(row['hz'] == hz and row['native_exit'] == 0 and row['error'] is None
                and row['commands'] == 20 and row['delivered'] == 50, 'incomplete wire test')
    require(done['rows'][2]['native_exit'] == 1 and 'wire data/parity mismatch bit=9' in done['rows'][2]['error'],
            'negative control did not detect parity corruption')
    for p, h in done['pins'].items(): read(Path(p), h)
    for name in ('soc/ps2.v', 'common/simple_fifo.v'):
        require(original['ventium/3rd-party/ao486_MiSTer/rtl/'+name] == read(proof/'source'/Path(name).name),
                'controller/FIFO differs from tested peripheral source')
    require(before['definitions'] == ['VEN_KBC_FAST', 'VEN_KBD_AUTOACK']
            and set(before['definitions']) <= set(old['hardware_defines']), 'controller profile drift')
    props = dict(s.split('=', 1) for s in subprocess.check_output(['systemctl', '--user', 'show',
        'ventium-ps2-adapter-path-oct12.service', '-p', 'SubState', '-p', 'MainPID',
        '-p', 'ExecMainStatus', '-p', 'InvocationID'], text=True, timeout=10).splitlines())
    require(props == dict(SubState='exited', MainPID='0', ExecMainStatus='0',
            InvocationID=before['invocation']), 'peripheral native owner not closed')
    closure = source_closure({n: dict(data=b) for n, b in payload.items()})
    require(closure == old['source_closure'] == dict(filelist_units=117, include_edges=49), 'source closure drift')
    checker = REPO/'fpga/test_ps2_mouse_rk_wrapper.tcl'
    for p in (Path(__file__), Path(recipe.__file__), checker,
              REPO/'fpga/test_rem_split_rk_wrapper.tcl', REPO/'fpga/test_code_payload_rk_wrapper.tcl',
              REPO/'fpga/freeze_rk_candidate.py', REPO/'fpga/freeze_performance_rk_candidate.py'):
        read(p)
    def stable():
        for p, info in observed.items(): unchanged(p, info)
        for p, identity in identities.items(): require(directory(p) == identity, 'input directory changed')
    stable(); out.mkdir(); identity = directory(out)
    rows = []
    for name, data in payload.items():
        write_new(out/name, data)
        added_or_changed = name.startswith('flow/') and name[5:] in extension
        rows.append(dict(frozen=name, source=str(overlay/name[5:] if added_or_changed else parent/name),
            sha256=sha256(data), bytes=len(data), parent_sha256=sha256(original[name]) if name in original else None))
    write_new(out/'defines.txt', definitions)
    command = ['tclsh', str(checker), str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
               str(out/'flow'), str(out/'defines.txt'), str(out/'ventium'), str(out/'template'), 'logic_only']
    native = subprocess.run(command, capture_output=True, text=True, timeout=15)
    write_new(out/'source-contract.log', (native.stdout+native.stderr).encode())
    require(native.returncode == 0 and 'MOUSE-PROJECT-SOURCE-CONTRACT-OK' in native.stdout,
            'project source contract failed: '+native.stdout+native.stderr)
    stable(); require(directory(out) == identity, 'output identity changed')
    for row in rows: snapshot(out/row['frozen'], row['sha256'], row['bytes'])
    manifest = dict(old, variant='backing_pair_payload_mouse_unqualified', files=rows,
        parent_manifest_sha256=PARENT, changed_parent_payloads=['flow/'+n for n in sorted(TRANSFORMS)],
        changed_flow_payloads=['flow/'+n for n in sorted(TRANSFORMS)], added_payloads=['flow/'+n for n in ADDED],
        simulator_sha256=None, unchanged_processor_simulator_sha256=old['simulator_sha256'],
        full_wrapper_elaborated=False, full_soc_lint=False, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None,
        note='Source-only mouse integration. Parent timing and simulator acceptance are not inherited.')
    publish_new(out/'input-manifest.json', (json.dumps(manifest, indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED', source_contract_passed=True, payloads=len(rows),
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p): info['sha256'] for p, info in observed.items()},
        peripheral_native_owner=props, complete_wrapper_or_board_qualified=False)
    publish_new(out/'freeze-receipt.json', (json.dumps(receipt, indent=2)+'\n').encode())
    return {k: receipt[k] for k in ('qualification', 'source_contract_passed', 'payloads', 'manifest_sha256')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'overlay', 'proof', 'out'): parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(freeze(args.parent.resolve(strict=True), args.overlay.resolve(strict=True),
                            args.proof.resolve(strict=True), args.out.resolve())))
